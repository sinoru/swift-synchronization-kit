//
//  RWLockHandle.swift
//  SynchronizationKit
//

// `SynchronizationKitCore` is imported by the one backend that stores a
// `_Cell` — glibc's and bionic's, around their `pthread_rwlock_t` — and there
// as `public import`, since the cell lands on this module's interface. The
// other two never name one, and a file-scope public import would draw a
// warning in each for going unused.

#if canImport(Darwin) || canImport(Musl) || canImport(wasi_pthread) || os(Windows)
// The handle's counters, its writer-side mutex and its two gates are stored
// properties of a `@usableFromInline` type, so the modules declaring them are
// on this one's interface.
//
// This package's own `Atomic` and `Mutex`, deliberately, and the same source
// on every platform this backend builds for. On Apple platforms they are the
// package's implementations; everywhere else the two modules re-export the
// standard library's types. What this backend is built from is thus decided
// once, by them, and not again here.
public import SynchronizationKitAtomic
public import SynchronizationKitMutex
public import SynchronizationKitSemaphore

/// The counter type backing the handle.
@usableFromInline
internal typealias _AtomicCounter = SynchronizationKitAtomic.Atomic<Int32>

/// What serializes writers; locked and unlocked by the same thread.
///
/// Spelled through its module, as the counter is: off Apple platforms the
/// module re-exports the standard library's type, and a bare `Mutex` would
/// leave the import above looking unused to the compiler.
@usableFromInline
internal typealias _WriterMutex = SynchronizationKitMutex.Mutex<Void>

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
/// documents. Windows's `SRWLOCK` has a shared mode, and documents it as
/// neither fair nor ordered, which is the same objection.
///
/// So the lock is built here instead. While no writer is about, a reader
/// publishes itself in the shared slot table `_ReaderBias` describes and
/// touches nothing another reader touches. Otherwise it is counted: a single
/// wait-free atomic add on a signed counter, which a writer announces itself
/// on by subtracting a large constant, driving the counter negative, which is
/// the one condition the counted reader paths test. Writers serialize against
/// each other on a `Mutex`, and two gates carry the sleep/wake handoff between
/// the last departing reader and a pending writer, and back. The gates are the
/// one part the mutex cannot provide: waking another thread is a signaling
/// operation, and the writer mutex may only be released by the thread that
/// locked it.
///
/// Each gate is a `Semaphore`, and hands out permits rather than reporting a
/// condition, which is what lets the handoffs stay this simple: a signal that
/// arrives before its counterpart blocks is held rather than lost, so neither
/// side has to re-check anything on waking. How a thread sleeps on a permit
/// and how it is woken is the semaphore's business, and differs per OS; this
/// file is only about when permits change hands.
///
/// The algorithm is writer-preferring: a blocked writer blocks new readers, so
/// writers cannot starve, and read locking is therefore not recursive.
///
/// The entry points are `@inline(always)`, as `_MutexHandle`'s are, and
/// `package` for the same reason: each is an atomic operation or two and a
/// branch, and inlined into the client they are compiled for the client's
/// deployment target, where a target new enough gets single-instruction
/// atomics that this package's own minimum does not. What follows the branch
/// — sleeping on a gate, waking the last reader's writer — stays out of line,
/// behind a call.
@_staticExclusiveOnly
@usableFromInline
package struct _RWLockHandle: ~Copyable {
    /// The reader count runs 0...`_maxReaders` while no writer is pending. A
    /// writer announces itself by subtracting `_maxReaders`, driving the count
    /// negative, which is what the reader fast paths key off.
    ///
    /// `@inline(always)` and `package`, as the entry points are, so that the
    /// constant folds into them by guarantee; `_ReaderBias` says more.
    @inline(always)
    package static var _maxReaders: Int32 {
        1 << 30
    }

    /// Held for the duration of a write lock; serializes writers against each
    /// other.
    ///
    /// Taken through the entry points that leave the critical section to the
    /// caller, since a write lock is released by another method than the one
    /// that took it — by the same thread, though, which is what those entry
    /// points require, and on Darwin what lets the unfair lock's priority
    /// donation apply.
    @usableFromInline
    internal let writerMutex = _WriterMutex(())

    /// Number of readers holding or waiting for the lock, minus `_maxReaders`
    /// while a writer is pending.
    @usableFromInline
    internal let readerCount = _AtomicCounter(0)

    /// Number of active readers a pending writer still has to wait out.
    @usableFromInline
    internal let readerWait = _AtomicCounter(0)

    /// Where a pending writer sleeps until the last active reader departs.
    @usableFromInline
    internal let writerGate = _SemaphoreHandle(value: 0)

    /// Where pending readers sleep until the active writer departs.
    @usableFromInline
    internal let readerGate = _SemaphoreHandle(value: 0)

    /// Whether readers may publish themselves rather than be counted, and
    /// the bookkeeping behind that.
    @usableFromInline
    internal let bias = _ReaderBias()

    @usableFromInline
    package init() {}

    /// Takes the lock for reading, and returns where the reader published
    /// itself, or `nil` if it was counted instead; `_readUnlock` takes the
    /// answer back.
    @inline(always)
    package borrowing func _readLock() -> _ReaderSlot? {
        if let slot = unsafe bias._enter() {
            return unsafe slot
        }
        _turnOnIfDue()
        if readerCount.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue < 0 {
            // A negative count means a writer holds or awaits the lock; sleep
            // until it departs. The increment above already registered this
            // reader, so the writer's unlock knows how many permits to hand out.
            readerGate._wait()
        }
        return nil
    }

    /// `_readLock` without the wait: whether the lock was taken, and if so
    /// where the reader published itself, as `_readLock` reports.
    @inline(always)
    package borrowing func _tryReadLock() -> (acquired: Bool, slot: _ReaderSlot?) {
        if let slot = unsafe bias._enter() {
            return unsafe (true, slot)
        }
        _turnOnIfDue()
        var count = readerCount.load(ordering: .relaxed)
        while true {
            if count < 0 {
                // A writer holds or is waiting for the lock.
                return (false, nil)
            }
            let (exchanged, original) = readerCount.compareExchange(
                expected: count,
                desired: count + 1,
                ordering: .acquiringAndReleasing
            )
            if exchanged {
                return (true, nil)
            }
            count = original
        }
    }

    /// Turns the table back on, on the way to being counted, if its spell has
    /// passed and no writer is about — which is what holding the writer mutex
    /// for a moment establishes; a writer holds it from before it turns the
    /// table off until after it has released the count.
    @usableFromInline
    internal borrowing func _turnOnIfDue() {
        guard let state = bias._due(), writerMutex._unsafeTryLock() else {
            return
        }
        bias._turnOn(from: state)
        writerMutex._unsafeUnlock()
    }

    @inline(always)
    package borrowing func _readUnlock(_ slot: _ReaderSlot?) {
        if let slot = unsafe slot {
            unsafe bias._leave(slot)
            return
        }
        let count = readerCount.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue
        if count < 0 {
            _readUnlockSlow(count)
        }
    }

    @usableFromInline
    internal borrowing func _readUnlockSlow(_ count: Int32) {
        precondition(
            count &+ 1 != 0 && count &+ 1 != -Self._maxReaders,
            "readUnlock of an RWLock that is not read-locked"
        )
        // The count went negative, so a writer is waiting for the readers that
        // were active when it arrived; whichever of them brings `readerWait`
        // to zero hands the lock over.
        if readerWait.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            writerGate._signal(1)
        }
    }

    @inline(always)
    package borrowing func _writeLock() {
        // Only one writer proceeds past this point at a time.
        writerMutex._unsafeLock()
        // Drive the reader count negative so new readers queue up; what the
        // subtraction returns is the number of readers that were active at
        // that instant.
        let count = readerCount.wrappingSubtract(
            Self._maxReaders, ordering: .acquiringAndReleasing
        ).newValue &+ Self._maxReaders
        // The published readers must drain too, and are waited out first: a
        // reader turned away from publishing by this is counted, and queues
        // behind the announcement above.
        _ = bias._revoke(waiting: true)
        // The counted readers must drain before the write lock is held.
        // Registering them in `readerWait` can race with them departing; if
        // the count hits zero right here, the last one has already signaled.
        if count != 0,
            readerWait.wrappingAdd(count, ordering: .acquiringAndReleasing).newValue != 0
        {
            writerGate._wait()
        }
    }

    @inline(always)
    package borrowing func _tryWriteLock() -> Bool {
        guard writerMutex._unsafeTryLock() else {
            return false
        }
        guard
            readerCount.compareExchange(
                expected: 0,
                desired: -Self._maxReaders,
                ordering: .acquiringAndReleasing
            ).exchanged
        else {
            writerMutex._unsafeUnlock()
            return false
        }
        // A published reader is as much in the way as a counted one, but there
        // is no waiting here; the count announcement has to be taken back the
        // way a write unlock takes it back, since readers may have queued
        // behind it meanwhile.
        guard bias._revoke(waiting: false) else {
            _releaseCount()
            return false
        }
        return true
    }

    @inline(always)
    package borrowing func _writeUnlock() {
        bias._restore()
        _releaseCount()
    }

    /// The counted half of a write unlock: lets the readers queued behind the
    /// writer's announcement in, and gives up writer-writer exclusion.
    @inline(always)
    package borrowing func _releaseCount() {
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
            readerGate._signal(count)
        }
        // Release writer-writer exclusion last, so a next writer starts from
        // a consistent counter.
        writerMutex._unsafeUnlock()
    }
}
#elseif canImport(Glibc) || canImport(Android)
#if canImport(Glibc)
public import Glibc
#else
public import Android
#endif
// The pending-writer count and the mutex around turning the table off are
// reached only from this backend's out-of-line bodies, so the modules
// declaring them stay off this one's interface.
import SynchronizationKitAtomic
public import SynchronizationKitCore
import SynchronizationKitMutex

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
///
/// The pthread lock counts its readers in one shared word, as `_ReaderBias`
/// describes, so readers publish themselves in front of it here as they do on
/// the built backend, and reach the pthread lock only while a writer is about.
///
/// A writer turns the table off *before* it asks for the pthread lock, not
/// after: the ask can block behind a reader that was counted, and a writer
/// blocked there with the table still on would be overtaken by every reader
/// that publishes meanwhile, which is what the lock-kind attribute exists to
/// prevent for the counted ones. The pthread lock does not know the writer
/// until the ask, though, so the writers count themselves, and a mutex of
/// the handle's own stands in for the lock up to then: a writer holds it
/// from before it turns the table off until the ask returns, and a reader
/// turned away from the table, finding the count above zero, waits on it
/// before asking for the pthread lock rather than overtake a writer scanning
/// or asking — or, from the non-blocking entry point, reports the writer as
/// in the way, as the pthread lock would once asked. A reader finding the
/// count at zero asks the pthread lock directly, and touches the mutex only
/// to turn the table back on. The same mutex is what makes turning the table
/// off safe to skip when it is found off, and turning it back on safe at
/// all; and since two writers may have turned it off before either holds
/// the lock, the first to leave leaves the marking to the last.
@_staticExclusiveOnly
@usableFromInline
internal struct _RWLockHandle: ~Copyable {
    @usableFromInline
    internal let lock: _Cell<pthread_rwlock_t>

