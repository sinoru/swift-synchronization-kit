//
//  SemaphoreHandle.swift
//  SynchronizationKit
//

// One backend per tier, chosen the way `RWLock` chooses its own: Darwin builds
// the semaphore out of an atomic word, every libc with unnamed POSIX semaphores
// takes those, Windows takes a kernel semaphore object, and anything else —
// embedded targets, currently — has no thread to block and gets no type.
//
// The handle is `package` rather than `internal` for the reason `_MutexHandle`
// is: `RWLock` builds its two gates out of it, which is the one place a
// semaphore appears inside a lock. `@usableFromInline` is what lets
// `Semaphore`'s inlined entry points carry references to it into client code
// without exposing the name.

#if canImport(Darwin)
import CSynchronizationKitCore
import CSynchronizationKitSemaphore
import Darwin
// The wait word is a stored property of a `@usableFromInline` type, so the
// module declaring its type is on this one's interface.
public import SynchronizationKitAtomic

/// The type of the word threads wait on.
///
/// This package's own `Atomic` deliberately: SwiftPM builds a package at the
/// deployment targets its manifest declares, which sit below every version
/// where the type's deprecation begins, so the warning never fires here — and
/// address-based waiting needs the address of the storage itself, which only
/// this type hands out. The release that moves the minimums past those
/// versions must revisit this alias along with `RWLock`'s.
///
/// Sixty-four bits: the count and the number of threads waiting on it, side
/// by side, so that one atomic operation reads or moves both. `_Layout`
/// says which half is which.
@usableFromInline
package typealias _AtomicWord = SynchronizationKitAtomic.Atomic<UInt64>

/// How the word is laid out on the address-based path: permits in the low
/// half, waiters in the high half.
///
/// The arrangement glibc's `sem_t` uses where 64-bit atomics are available,
/// and for the same reason. A signal has to know whether anybody is waiting
/// before it asks the kernel to wake them — the kernel answers `ENOENT` when
/// nobody is, but answering costs a system call, and an uncontended signal
/// would pay it every time — and a count alone cannot say. `DispatchSemaphore`
/// gets by with one signed count because a Mach semaphore below it keeps a
/// signal that arrives before its waiter blocks; an address wait keeps
/// nothing, so the waiters have to be counted here.
///
/// Threads wait on the permit half alone, as a four-byte word with an
/// expected value of zero, so a waiter registers itself with one add rather
/// than a compare-and-exchange loop, and a change in the waiter count wakes
/// nobody. That half is the word's first four bytes on every architecture
/// Apple ships, which the `#if` below is there to notice if it ever stops
/// being true.
@usableFromInline
package enum _Layout {
    @usableFromInline
    package static var waiterOne: UInt64 { 1 << 32 }

    @usableFromInline
    package static func permits(_ word: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: word)
    }

    @usableFromInline
    package static func waiters(_ word: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: word >> 32)
    }
}

#if !_endian(little)
#error("the permit half of the semaphore word is assumed to come first in memory")
#endif

/// Whether waits go to an address rather than to a Mach semaphore.
///
/// Resolved once. It depends only on the version of the OS the process is
/// running on, which cannot change underneath it.
@usableFromInline
package let _addressWaitIsAvailable: Bool = sk_semaphore_address_wait_is_available()

