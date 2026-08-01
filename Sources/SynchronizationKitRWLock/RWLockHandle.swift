//
//  RWLockHandle.swift
//  SynchronizationKit
//

import SynchronizationKitCore

#if canImport(Darwin) || canImport(Musl) || canImport(wasi_pthread)
#if canImport(Darwin)
// The handle's counters and its writer-side mutex are stored properties of a
// `@usableFromInline` type, so those two modules are on this one's interface.
// The shim and `Darwin` are not: nothing here is inlined into a caller, so the
// calls into them stay inside this module. Inlining one would be an error
// rather than a silent leak — though not this error first. Every member here is
// `@usableFromInline`, which `@inline(always)` refuses to sit beside, so that
// diagnostic comes up before the import one; `@inlinable` is the spelling that
// reaches it.
import CSynchronizationKitRWLock
import Darwin
public import SynchronizationKitAtomic
public import SynchronizationKitMutex
#else
#if canImport(Musl)
import Musl
#else
import wasi_pthread
import WASILibc
#endif
// Scoped deliberately: `Synchronization` also exports a `_Cell` of its own,
// which a whole-module import would make ambiguous with the package's.
import struct Synchronization.Atomic
#endif

#if canImport(Darwin)
/// The counter type backing the handle.
///
/// This package's own `Atomic` deliberately: SwiftPM builds a package at the
/// deployment targets its manifest declares, which sit below every version
/// where the type's deprecation begins, so the warning never fires here. The
/// release that moves the minimums past those versions must point this alias
/// at `Synchronization.Atomic` instead.
@usableFromInline
internal typealias _AtomicCounter = SynchronizationKitAtomic.Atomic<Int32>

/// What serializes writers: the unfair lock backing `Mutex`, whose priority
/// donation is usable here because a write lock is released by the thread
/// that took it.
@usableFromInline
internal typealias _WriterMutex = _MutexHandle

/// The type of a word threads wait on.
///
/// This package's own `Atomic`, for the reason given over `_AtomicCounter`,
/// plus one specific to this use: address-based waiting needs the address of
/// the storage itself, which only this type hands out.
@usableFromInline
internal typealias _AtomicWord = SynchronizationKitAtomic.Atomic<UInt32>

/// Whether waits go to an address rather than to a Mach semaphore.
///
/// Resolved once. It depends only on the version of the OS the process is
/// running on, which cannot change underneath it.
@usableFromInline
internal let _addressWaitIsAvailable: Bool = sk_rwlock_address_wait_is_available()
#else
/// The counter type backing the handle.
///
/// The standard library's `Atomic` directly: on these platforms the Swift
/// runtime ships with the application, so it is available at every deployment
/// target and this package's own `Atomic` never comes into play.
@usableFromInline
internal typealias _AtomicCounter = Synchronization.Atomic<Int32>

/// What serializes writers; locked and unlocked by the same thread.
@_staticExclusiveOnly
@usableFromInline
internal struct _WriterMutex: ~Copyable {
    @usableFromInline
    internal let value: _Cell<pthread_mutex_t>

    @usableFromInline
    internal init() {
        value = _Cell(pthread_mutex_t())
        let result = unsafe pthread_mutex_init(value._address, nil)
        precondition(result == 0, "pthread_mutex_init failed")
    }

    deinit {
        unsafe pthread_mutex_destroy(value._address)
    }

    @usableFromInline
    internal borrowing func _lock() {
        let result = unsafe pthread_mutex_lock(value._address)
        precondition(result == 0, "pthread_mutex_lock failed")
    }

    @usableFromInline
    internal borrowing func _tryLock() -> Bool {
        unsafe pthread_mutex_trylock(value._address) == 0
    }

    @usableFromInline
    internal borrowing func _unlock() {
        let result = unsafe pthread_mutex_unlock(value._address)
        precondition(result == 0, "pthread_mutex_unlock failed")
    }
}
#endif

