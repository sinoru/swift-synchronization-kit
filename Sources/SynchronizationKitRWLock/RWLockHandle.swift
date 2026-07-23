//
//  RWLockHandle.swift
//  SynchronizationKit
//

import SynchronizationKitCore

#if canImport(Darwin)
import Darwin
import SynchronizationKitAtomic
import SynchronizationKitMutex

/// The platform lock backing `RWLock` on Darwin.
///
/// Darwin's own `pthread_rwlock_t` collapses under contention — its reader
/// paths are compare-exchange loops over three shared sequence words, and any
/// failed acquisition goes straight to a psynch syscall with no userspace
/// spinning. This implementation keeps the reader fast path down to a single
/// wait-free atomic add on a signed counter: a writer announces itself by
/// subtracting a large constant, driving the counter negative, which is the
/// one condition the reader paths test. Writers serialize against each other
/// on the mutex handle, and two mach semaphores carry the sleep/wake handoff
/// between the last departing reader and a pending writer, and back. The
/// semaphores are the one part a mutex cannot provide: waking another thread
/// is a signaling operation, and `os_unfair_lock` may only be unlocked by the
/// thread that locked it.
///
/// The algorithm is writer-preferring: a blocked writer blocks new readers, so
/// writers cannot starve, and read locking is therefore not recursive.
@_staticExclusiveOnly
public struct _RWLockHandle: ~Copyable {
    /// The reader count runs 0...`_maxReaders` while no writer is pending. A
    /// writer announces itself by subtracting `_maxReaders`, driving the count
    /// negative, which is what the reader fast paths key off.
    @usableFromInline
    internal static var _maxReaders: Int32 {
        1 << 30
    }

    /// Held for the duration of a write lock; serializes writers against each
    /// other. Locked and unlocked by the same thread, which is what makes the
    /// unfair lock backing `Mutex` (with its priority donation) usable here.
    @usableFromInline
    internal let writerMutex = _MutexHandle()

    /// Number of readers holding or waiting for the lock, minus `_maxReaders`
    /// while a writer is pending.
    @usableFromInline
    internal let readerCount = Atomic<Int32>(0)

    /// Number of active readers a pending writer still has to wait out.
    @usableFromInline
    internal let readerWait = Atomic<Int32>(0)

    /// Where a pending writer sleeps until the last active reader departs.
    @usableFromInline
    internal let writerSem: semaphore_t

    /// Where pending readers sleep until the active writer departs.
    @usableFromInline
    internal let readerSem: semaphore_t

    public init() {
        var semaphore: semaphore_t = 0
        var result = unsafe semaphore_create(mach_task_self_, &semaphore, SYNC_POLICY_FIFO, 0)
        precondition(result == KERN_SUCCESS, "semaphore_create failed")
        writerSem = semaphore

        result = unsafe semaphore_create(mach_task_self_, &semaphore, SYNC_POLICY_FIFO, 0)
        precondition(result == KERN_SUCCESS, "semaphore_create failed")
        readerSem = semaphore
    }

    deinit {
        unsafe semaphore_destroy(mach_task_self_, writerSem)
        unsafe semaphore_destroy(mach_task_self_, readerSem)
    }

    private static func _wait(on semaphore: semaphore_t) {
        var result: kern_return_t
        repeat {
            result = semaphore_wait(semaphore)
        } while result == KERN_ABORTED
        precondition(result == KERN_SUCCESS, "semaphore_wait failed")
    }

    @usableFromInline
    internal borrowing func _readLock() {
        if readerCount.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue < 0 {
            // A negative count means a writer holds or awaits the lock; sleep
            // until it departs. The increment above already registered this
            // reader, so the writer's unlock knows how many to wake.
            Self._wait(on: readerSem)
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
            semaphore_signal(writerSem)
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
            Self._wait(on: writerSem)
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
        precondition(count < Self._maxReaders, "writeUnlock of an RWLock that is not write-locked")
        // Wake every one of them; they all hold the lock together.
        for _ in 0..<count {
            semaphore_signal(readerSem)
        }
        // Release writer-writer exclusion last, so a next writer starts from
        // a consistent counter.
        writerMutex._unlock()
    }
}
#elseif canImport(Glibc) || canImport(Musl) || canImport(Android) || canImport(wasi_pthread)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#else
import wasi_pthread
#endif

/// The platform lock backing `RWLock` on POSIX platforms other than Darwin.
///
/// Unlike Darwin's, these `pthread_rwlock_t` implementations (glibc, musl,
/// bionic, wasi-libc) are futex-based and behave reasonably under contention,
/// so the portable primitive is used directly. The usual objection — a pthread
/// lock must not move — does not apply here: `@_rawLayout` storage combined
/// with `@_staticExclusiveOnly` pins the lock's address for its lifetime.
@_staticExclusiveOnly
public struct _RWLockHandle: ~Copyable {
    @usableFromInline
    internal let lock: _Cell<pthread_rwlock_t>

    public init() {
        lock = _Cell(pthread_rwlock_t())
        let result = unsafe pthread_rwlock_init(lock._address, nil)
        precondition(result == 0, "pthread_rwlock_init failed")
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
/// Degrading this way is contract-preserving: concurrent readers are a
/// permission the API grants, never a guarantee, and recursive read locking is
/// already forbidden by `RWLock`'s writer-preferring contract. What is lost is
/// only reader parallelism, not correctness.
@_staticExclusiveOnly
public struct _RWLockHandle: ~Copyable {
    @usableFromInline
    internal let mutex = Mutex<Void>(())

    public init() {}

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