/// A counting semaphore over one 64-bit word, and nothing else.
///
/// The word is read one of two ways depending on `_addressWaitIsAvailable`:
/// as the permits outstanding and the threads waiting for one, laid out as
/// `_Layout` says, which threads block on directly through
/// `os_sync_wait_on_address`; or as the Mach port name of the kernel
/// semaphore holding those permits — `MACH_PORT_NULL` until the first thread
/// has to block or signal. The two readings never mix; which applies follows
/// from the running OS, which cannot change underneath a handle, so the
/// answer is a global rather than a stored property: `RWLock` carries two of
/// these, and a byte beside each would cost it eight.
///
/// Darwin's unnamed POSIX semaphores are declared deprecated and
/// unimplemented, which is why this looks nothing like the other backends.
///
/// - Note: The Mach half of this file goes when the deployment targets reach
///   macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4 and visionOS 1.1. That is
///   every branch on `_addressWaitIsAvailable` and the `deinit`, leaving
///   `_Layout` as the only reading of the word.
@_staticExclusiveOnly
@usableFromInline
package struct _SemaphoreHandle: ~Copyable {
    /// Permits outstanding and waiters, or the port name of the semaphore
    /// holding the permits.
    @usableFromInline
    package let word: _AtomicWord

    @usableFromInline
    package init(value: Int) {
        precondition(
            value >= 0 && value <= Int32.max,
            "Semaphore requires an initial value in 0...Int32.max"
        )
        if _addressWaitIsAvailable {
            // The word is the count from the start, with nobody waiting.
            word = _AtomicWord(UInt64(value))
        } else {
            // The word is a port name. A count of zero has nothing to hold
            // yet, so no port is created until a thread has to block or
            // signal — the case every `RWLock` gate is in, and what keeps
            // locks in bulk cheap. A positive count is created with its port
            // now, the way `DispatchSemaphore` does.
            word = _AtomicWord(0)
            if value > 0 {
                _ = _createSemaphorePort(startingAt: Int32(value))
            }
        }
    }

    deinit {
        // Only the semaphore reading of the word owns anything.
        if !_addressWaitIsAvailable {
            _destroyAnySemaphore()
        }
    }

    // `_wait` and `_signal` are `@inline(always)`, as `_MutexHandle`'s
    // operations are: on the address-based path the part that needs no kernel
    // — taking a permit that is there, publishing permits that wake nobody —
    // is an atomic operation or two, and inlined into the client it is
    // compiled for the client's deployment target, where a target new enough
    // gets single-instruction atomics that this package's own minimum does
    // not. Everything past that point — registering as a waiter and sleeping,
    // asking the kernel to wake — stays out of line, behind a call, and so
    // does the whole of the Mach path.

    /// Blocks until a permit is available, then takes it.
    @inline(always)
    package borrowing func _wait() {
        if _addressWaitIsAvailable {
            // The fast path: a permit is there, take it. Nothing is
            // registered, so a signal arriving meanwhile has nobody to wake
            // and nothing to pay for.
            var current = word.load(ordering: .acquiring)
            while _Layout.permits(current) > 0 {
                let (exchanged, observed) = word.compareExchange(
                    expected: current,
                    desired: current &- 1,
                    ordering: .acquiringAndReleasing
                )
                if exchanged {
                    return
                }
                current = observed
            }
            _waitByAddress()
        } else {
            _waitBySemaphore()
        }
    }

    /// Hands out `count` permits and wakes whoever can use them.
    ///
    /// - Precondition: `count` is positive.
    @inline(always)
    package borrowing func _signal(_ count: Int32) {
        precondition(count > 0, "a semaphore cannot signal a non-positive number of permits")
        if _addressWaitIsAvailable {
            let added = word.wrappingAdd(UInt64(count), ordering: .releasing).newValue
            // A wrapped add lands below what was just added, carrying into
            // the waiter half on its way. Trapping after the fact is enough:
            // the other backends fail the same way — `sem_post` with
            // `EOVERFLOW`, `ReleaseSemaphore` with an error — and each is a
            // precondition here too. `RWLock`'s gates cannot get here, their
            // permits being bounded by the reader count; a public
            // `Semaphore` can.
            precondition(_Layout.permits(added) >= UInt32(count), "Semaphore count overflowed")

            // Publishing the permits above is what a sleeper's comparison
            // tests, so the wake below only has to cover threads already
            // blocked — and only has to be asked for when there might be
            // one. A waiter is counted before it looks at the permits and
            // until it has taken one, so a zero here means nobody is on the
            // way to sleep either, and the kernel is left alone: this is the
            // whole cost of an uncontended signal.
            guard _Layout.waiters(added) > 0 else {
                return
            }
            _wakeByAddress(count)
        } else {
            _signalBySemaphore(count)
        }
    }

    /// Traps if the count has fallen below `initialValue`, where the count can
    /// be read.
    ///
    /// The kernel does not report a Mach semaphore's count, so on that path
    /// this checks nothing.
    @usableFromInline
    package borrowing func _checkNotInUse(since initialValue: Int32) {
        if _addressWaitIsAvailable {
            precondition(
                _Layout.permits(word.load(ordering: .relaxed)) >= UInt32(initialValue),
                "Semaphore deallocated while in use"
            )
        }
    }
}