    /// Whether readers may publish themselves rather than take the pthread
    /// lock, and the bookkeeping behind that.
    @usableFromInline
    internal let bias = _ReaderBias()

    /// Writers waiting for or holding the pthread lock.
    internal let pendingWriters = SynchronizationKitAtomic.Atomic<Int32>(0)

    /// Held by a writer from before it turns the table off until it holds the
    /// pthread lock, and waited on by a reader that finds a writer pending;
    /// the handle's note says why.
    internal let revocation = SynchronizationKitMutex.Mutex<Void>(())

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

    /// Takes the lock for reading, and returns where the reader published
    /// itself, or `nil` if it took the pthread lock instead; `_readUnlock`
    /// takes the answer back.
    @usableFromInline
    internal borrowing func _readLock() -> _ReaderSlot? {
        if let slot = unsafe bias._enter() {
            return unsafe slot
        }
        if pendingWriters.load(ordering: .acquiring) > 0 {
            // Wait the writer out here, where it is known, rather than
            // overtake it on the pthread lock, where it may not be yet.
            revocation._unsafeLock()
            revocation._unsafeUnlock()
        } else {
            _turnOnIfDue()
        }
        let result = unsafe pthread_rwlock_rdlock(lock._address)
        precondition(result == 0, "pthread_rwlock_rdlock failed")
        return nil
    }

