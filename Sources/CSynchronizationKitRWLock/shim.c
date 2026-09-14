// The per-thread record the header describes.
//
// A fixed array rather than anything that allocates: a thread holds a handful
// of locks at a time, and the record should cost a thread that never takes
// one nothing but its storage. Holds past the end of the array are counted
// and not kept, so a nesting deeper than that goes unchecked below the last
// kept hold rather than misreported: a lookup only ever finds holds that are
// real.

#include "CSynchronizationKitRWLock.h"

// Whether the target has thread-local storage is asked of the compiler
// building this target, which is the one that knows. A target without it is
// built all the same: nothing records a hold there, so the functions compile
// to nothing.
#if __has_feature(c_thread_local)

#define SK_HOLD_CAPACITY 16

struct sk_hold {
    uintptr_t lock;
    int kind;
};

static _Thread_local struct sk_hold sk_holds[SK_HOLD_CAPACITY];

/// Holds recorded and not yet forgotten, kept or not.
static _Thread_local unsigned sk_hold_count;

void sk_rwlock_hold_push(uintptr_t lock, int kind) {
    if (sk_hold_count < SK_HOLD_CAPACITY) {
        sk_holds[sk_hold_count].lock = lock;
        sk_holds[sk_hold_count].kind = kind;
    }
    sk_hold_count += 1;
}

void sk_rwlock_hold_pop(void) {
    sk_hold_count -= 1;
}

int sk_rwlock_hold_find(uintptr_t lock) {
    unsigned index = sk_hold_count < SK_HOLD_CAPACITY ? sk_hold_count : SK_HOLD_CAPACITY;
    while (index > 0) {
        index -= 1;
        if (sk_holds[index].lock == lock) {
            return sk_holds[index].kind;
        }
    }
    return 0;
}

#else

void sk_rwlock_hold_push(uintptr_t lock, int kind) {
    (void)lock;
    (void)kind;
}

void sk_rwlock_hold_pop(void) {}

int sk_rwlock_hold_find(uintptr_t lock) {
    (void)lock;
    return 0;
}

#endif