/// The platform lock backing `RWLock` where the system-provided one would
/// break its contract.
///
/// Darwin's `pthread_rwlock_t` collapses under contention — its reader paths
/// are compare-exchange loops over three shared sequence words, and any
/// failed acquisition goes straight to a psynch syscall with no userspace
/// spinning. musl's and wasi-libc's grant a reader the lock even while a
/// writer waits and, unlike glibc's and bionic's, accept no lock-kind
/// attribute to change that, which would let readers starve a writer
/// indefinitely, contradicting the writer-preferring contract `RWLock`
/// documents.
///
/// So the lock is built here instead. The reader fast path is a single
/// wait-free atomic add on a signed counter: a writer announces itself by
/// subtracting a large constant, driving the counter negative, which is the
/// one condition the reader paths test. Writers serialize against each other
/// on `_WriterMutex`, and two gates carry the sleep/wake handoff between the
/// last departing reader and a pending writer, and back. The gates are the one
/// part the mutex cannot provide: waking another thread is a signaling
/// operation, and the writer mutex may only be released by the thread that
/// locked it.
///
/// A gate hands out permits rather than reporting a condition, which is what
/// lets the handoffs stay this simple: a signal that arrives before its
/// counterpart blocks is held rather than lost, so neither side has to re-check
/// anything on waking. `RWLockHandle+Waiting.swift` is what carries those
/// permits on each OS; this file is only about when they change hands.
///
/// The algorithm is writer-preferring: a blocked writer blocks new readers, so
/// writers cannot starve, and read locking is therefore not recursive.
@_staticExclusiveOnly
@usableFromInline
internal struct _RWLockHandle: ~Copyable {
    /// The reader count runs 0...`_maxReaders` while no writer is pending. A
    /// writer announces itself by subtracting `_maxReaders`, driving the count
    /// negative, which is what the reader fast paths key off.
    @usableFromInline
    internal static var _maxReaders: Int32 {
        1 << 30
    }

    /// Held for the duration of a write lock; serializes writers against each
    /// other.
    @usableFromInline
    internal let writerMutex = _WriterMutex()

    /// Number of readers holding or waiting for the lock, minus `_maxReaders`
    /// while a writer is pending.
    @usableFromInline
    internal let readerCount = _AtomicCounter(0)

    /// Number of active readers a pending writer still has to wait out.
    @usableFromInline
    internal let readerWait = _AtomicCounter(0)

    #if canImport(Darwin)
    /// Where a pending writer sleeps until the last active reader departs.
    ///
    /// One 32-bit word, read one of two ways depending on `usesAddressWait`:
    /// as the number of permits outstanding, which threads block on directly,
    /// or as the Mach port name of the semaphore holding those permits —
    /// `MACH_PORT_NULL` until the first thread has to block. The two readings
    /// never mix; which applies follows from the running OS, and both start at
    /// zero. See `RWLockHandle+Waiting.swift`.
    @usableFromInline
    internal let writerWord = _AtomicWord(0)

    /// Where pending readers sleep until the active writer departs, read the
    /// same two ways as `writerWord`.
    @usableFromInline
    internal let readerWord = _AtomicWord(0)

    /// Which reading of the two words above applies, and so which way a thread
    /// waits.
    ///
    /// Answered once per handle rather than at each of the four wait sites, and
    /// stored beside the words it describes and the `deinit` that acts on it, so
    /// that nothing has to pass it around or agree about it. It costs nothing:
    /// the byte lands in padding the handle already had.
    ///
    /// Nothing can set this to anything but what the OS provides. A handle
    /// forced onto the address-based path on a release predating it would fault
    /// on the first call that had to block, and one forced the other way would
    /// exercise a configuration that ships nowhere.
    @usableFromInline
    internal let usesAddressWait: Bool = _addressWaitIsAvailable

    @usableFromInline
    internal init() {}

    deinit {
        // Only the semaphore reading of the words owns anything.
        if !usesAddressWait {
            _destroyAnySemaphore(writerWord)
            _destroyAnySemaphore(readerWord)
        }
    }
    #else
    /// Where a pending writer sleeps until the last active reader departs.
    ///
    /// musl and wasi-libc implement unnamed POSIX semaphores, which is exactly
    /// what these handoffs need, so there is nothing to build. Darwin's are
    /// declared deprecated and unimplemented, which is why its own waiting looks
    /// nothing like this.
    @usableFromInline
    internal let writerSemaphore: _Cell<sem_t>

    /// Where pending readers sleep until the active writer departs.
    @usableFromInline
    internal let readerSemaphore: _Cell<sem_t>

