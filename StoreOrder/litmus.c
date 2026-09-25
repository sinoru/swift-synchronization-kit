// Whether a plain store can become visible after a later acquire-only
// compare-and-swap, in the shape libdispatch gives it when a worker takes a
// lane off a root queue and finds it cannot run it:
//
//   invoker                          pusher
//   x = LISTLESS      (plain str)    spin until y == 0
//   CAS y: 1 -> 0     (acquire)      CAS y: 0 -> 1   (release)
//                                    x = NULL        (plain str)
//
// The pusher writes x only after it has seen the invoker's CAS, and the
// invoker wrote x before that CAS. If x ends as LISTLESS, the invoker's store
// reached memory after the pusher's: the reordering in question.
//
// Usage: litmus <order> <layout> <seconds>
//   order:  acq    CAS with acquire only, as libdispatch has it
//           acqrel CAS with acquire and release   (control, must be 0)
//           ishst  acquire CAS after `dmb ishst`  (control, must be 0)
//   layout: same   x and y in one cache line, at a lane's offsets
//           split  x and y in two cache lines, the pusher reading both

#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SLOTS (1u << 14)
#define LISTLESS 1
#define CLEARED 2

typedef struct {
    _Alignas(128) uint64_t line0[16];
    uint64_t line1[16];
} slot_t;

enum order { ORDER_ACQ, ORDER_ACQREL, ORDER_ISHST };

typedef struct {
    slot_t *slots;
    enum order order;
    bool split;
    int cpu[2];
    _Alignas(128) volatile uint64_t batch;
    _Alignas(128) volatile uint64_t invoker_done;
    _Alignas(128) volatile uint64_t pusher_done;
    _Alignas(128) volatile bool stop;
    uint64_t trials, observed;
} pair_t;

static uint64_t *x_of(pair_t *p, uint32_t i) {
    return p->split ? &p->slots[i].line0[0] : &p->slots[i].line0[2];   // +0x10
}
static uint64_t *y_of(pair_t *p, uint32_t i) {
    return p->split ? &p->slots[i].line1[0] : &p->slots[i].line0[7];   // +0x38
}
static uint64_t *done_of(pair_t *p, uint32_t i) {
    return &p->slots[i].line1[8];
}

static void pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof set, &set) != 0) {
        fprintf(stderr, "cannot pin to cpu %d\n", cpu);
        exit(2);
    }
}

static void reset(pair_t *p) {
    for (uint32_t i = 0; i < SLOTS; i++) {
        memset(&p->slots[i], 0, sizeof p->slots[i]);
        *y_of(p, i) = 1;
    }
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
}