// MARK: - Waiting on an address

extension _SemaphoreHandle {
    /// The address of the word's permit half, which is what threads wait on
    /// and what the kernel compares against.
    private borrowing func _address() -> UnsafeMutablePointer<UInt32> {
        unsafe word._rawAddress.assumingMemoryBound(to: UInt32.self)
    }

    /// The rest of a wait once `_wait` found nothing to take: registers as
    /// a waiter and sleeps until a permit can be had.
    @usableFromInline
    internal borrowing func _waitByAddress() {
        // Register as a waiter before looking again, so that a signal which
        // lands after this add sees a waiter and wakes it; the add and the
        // signal's own are ordered by the word, and a signal that landed
        // before it left a permit for the loop to find. Relaxed, for that
        // reason: the ordering that matters is the acquire on the take below
        // against the release on the signal.
        var current = word.wrappingAdd(_Layout.waiterOne, ordering: .relaxed).newValue

        while true {
            if _Layout.permits(current) == 0 {
                // Sleep until the permit half moves off zero. A signal landing
                // between the read above and this call cannot be missed: the
                // kernel compares the word itself, so such a signal either
                // fails the comparison or wakes the sleep it established.
                if unsafe sk_semaphore_wait_on_address(_address(), 0) < 0 {
                    precondition(
                        errno == EINTR || errno == EFAULT || errno == ENOMEM,
                        "os_sync_wait_on_address failed"
                    )
                    // Every one of those is a documented early return rather
                    // than a failure; the loop re-reads the word and decides
                    // again.
                }
                current = word.load(ordering: .relaxed)
                continue
            }

            // A permit and a registration, both given up in the one exchange.
            let (exchanged, observed) = word.compareExchange(
                expected: current,
                desired: current &- 1 &- _Layout.waiterOne,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                return
            }
            current = observed
        }
    }

    /// The rest of a signal once `_signal` found a waiter to wake: asks the
    /// kernel to wake one, or all, of the threads blocked on the word.
    @usableFromInline
    internal borrowing func _wakeByAddress(_ count: Int32) {
        while true {
            let result =
                count == 1
                ? unsafe sk_semaphore_wake_one_by_address(_address())
                : unsafe sk_semaphore_wake_all_by_address(_address())
            if result >= 0 || errno == ENOENT {
                // `ENOENT` reports that nobody was blocked yet. The permits
                // stand, and the next thread to look will find them.
                return
            }

            precondition(
                errno == EINTR || errno == EFAULT || errno == ENOMEM,
                "os_sync_wake_by_address failed"
            )
            // The SDK gives the wake-all call the same early returns as the
            // wait: interrupted, or the kernel briefly short of memory. The
            // permits are already published, so abandoning the wake here would
            // leave sleepers parked on them; ask again instead.
        }
    }
}

// MARK: - Waiting on a Mach semaphore

extension _SemaphoreHandle {
    @usableFromInline
    internal borrowing func _waitBySemaphore() {
        let port = _semaphorePort()
        var result: kern_return_t
        repeat {
            result = semaphore_wait(port)
        } while result == KERN_ABORTED
        precondition(result == KERN_SUCCESS, "semaphore_wait failed")

        // The wait is the whole of this backend's ordering — a woken thread
        // reads whatever the signaller published without touching another
        // atomic first — and it is ordering ThreadSanitizer cannot see.
        // `CSynchronizationKitCore.h` records what it reports instead, and
        // how that was pinned on this backend. Nothing but the sanitizer
        // reads this.
        unsafe sk_tsan_acquire(UnsafeMutableRawPointer(_address()))
    }

    @usableFromInline
    internal borrowing func _signalBySemaphore(_ count: Int32) {
        // A signal can arrive before its counterpart blocks, and it may not be
        // dropped, so the signalling side creates the semaphore too.
        let port = _semaphorePort()

        // Before the signal, so that the edge is on record by the time anything
        // can wake on it.
        unsafe sk_tsan_release(UnsafeMutableRawPointer(_address()))

        for _ in 0 ..< count {
            semaphore_signal(port)
        }
    }