    @usableFromInline
    internal borrowing func _tryReadLock() -> (acquired: Bool, slot: _ReaderSlot?) {
        if let slot = unsafe bias._enter() {
            return unsafe (true, slot)
        }
        guard pendingWriters.load(ordering: .acquiring) == 0 else {
            return (false, nil)
        }
        _turnOnIfDue()
        return (unsafe pthread_rwlock_tryrdlock(lock._address) == 0, nil)
    }

    /// Turns the table back on if its spell has passed and no writer is
    /// waiting or holding — decided under `revocation`, which is what keeps
    /// the count of writers from changing underneath the check. A reader
    /// that cannot take the mutex leaves the turning on to whoever holds it:
    /// a writer, which is about to turn the table off anyway, or a reader,
    /// which is turning it on.
    @usableFromInline
    internal borrowing func _turnOnIfDue() {
        guard let state = bias._due(), revocation._unsafeTryLock() else {
            return
        }
        if pendingWriters.load(ordering: .acquiring) == 0 {
            bias._turnOn(from: state)
        }
        revocation._unsafeUnlock()
    }

    @usableFromInline
    internal borrowing func _readUnlock(_ slot: _ReaderSlot?) {
        if let slot = unsafe slot {
            unsafe bias._leave(slot)
            return
        }
        let result = unsafe pthread_rwlock_unlock(lock._address)
        precondition(result == 0, "pthread_rwlock_unlock failed")
    }

