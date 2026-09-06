// ThreadSanitizer annotations for an ordering it cannot see.
//
// A handoff between two threads, or two tasks, is ordered by whatever carries
// it — a kernel wait queue, the runtime's continuation machinery — and the
// sanitizer models some of those carriers and not others. Where it models
// none of the ordering, it is left with no edge between the side that wrote
// and the side that reads, and reports the protected value as raced.
//
// This package meets that twice:
//
// - `Semaphore`, on the Darwin releases predating `os_sync_wait_on_address`,
//   hands off through a Mach semaphore. The kernel takes the barriers with the
//   wait queue lock, but the sanitizer does not model those calls and never
//   records the edge — so every reader a writer wakes through `RWLock` is told
//   its read of the protected value races. Measured rather than assumed: a
//   writer, a reader and one cell, ordered only by a Mach semaphore, draws a
//   report, while the same shape ordered by an atomic or by
//   `dispatch_semaphore_t` draws none and the same shape ordered by nothing
//   draws one.
//
// - The asynchronous wait queue grants a waiter and resumes it. A continuation
//   resumed before its task has finished suspending continues in place, and
//   that path through the runtime records no acquire where the enqueued path
//   does. Under a fast enough handoff the sanitizer is then left with no edge
//   between one holder and the next.
//
// Both matter off this package's own test runs: somebody running their own
// app under the sanitizer is told their reads of a lock-protected value race,
// with none of the context that says otherwise.
//
// The pair below is what the sanitizer offers for exactly this: `_release`
// publishes what this thread has done to a token, `_acquire` takes it, and
// the two are joined by the token address alone. Nothing but the sanitizer
// reads them, and outside a sanitized build they are empty.
//
// They are defined in `shim.c` rather than here. They have to be: whether the
// sanitizer is in play is answered by `__has_feature`, and for a header
// consumed from Swift that question is put to the Clang importer, which is not
// handed the sanitizer flag even when every Swift file around it is being
// instrumented — so an inline definition compiles to nothing in exactly the
// build that needs it. A weak import instead of a feature test does not
// survive the importer either; the attribute is dropped and the program fails
// to link anywhere the runtime is absent, which is everywhere normal. Compiled
// as its own C translation unit the question is put to the compiler actually
// building this target, which is the one that knows.

#ifndef C_SYNCHRONIZATION_KIT_CORE_H
#define C_SYNCHRONIZATION_KIT_CORE_H

/// Publishes everything this thread has done, for whoever acquires `token`.
///
/// Does nothing unless the target was built with the sanitizer.
extern void sk_tsan_release(void *token);

/// Takes what the thread that last released `token` had done by then.
///
/// Does nothing unless the target was built with the sanitizer.
extern void sk_tsan_acquire(void *token);

#endif // C_SYNCHRONIZATION_KIT_CORE_H