    /// The semaphore the word names, creating it if this is the first thread
    /// to need one.
    ///
    /// A port is an entry in the task's name space, and the kernel treats a
    /// process that fills its name space as leaking rather than as busy, so
    /// none is created until a thread actually has to wait or signal.
    private borrowing func _semaphorePort() -> semaphore_t {
        let existing = word.load(ordering: .relaxed)
        return existing != 0
            ? semaphore_t(truncatingIfNeeded: existing)
            : _createSemaphorePort(startingAt: 0)
    }

    private borrowing func _createSemaphorePort(startingAt value: Int32) -> semaphore_t {
        var created: semaphore_t = 0
        let result = unsafe semaphore_create(
            mach_task_self_, &created, SYNC_POLICY_FIFO, value
        )
        precondition(result == KERN_SUCCESS, "semaphore_create failed")

        // Relaxed is enough: the word carries a port name and nothing else, and
        // the kernel object it names is complete before `semaphore_create`
        // returns, so there is no user-space write for this store to publish.
        let (exchanged, current) = word.compareExchange(
            expected: 0,
            desired: UInt64(created),
            ordering: .relaxed
        )
        guard exchanged else {
            // Another thread got there first; hand this one back rather than
            // leaving it to occupy a port name for nothing.
            unsafe semaphore_destroy(mach_task_self_, created)
            return semaphore_t(truncatingIfNeeded: current)
        }

        return created
    }

    /// Releases the semaphore the word names, if one was ever created.
    private borrowing func _destroyAnySemaphore() {
        let name = word.load(ordering: .relaxed)
        if name != 0 {
            unsafe semaphore_destroy(mach_task_self_, semaphore_t(truncatingIfNeeded: name))
        }
    }
}
#elseif canImport(Glibc) || canImport(Android) || canImport(Musl) || canImport(wasi_pthread)
#if canImport(Glibc)
public import Glibc
#elseif canImport(Android)
public import Android
#elseif canImport(Musl)
public import Musl
#else
// Both: `sem_t` comes from one and the pthread support that makes it usable
// from the other, and the storage lands in a `@usableFromInline` property.
public import wasi_pthread
public import WASILibc
#endif
public import SynchronizationKitCore

/// A counting semaphore over an unnamed POSIX semaphore.
///
/// Every libc here implements these, and they are exactly what a counting
/// semaphore is, so there is nothing to build. The usual objection — a `sem_t`
/// must not move — does not apply: `@_rawLayout` storage combined with
/// `@_staticExclusiveOnly` pins its address for its lifetime.
@_staticExclusiveOnly
@usableFromInline
package struct _SemaphoreHandle: ~Copyable {
    @usableFromInline
    internal let value: _Cell<sem_t>

    @usableFromInline
    package init(value: Int) {
        precondition(
            value >= 0 && value <= Int32.max,
            "Semaphore requires an initial value in 0...Int32.max"
        )
        self.value = _Cell(sem_t())
        let result = unsafe sem_init(self.value._address, 0, UInt32(value))
        precondition(result == 0, "sem_init failed")
    }

    deinit {
        unsafe sem_destroy(value._address)
    }

    /// Blocks until a permit is available, then takes it.
    @usableFromInline
    package borrowing func _wait() {
        while unsafe sem_wait(value._address) != 0 {
            // The wait aborts when a signal lands; nothing else is expected.
            precondition(errno == EINTR, "sem_wait failed")
        }
    }

    /// Hands out `count` permits and wakes whoever can use them.
    ///
    /// - Precondition: `count` is positive.
    @usableFromInline
    package borrowing func _signal(_ count: Int32) {
        precondition(count > 0, "a semaphore cannot signal a non-positive number of permits")
        for _ in 0 ..< count {
            let result = unsafe sem_post(value._address)
            precondition(result == 0, "sem_post failed")
        }
    }

    /// Traps if the count has fallen below `initialValue`.
    @usableFromInline
    package borrowing func _checkNotInUse(since initialValue: Int32) {
        var count: Int32 = 0
        let result = unsafe sem_getvalue(value._address, &count)
        precondition(result == 0, "sem_getvalue failed")
        precondition(count >= initialValue, "Semaphore deallocated while in use")
    }
}
#elseif os(Windows)
// The handle to the kernel object is a stored property of a
// `@usableFromInline` type, so the module declaring its atomic wrapper is on
// this one's interface. Scoped to the one type: this tier stores nothing else
// from `Synchronization`.
public import struct Synchronization.Atomic
public import WinSDK

