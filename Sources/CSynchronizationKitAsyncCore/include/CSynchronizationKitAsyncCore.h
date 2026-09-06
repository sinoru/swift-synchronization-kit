// ThreadSanitizer annotations for the wait queue.
//
// A waiter is handed what it waited for by whoever held it, and resumed; the
// ordering between the holder's last writes and the waiter's first reads is
// real — it runs through the state lock and the runtime's continuation
// machinery — but the sanitizer sees only part of it. A continuation resumed
// before its task has finished suspending continues in place, and that path
// through the runtime records no acquire where the enqueued path does. Under
// a fast enough handoff the sanitizer is then left with no edge between one
// holder and the next, and reports the protected value as raced.
//
// These two calls put the edge on record: a release on the waiter as it is
// granted, an acquire in its task once it resumes. Nothing but the sanitizer
// reads them, and outside a sanitized build they are empty.
//
// They are defined in `shim.c` rather than here, for the reason
// `CSynchronizationKitSemaphore.h` gives for its own pair: whether the
// sanitizer is in play is a `__has_feature` question, and for a header
// consumed from Swift that question goes to the Clang importer, which is not
// handed the sanitizer flag. Compiled as their own translation unit, the
// question goes to the compiler that is.

#ifndef C_SYNCHRONIZATION_KIT_ASYNC_CORE_H
#define C_SYNCHRONIZATION_KIT_ASYNC_CORE_H

/// Publishes everything this thread has done, for whoever acquires `token`.
///
/// Does nothing unless the target was built with the sanitizer.
extern void sk_async_core_tsan_release(void *token);

/// Takes what the thread that last released `token` had done by then.
///
/// Does nothing unless the target was built with the sanitizer.
extern void sk_async_core_tsan_acquire(void *token);

#endif // C_SYNCHRONIZATION_KIT_ASYNC_CORE_H