    @usableFromInline
    internal init() {
        writerSemaphore = _Cell(sem_t())
        readerSemaphore = _Cell(sem_t())
        let writerResult = unsafe sem_init(writerSemaphore._address, 0, 0)
        precondition(writerResult == 0, "sem_init failed")
        let readerResult = unsafe sem_init(readerSemaphore._address, 0, 0)
        precondition(readerResult == 0, "sem_init failed")
    }

    deinit {
        unsafe sem_destroy(writerSemaphore._address)
        unsafe sem_destroy(readerSemaphore._address)
    }
    #endif

    @usableFromInline
    internal borrowing func _readLock() {
        if readerCount.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue < 0 {
            // A negative count means a writer holds or awaits the lock; sleep
            // until it departs. The increment above already registered this
            // reader, so the writer's unlock knows how many permits to hand out.
            _acquireReaderGate()
        }
    }

    @usableFromInline
    internal borrowing func _tryReadLock() -> Bool {
        var count = readerCount.load(ordering: .relaxed)
        while true {
            if count < 0 {
                // A writer holds or is waiting for the lock.
                return false
            }
            let (exchanged, original) = readerCount.compareExchange(
                expected: count,
                desired: count + 1,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                return true
            }
            count = original
        }
    }

    @usableFromInline
    internal borrowing func _readUnlock() {
        let count = readerCount.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue
        if count < 0 {
            _readUnlockSlow(count)
        }
    }

    private borrowing func _readUnlockSlow(_ count: Int32) {
        precondition(
            count &+ 1 != 0 && count &+ 1 != -Self._maxReaders,
            "readUnlock of an RWLock that is not read-locked"
        )
        // The count went negative, so a writer is waiting for the readers that
        // were active when it arrived; whichever of them brings `readerWait`
        // to zero hands the lock over.
        if readerWait.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            _releaseWriterGate(1)
        }
    }

    @usableFromInline
    internal borrowing func _writeLock() {
        // Only one writer proceeds past this point at a time.
        writerMutex._lock()
        // Drive the reader count negative so new readers queue up; what the
        // subtraction returns is the number of readers that were active at
        // that instant.
        let count = readerCount.wrappingSubtract(
            Self._maxReaders, ordering: .acquiringAndReleasing
        ).newValue &+ Self._maxReaders
        // Those readers must drain before the write lock is held. Registering
        // them in `readerWait` can race with them departing; if the count hits
        // zero right here, the last one has already signaled.
        if count != 0,
            readerWait.wrappingAdd(count, ordering: .acquiringAndReleasing).newValue != 0
        {
            _acquireWriterGate()
        }
    }

    @usableFromInline
    internal borrowing func _tryWriteLock() -> Bool {
        guard writerMutex._tryLock() else {
            return false
        }
        guard
            readerCount.compareExchange(
                expected: 0,
                desired: -Self._maxReaders,
                ordering: .acquiringAndReleasing
            ).exchanged
        else {
            writerMutex._unlock()
            return false
        }
        return true
    }

    @usableFromInline
    internal borrowing func _writeUnlock() {
        // Return the reader count to its non-negative range; what the addition
        // returns is the number of readers that queued up behind this writer.
        let count = readerCount.wrappingAdd(
            Self._maxReaders, ordering: .acquiringAndReleasing
        ).newValue
        // Both bounds matter. A negative count takes memory corruption to
        // reach, but the release below is guarded on being positive, so without
        // the lower bound that state parks every queued reader forever instead
        // of trapping — the least diagnosable way for a lock to fail.
        precondition(
            count >= 0 && count < Self._maxReaders,
            "writeUnlock of an RWLock that is not write-locked"
        )
        // Release every one of them at once; they all hold the lock together.
        if count > 0 {
            _releaseReaderGate(count)
        }
        // Release writer-writer exclusion last, so a next writer starts from
        // a consistent counter.
        writerMutex._unlock()
    }
}
#elseif canImport(Glibc) || canImport(Android)
#if canImport(Glibc)
import Glibc
#else
import Android
#endif