    @usableFromInline
    internal borrowing func _writeLock() {
        revocation._unsafeLock()
        pendingWriters.wrappingAdd(1, ordering: .acquiringAndReleasing)
        // Readers turned away from publishing by this wait on `revocation`,
        // and then on the pthread lock, where the writer asking below is
        // ahead of them. The table stays off until the last pending writer
        // leaves, so there is nothing to turn off again once the lock is
        // held.
        _ = bias._revoke(waiting: true)
        let result = unsafe pthread_rwlock_wrlock(lock._address)
        precondition(result == 0, "pthread_rwlock_wrlock failed")
        revocation._unsafeUnlock()
    }

    @usableFromInline
    internal borrowing func _tryWriteLock() -> Bool {
        guard unsafe pthread_rwlock_trywrlock(lock._address) == 0 else {
            return false
        }
        // A writer turning the table off is a writer in the way, as much as
        // one holding the lock.
        guard revocation._unsafeTryLock() else {
            let result = unsafe pthread_rwlock_unlock(lock._address)
            precondition(result == 0, "pthread_rwlock_unlock failed")
            return false
        }
        pendingWriters.wrappingAdd(1, ordering: .acquiringAndReleasing)
        guard bias._revoke(waiting: false) else {
            pendingWriters.wrappingSubtract(1, ordering: .acquiringAndReleasing)
            revocation._unsafeUnlock()
            let result = unsafe pthread_rwlock_unlock(lock._address)
            precondition(result == 0, "pthread_rwlock_unlock failed")
            return false
        }
        revocation._unsafeUnlock()
        return true
    }

    @usableFromInline
    internal borrowing func _writeUnlock() {
        if pendingWriters.wrappingSubtract(1, ordering: .acquiringAndReleasing).newValue == 0 {
            bias._restore()
        }
        let result = unsafe pthread_rwlock_unlock(lock._address)
        precondition(result == 0, "pthread_rwlock_unlock failed")
    }
}
#else
// No `SynchronizationKitCore` here. This backend stores a `Mutex` and never
// names `_Cell`, so it needs nothing from that module — and the pairing is one
// to leave alone regardless: a musl leg once failed to build with a
// whole-module `Synchronization` beside the package's own storage cell, which
// exports a `_Cell` of its own.
public import Synchronization

/// Where a reader on this backend publishes itself: nowhere, as the handle
/// explains.
@usableFromInline
internal typealias _ReaderSlot = Never

/// The fallback backing for `RWLock` on platforms with neither a tuned
/// implementation nor a `Semaphore` to build one from (embedded targets,
/// currently).
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
///
/// Readers publish themselves nowhere either: with reads excluding one
/// another there is no reader parallelism for `_ReaderBias` to speed up, and
/// no thread identity or clock on this tier to build it from. The slot type
/// is uninhabited, so the read paths return and take back a `nil` that costs
/// nothing.
@_staticExclusiveOnly
@usableFromInline
internal struct _RWLockHandle: ~Copyable {
    @usableFromInline
    internal let mutex = Mutex<Void>(())

    @usableFromInline
    internal init() {}

    @usableFromInline
    internal borrowing func _readLock() -> _ReaderSlot? {
        mutex._unsafeLock()
        return nil
    }

    @usableFromInline
    internal borrowing func _tryReadLock() -> (acquired: Bool, slot: _ReaderSlot?) {
        (mutex._unsafeTryLock(), nil)
    }

    @usableFromInline
    internal borrowing func _readUnlock(_ slot: _ReaderSlot?) {
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