static void *invoker(void *arg) {
    pair_t *p = arg;
    pin(p->cpu[0]);
    for (uint64_t b = 1;; b++) {
        while (p->batch < b) {
            if (p->stop) return NULL;
        }
        for (uint32_t i = 0; i < SLOTS; i++) {
            // Keep the pusher close behind: it is spinning on this slot's y
            // by the time x is written.
            if (i > 0) {
                while (__atomic_load_n(done_of(p, i - 1), __ATOMIC_ACQUIRE) == 0) {}
            }
            uint64_t expected = 1;
            __atomic_store_n(x_of(p, i), LISTLESS, __ATOMIC_RELAXED);
            switch (p->order) {
            case ORDER_ACQ:
                __atomic_compare_exchange_n(y_of(p, i), &expected, 0, false,
                        __ATOMIC_ACQUIRE, __ATOMIC_RELAXED);
                break;
            case ORDER_ACQREL:
                __atomic_compare_exchange_n(y_of(p, i), &expected, 0, false,
                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
                break;
            case ORDER_ISHST:
                __asm__ __volatile__("dmb ishst" ::: "memory");
                __atomic_compare_exchange_n(y_of(p, i), &expected, 0, false,
                        __ATOMIC_ACQUIRE, __ATOMIC_RELAXED);
                break;
            }
        }
        __atomic_store_n(&p->invoker_done, b, __ATOMIC_RELEASE);
    }
}

static void *pusher(void *arg) {
    pair_t *p = arg;
    pin(p->cpu[1]);
    for (uint64_t b = 1;; b++) {
        while (p->batch < b) {
            if (p->stop) return NULL;
        }
        for (uint32_t i = 0; i < SLOTS; i++) {
            uint64_t *x = x_of(p, i), *y = y_of(p, i);
            while (__atomic_load_n(y, __ATOMIC_RELAXED) != 0) {
                // In the split layout, keep x's line shared here too, as the
                // other threads touching a lane keep it.
                if (p->split) (void)__atomic_load_n(x, __ATOMIC_RELAXED);
            }
            uint64_t expected = 0;
            if (__atomic_compare_exchange_n(y, &expected, 1, false,
                    __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {
                __atomic_store_n(x, CLEARED, __ATOMIC_RELAXED);
            }
            __atomic_store_n(done_of(p, i), 1, __ATOMIC_RELEASE);
        }
        __atomic_store_n(&p->pusher_done, b, __ATOMIC_RELEASE);
    }
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s acq|acqrel|ishst same|split seconds\n", argv[0]);
        return 2;
    }
    enum order order;
    if (!strcmp(argv[1], "acq")) order = ORDER_ACQ;
    else if (!strcmp(argv[1], "acqrel")) order = ORDER_ACQREL;
    else if (!strcmp(argv[1], "ishst")) order = ORDER_ISHST;
    else return 2;
    bool split = !strcmp(argv[2], "split");
    double seconds = atof(argv[3]);

    // One pair per two CPUs, all running at once.
    int cpus = (int)sysconf(_SC_NPROCESSORS_ONLN);
    int pairs = cpus / 2;
    pair_t *pair = aligned_alloc(128, sizeof(pair_t) * pairs);
    pthread_t threads[2 * pairs];
    for (int k = 0; k < pairs; k++) {
        memset(&pair[k], 0, sizeof pair[k]);
        pair[k].slots = aligned_alloc(128, sizeof(slot_t) * SLOTS);
        pair[k].order = order;
        pair[k].split = split;
        pair[k].cpu[0] = 2 * k;
        pair[k].cpu[1] = 2 * k + 1;
        reset(&pair[k]);
        pthread_create(&threads[2 * k], NULL, invoker, &pair[k]);
        pthread_create(&threads[2 * k + 1], NULL, pusher, &pair[k]);
    }

    double start = now();
    for (uint64_t b = 1; now() - start < seconds; b++) {
        for (int k = 0; k < pairs; k++) __atomic_store_n(&pair[k].batch, b, __ATOMIC_RELEASE);
        for (int k = 0; k < pairs; k++) {
            while (__atomic_load_n(&pair[k].invoker_done, __ATOMIC_ACQUIRE) < b ||
                   __atomic_load_n(&pair[k].pusher_done, __ATOMIC_ACQUIRE) < b) {}
            for (uint32_t i = 0; i < SLOTS; i++) {
                uint64_t x = *x_of(&pair[k], i);
                if (x == LISTLESS) pair[k].observed++;
                else if (x != CLEARED) {
                    fprintf(stderr, "slot %u ended as %llu\n", i, (unsigned long long)x);
                    return 3;
                }
            }
            pair[k].trials += SLOTS;
            reset(&pair[k]);
        }
    }
    uint64_t trials = 0, observed = 0;
    for (int k = 0; k < pairs; k++) {
        pair[k].stop = true;
        trials += pair[k].trials;
        observed += pair[k].observed;
        printf("pair %d (cpu %d,%d): %llu of %llu\n", k, pair[k].cpu[0], pair[k].cpu[1],
               (unsigned long long)pair[k].observed, (unsigned long long)pair[k].trials);
    }
    printf("%s %s: x ended as LISTLESS in %llu of %llu trials in %.0fs\n",
           argv[1], argv[2], (unsigned long long)observed, (unsigned long long)trials, now() - start);
    return 0;
}