/// The platform lock backing `RWLock` where glibc or bionic provides
/// `pthread_rwlock_t`.
///
/// Unlike Darwin's, these implementations are futex-based and behave
/// reasonably under contention, so the portable primitive is used directly —
/// with one adjustment. Both default to reader preference: a reader is
/// granted the lock even while a writer waits, which would let readers starve
/// a writer indefinitely, contradicting the writer-preferring contract
/// `RWLock` documents. Both also accept the writer-nonrecursive lock kind,
/// which makes a waiting writer block new readers; its one restriction — read
/// locking must not be recursive — is a rule `RWLock`'s contract already
/// imposes, so the kind is applied unconditionally.
///
/// The usual objection — a pthread lock must not move — does not apply here:
/// `@_rawLayout` storage combined with `@_staticExclusiveOnly` pins the
/// lock's address for its lifetime.
@_staticExclusiveOnly
@usableFromInline
internal struct _RWLockHandle: ~Copyable {
    @usableFromInline
    internal let lock: _Cell<pthread_rwlock_t>

    @usableFromInline
    internal init() {
        lock = _Cell(pthread_rwlock_t())
        var attributes = pthread_rwlockattr_t()
        var result = unsafe pthread_rwlockattr_init(&attributes)
        precondition(result == 0, "pthread_rwlockattr_init failed")
        result = unsafe pthread_rwlockattr_setkind_np(
            &attributes,
            numericCast(PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP)
        )
        precondition(result == 0, "pthread_rwlockattr_setkind_np failed")
        result = unsafe pthread_rwlock_init(lock._address, &attributes)
        precondition(result == 0, "pthread_rwlock_init failed")
        unsafe pthread_rwlockattr_destroy(&attributes)
    }

    deinit {
        unsafe pthread_rwlock_destroy(lock._address)
    }

    @usableFromInline
    internal borrowing func _readLock() {
        let result = unsafe pthread_rwlock_rdlock(lock._address)
        precondition(result == 0, "pthread_rwlock_rdlock failed")
    }

    @usableFromInline
    internal borrowing func _tryReadLock() -> Bool {
        unsafe pthread_rwlock_tryrdlock(lock._address) == 0
    }

    @usableFromInline
    internal borrowing func _readUnlock() {
        let result = unsafe pthread_rwlock_unlock(lock._address)
        precondition(result == 0, "pthread_rwlock_unlock failed")
    }

    @usableFromInline
    internal borrowing func _writeLock() {
        let result = unsafe pthread_rwlock_wrlock(lock._address)
        precondition(result == 0, "pthread_rwlock_wrlock failed")
    }

    @usableFromInline
    internal borrowing func _tryWriteLock() -> Bool {
        unsafe pthread_rwlock_trywrlock(lock._address) == 0
    }

    @usableFromInline
    internal borrowing func _writeUnlock() {
        let result = unsafe pthread_rwlock_unlock(lock._address)
        precondition(result == 0, "pthread_rwlock_unlock failed")
    }
}
#else
import Synchronization

/// The fallback backing for `RWLock` on platforms with neither a tuned
/// implementation nor pthreads (Windows and embedded targets, currently).
///
/// Every acquisition — read or write — takes the same exclusive `Mutex`.
/// Mutual exclusion is unaffected, and so is the rest of the safety half of the
/// contract: concurrent readers are a permission the API grants, never a
/// guarantee, and recursive read locking is already forbidden by `RWLock`'s
/// writer-preferring contract. What the degradation does drop is writer
/// preference — there is no pending-writer state for a plain `Mutex` to expose,
/// so a writer contends with readers on equal terms instead of ahead of them,
/// and `_tryReadLock` can succeed while a writer is blocked.
///
/// Restoring it here would take a blocking wait, and this tier has nothing to
/// build one from — no semaphore, no condition variable — which is the reason
/// it is the fallback in the first place.
@_staticExclusiveOnly
@usableFromInline
internal struct _RWLockHandle: ~Copyable {
    @usableFromInline
    internal let mutex = Mutex<Void>(())

    @usableFromInline
    internal init() {}

    @usableFromInline
    internal borrowing func _readLock() {
        mutex._unsafeLock()
    }

    @usableFromInline
    internal borrowing func _tryReadLock() -> Bool {
        mutex._unsafeTryLock()
    }

    @usableFromInline
    internal borrowing func _readUnlock() {
        mutex._unsafeUnlock()
    }

    @usableFromInline
    internal borrowing func _writeLock() {
        mutex._unsafeLock()
    }

    @usableFromInline
    internal borrowing func _tryWriteLock() -> Bool {
        mutex._unsafeTryLock()
    }

    @usableFromInline
    internal borrowing func _writeUnlock() {
        mutex._unsafeUnlock()
    }
}
#endif
