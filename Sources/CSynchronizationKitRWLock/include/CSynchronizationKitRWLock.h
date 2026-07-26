// Darwin's address-based wait and wake, reachable from Swift.
//
// `os_sync_wait_on_address` and its wake counterparts are public API, but the
// SDK's `os` module map lists only `atomic.h`, `overflow.h`, `log.h` and a few
// others — not `os/os_sync_wait_on_address.h`. The Clang importer therefore
// never sees these calls, so this target includes the header directly and
// re-exports the three entry points `RWLock` needs.
//
// Every platform has to name itself in the guard below. A platform left out is
// not defaulted to unavailable — it is defaulted to *available*: with no clause
// for the target's platform the check is left with an empty version, an empty
// version always compares as already met, and the whole thing folds to a
// constant true, leaving a call into a weak symbol that resolves to null. The
// trailing `*` does not choose that outcome; it is required punctuation and
// matches nothing. See the pragma below for what makes that a build failure
// rather than something to be careful about.
//
// Mac Catalyst is the one platform with no clause of its own, because Clang
// rewrites an `ios` clause to `maccatalyst` when none is given. It gets no
// clause rather than a redundant one so that the pragma keeps deciding this
// rather than a comment. Nothing similar happens for visionOS: its versions
// pair with iOS in the SDK's own declarations, but not in a guard written here,
// so it is spelled out at the 1.1 that pairs with `ios(17.4)`.
//
// The check lives here rather than on the Swift side only so that one spelling
// serves the shim and its callers; it is not doing any mapping for us.

#ifndef C_SYNCHRONIZATION_KIT_RWLOCK_H
#define C_SYNCHRONIZATION_KIT_RWLOCK_H

#if defined(__APPLE__)

#include <errno.h>
#include <os/os_sync_wait_on_address.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

// A platform missing from the guard below is the one mistake here that changes
// behaviour, and Clang already reports it: the call reads as unguarded on the
// platform that was left out, because as far as the compiler is concerned no
// guard covers it. That is a warning, and a warning in one target's build log
// is not a thing anyone reads, so it is an error here instead. Building for the
// platform is then all it takes to catch — a pragma rather than a build setting
// so that holds for anyone compiling this header, not just this package's own
// build. `-Werror` in `cSettings` would need `.unsafeFlags`, which would stop
// the package from being usable as a versioned dependency at all.
#pragma clang diagnostic error "-Wunguarded-availability"
#pragma clang diagnostic error "-Wunguarded-availability-new"

#define SK_RWLOCK_SHIM static inline __attribute__((always_inline))

/// The one spelling of the availability check, which every entry point below
/// guards itself with.
///
/// A macro rather than a function because Clang's unguarded-use analysis stops
/// at the function boundary: each call to `os_sync_*` has to sit lexically
/// inside its own `__builtin_available`. Spelling it once is what keeps the
/// four from drifting apart, which is the failure described above — three sites
/// updated and one not produces no diagnostic and misbehaves only on the
/// platform that was missed.
#define SK_RWLOCK_ADDRESS_WAIT_AVAILABLE()  \
    __builtin_available(                    \
        macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, visionOS 1.1, *)

/// Whether the running OS provides the wait and wake calls below.
///
/// Every other entry point here repeats the same check, so a caller that skips
/// this one gets a failed call rather than a missing symbol.
SK_RWLOCK_SHIM bool sk_rwlock_address_wait_is_available(void) {
    if (SK_RWLOCK_ADDRESS_WAIT_AVAILABLE()) {
        return true;
    }

    return false;
}

/// Blocks for as long as the four-byte value at `address` equals `expected`.
///
/// The comparison runs in the kernel under the same lock the wake calls take,
/// which is what makes the caller's own read of `address` safe to act on: a
/// wake that lands after that read either fails this comparison outright or
/// arrives at the sleep it established. Neither order drops the wake.
///
/// - Returns: The number of threads still blocked on `address`, or -1 with
///   `errno` set. `EINTR`, `EFAULT` and `ENOMEM` are documented early returns
///   rather than failures; the caller re-reads `address` and decides again.
SK_RWLOCK_SHIM int sk_rwlock_wait_on_address(uint32_t *address, uint32_t expected) {
    if (SK_RWLOCK_ADDRESS_WAIT_AVAILABLE()) {
        return os_sync_wait_on_address(
            address, expected, sizeof(uint32_t), OS_SYNC_WAIT_ON_ADDRESS_NONE
        );
    }

    errno = ENOTSUP;
    return -1;
}