/// A counting semaphore over a Windows kernel semaphore object, created the
/// first time a thread needs it.
///
/// The kernel object is what `DispatchSemaphore` itself sits on for this
/// platform, minus Dispatch. It costs a handle per semaphore, which the
/// atomic-word approach Darwin takes would avoid — but that needs the address
/// of an atomic word, and on this tier `Atomic` is the standard library's,
/// which hands out no such thing. What it does hand out is enough for the
/// Mach path's other trick: the handle lives in an atomic, `nil` until a
/// thread has to block or signal, and is created with the count if that is
/// positive — so an `RWLock`, whose two gates start at zero, owns no kernel
/// object until it is contended, and locks in bulk stay cheap.
///
/// The kernel does not report a semaphore's count, so the in-use check has
/// nothing to read here.
///
/// `@safe`, with the handle and the two members that produce one marked
/// `@unsafe`: a `HANDLE` is a raw pointer to the compiler, and every read of
/// it is marked as such, but nothing here dereferences one — the kernel does.
@safe
@_staticExclusiveOnly
@usableFromInline
package struct _SemaphoreHandle: ~Copyable {
    /// The kernel object, or `nil` until a thread needs one.
    @unsafe
    @usableFromInline
    internal let object = unsafe Atomic<HANDLE?>(nil)

    @usableFromInline
    package init(value: Int) {
        precondition(
            value >= 0 && value <= Int32.max,
            "Semaphore requires an initial value in 0...Int32.max"
        )
        // A count of zero has nothing to hold yet. A positive one is created
        // with its object now, the way `DispatchSemaphore` does.
        if value > 0 {
            _ = unsafe _createObject(startingAt: LONG(value))
        }
    }

    deinit {
        if let handle = unsafe object.load(ordering: .relaxed) {
            _ = unsafe CloseHandle(handle)
        }
    }

    /// Blocks until a permit is available, then takes it.
    @usableFromInline
    package borrowing func _wait() {
        let result = unsafe WaitForSingleObject(_object(), INFINITE)
        precondition(result == WAIT_OBJECT_0, "WaitForSingleObject failed")
    }

    /// Hands out `count` permits and wakes whoever can use them.
    ///
    /// - Precondition: `count` is positive.
    @usableFromInline
    package borrowing func _signal(_ count: Int32) {
        precondition(count > 0, "a semaphore cannot signal a non-positive number of permits")
        // A signal can arrive before its counterpart blocks, and it may not be
        // dropped, so the signalling side creates the object too.
        let released = unsafe ReleaseSemaphore(_object(), LONG(count), nil)
        precondition(released, "ReleaseSemaphore failed")
    }

    /// Checks nothing: the kernel does not report the count.
    @usableFromInline
    package borrowing func _checkNotInUse(since initialValue: Int32) {}

    /// The kernel object, creating it if this is the first thread to need
    /// one.
    @unsafe
    private borrowing func _object() -> HANDLE {
        if let existing = unsafe object.load(ordering: .acquiring) {
            return unsafe existing
        }
        return unsafe _createObject(startingAt: 0)
    }

    @unsafe
    private borrowing func _createObject(startingAt value: LONG) -> HANDLE {
        guard let created = unsafe CreateSemaphoreW(nil, value, LONG.max, nil) else {
            preconditionFailure("CreateSemaphoreW failed")
        }

        // Relaxed would do, as on the Mach path: the kernel object is complete
        // before `CreateSemaphoreW` returns, and the handle is a value the
        // kernel resolves, so there is no user-space write for this store to
        // publish. Acquire/release costs nothing measurable on a path taken
        // once per semaphore, and spares a reader of this the argument.
        let (exchanged, current) = unsafe object.compareExchange(
            expected: nil,
            desired: created,
            ordering: .acquiringAndReleasing
        )
        guard exchanged else {
            // Another thread got there first; hand this one back rather than
            // leaving it to occupy a handle for nothing.
            _ = unsafe CloseHandle(created)
            // Non-nil: only a created handle is ever stored.
            return unsafe current!
        }

        return unsafe created
    }
}
#endif