/// Wakes one thread blocked on `address`, if any is.
///
/// - Returns: 0, or -1 with `errno` set. `ENOENT` reports that nobody was
///   blocked, which is an ordinary outcome rather than a failure.
SK_RWLOCK_SHIM int sk_rwlock_wake_one_by_address(uint32_t *address) {
    if (SK_RWLOCK_ADDRESS_WAIT_AVAILABLE()) {
        return os_sync_wake_by_address_any(
            address, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_NONE
        );
    }

    errno = ENOTSUP;
    return -1;
}

/// Wakes every thread blocked on `address`.
///
/// - Returns: 0, or -1 with `errno` set. `ENOENT` again reports that nobody was
///   blocked. Unlike the single-waiter call, the SDK documents this one as
///   returning what `os_sync_wait_on_address` returns, which adds `EINTR`,
///   `EFAULT` and `ENOMEM` — early returns rather than failures, so a caller
///   that needs the wake delivered has to ask again.
SK_RWLOCK_SHIM int sk_rwlock_wake_all_by_address(uint32_t *address) {
    if (SK_RWLOCK_ADDRESS_WAIT_AVAILABLE()) {
        return os_sync_wake_by_address_all(
            address, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_NONE
        );
    }

    errno = ENOTSUP;
    return -1;
}

// MARK: - Telling ThreadSanitizer about an ordering it cannot see

// A thread released from a Mach semaphore observes everything the signalling
// thread did before it — the kernel takes the barriers with the wait queue lock
// — but ThreadSanitizer does not model those calls, so it never records the
// edge. Where a lock's whole handoff rests on one, as `RWLock`'s does on the
// releases predating `os_sync_wait_on_address`, the sanitizer then reports the
// protected value as raced by every reader a writer wakes.
//
// Measured rather than assumed: a writer, a reader and one cell, ordered only
// by a Mach semaphore, draws a report, while the same shape ordered by an
// atomic or by `dispatch_semaphore_t` draws none and the same shape ordered by
// nothing draws one. The pair below is what the sanitizer offers for exactly
// this: `_release` publishes what this thread has done to a token, `_acquire`
// takes it, and the two are joined by the token address alone.
//
// This matters off this package's own test runs. Somebody whose deployment
// target predates those calls, running their own app under the sanitizer, is
// told their reads of a lock-protected value race — with none of the context
// that says otherwise.
//
// Unlike everything above these are defined in `shim.c` rather than here. They
// have to be: whether the sanitizer is in play is answered by `__has_feature`,
// and for a header consumed from Swift that question is put to the Clang
// importer, which is not handed the sanitizer flag even when every Swift file
// around it is being instrumented — so an inline definition compiles to nothing
// in exactly the build that needs it. A weak import instead of a feature test
// does not survive the importer either; the attribute is dropped and the
// program fails to link anywhere the runtime is absent, which is everywhere
// normal. Compiled as its own C translation unit the question is put to the
// compiler actually building this target, which is the one that knows.

/// Publishes everything this thread has done, for whoever acquires `token`.
///
/// Does nothing unless the target was built with the sanitizer.
extern void sk_rwlock_tsan_release(void *token);

/// Takes what the thread that last released `token` had done by then.
///
/// Does nothing unless the target was built with the sanitizer.
extern void sk_rwlock_tsan_acquire(void *token);

#undef SK_RWLOCK_ADDRESS_WAIT_AVAILABLE
#undef SK_RWLOCK_SHIM

#pragma clang assume_nonnull end

#endif // defined(__APPLE__)

#endif // C_SYNCHRONIZATION_KIT_RWLOCK_H
