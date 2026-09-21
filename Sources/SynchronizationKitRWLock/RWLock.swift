//
//  RWLock.swift
//  SynchronizationKit
//

// As in `Mutex`: `_Cell` backs the inline storage and is reached from members
// that inline into their callers. So is `_ExclusiveTransfer`, which detaches
// the storage from `self`'s isolation region for the write path; it says why
// that is needed, and why `Mutex` needs no such thing.
//
// The split between the two inlining attributes is the one `Mutex` explains,
// and it was measured here too rather than carried over. `init` constructs an
// `_RWLockHandle` and a `_Cell`, so it is `@_transparent`: 51 SIL instructions
// at a client's call site under `-Onone` against 59 the other way. The write
// path passes its pointer through `_ExclusiveTransfer`, so that initializer is
// `@_transparent` for the same reason, which leaves `withWriteLock` at 47
// either way. The read path has no wrapper to fold and measures 38 under both,
// so it takes the official spelling along with the rest of the locking methods.
public import SynchronizationKitCore

/// A reader-writer lock that owns the value it protects: any number of
/// concurrent readers, or exactly one writer.
///
/// Like `Mutex`, the value is reachable only from inside the locking methods,
/// so there is no way to touch it without holding the lock. Readers receive
/// the value by borrow and cannot mutate it; a writer receives it `inout` with
/// the same exclusive access `Mutex.withLock` grants:
///
///     final class ResourceCache {
///         private let entries = RWLock<[Key: Resource]>([:])
///
///         func resource(for key: Key) -> Resource? {
///             entries.withReadLock { $0[key] }
///         }
///
///         func store(_ resource: Resource, for key: Key) {
///             entries.withWriteLock { $0[key] = resource }
///         }
///     }
///
/// Unlike `Mutex` and `Atomic`, this type has no standard-library counterpart
/// to defer to, so it is available on every platform at every deployment
/// target.
///
/// Reading is cheap however many threads read at once — a reader touches
/// nothing another reader touches, on any backend but the fallback noted
/// below — and it is the writer that pays for that: a write costs more than
/// a `Mutex`'s exclusive take, more still when it follows a quiet spell. The
/// lock earns that where several threads read at once, a read section does
/// some work, and writes are few. A value written as often as it is read, or
/// one whose whole section is a load or a store, is better behind a `Mutex`.
///
/// Keep read sections short. A writer waits for a reader that published
/// itself by looking again rather than by sleeping on it: at once for the
/// first few dozen looks, then yielding, then in naps of up to a
/// millisecond, which is how late it may notice that the reader has left.
/// Nothing lends the reader the writer's priority meanwhile, on any
/// platform.
///
/// The instance itself is heavier than a `Mutex`, though only by the counters
/// and wait words it needs: the value is stored inline and nothing is
/// allocated. Where the handoff rests on a kernel object — a Mach semaphore
/// on an older Apple release, a semaphore object on Windows — it is created
/// the first time that lock actually blocks somebody, so what a lock costs
/// tracks how contended it is rather than how many of them are in flight.
/// The table readers publish themselves in is one per process and shared by
/// every lock; it is storage in the binary, so the first read allocates
/// nothing either.
///
/// - Warning: The lock is writer-preferring: a blocked `withWriteLock` call
///   stops new readers from acquiring the lock so writers cannot starve, except
///   on the fallback backend noted below. This means read locking is not
///   recursive — `withReadLock` from inside `withReadLock` on the same instance
///   deadlocks if a writer is waiting in between — and write locking is not
///   either: `withWriteLock` from inside `withReadLock` deadlocks outright.
///   Inside `withWriteLock`, both are recognized. The thread would wait for
///   its own unlock, and traps instead, on every backend but the fallback.
///   Where the calling code is built with assertions enabled, as a debug
///   build is, every one of these nestings is recognized as it begins, and
///   traps whether or not a writer is waiting, so that the mistake shows the
///   first time the code runs — except on the fallback backend.
///   The `IfAvailable` methods never wait, and are never trapped.
///
/// - Note: Writer preference is a property of the backends built for it. Where
///   `RWLock` falls back to an exclusive mutex — platforms with no backend of
///   their own, and no `Semaphore` to build the handoff from — readers and
///   writers contend on equal terms: a writer can be starved by a steady
///   stream of readers, and `withReadLockIfAvailable` may succeed while one
///   is blocked. Mutual exclusion is unaffected.
@_staticExclusiveOnly
public struct RWLock<Value: ~Copyable>: ~Copyable {
    @usableFromInline
    internal let handle: _RWLockHandle

    @usableFromInline
    internal let value: _Cell<Value>

    /// Creates a reader-writer lock guarding `initialValue`.
    @_transparent
    public init(_ initialValue: consuming sending Value) {
        handle = _RWLockHandle()
        value = _Cell(initialValue)
    }
}

// Unlike `Mutex`, which hands the value to exactly one thread at a time and
// can therefore be `Sendable` for any `Value`, a reader-writer lock lets many
// threads borrow the value simultaneously. A non-`Sendable` value could leak
// shared mutable state through that borrow — a class reference copied by two
// readers at once, say — so sharing the lock across threads requires a
// `Sendable` value, exactly as Rust's `RwLock<T>: Sync` requires `T: Sync`.
extension RWLock: @unchecked Sendable where Value: Sendable & ~Copyable {}

// MARK: - Read locking

extension RWLock where Value: ~Copyable {
    /// Acquires the lock for reading, runs `body` against the protected value,
    /// and releases the lock before returning.
    ///
    /// Any number of readers may run at once; a call blocks only while a
    /// writer holds the lock or is waiting for it. The lock is released
    /// however `body` exits, including by throwing.
    ///
    /// Keep the closure short. A reader does not block other readers, but it
    /// does block any writer for as long as it runs.
    ///
    /// - Parameter body: Runs with shared, read-only access to the value.
    /// - Returns: Whatever `body` returns.
    @inline(always)
    public borrowing func withReadLock<Result: ~Copyable, E: Error>(
        _ body: (borrowing Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        _debugRecordHoldChecking(.read)
        let slot = unsafe handle._readLock()

        defer {
            unsafe handle._readUnlock(slot)
            _debugForgetHold()
        }

        return try unsafe body(value._address.pointee)
    }

    /// Runs `body` with shared access if no writer holds or awaits the lock,
    /// and reports back without blocking otherwise.
    ///
    /// - Parameter body: Runs with shared, read-only access to the value, and
    ///   only if the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if a writer was in the way.
    @inline(always)
    public borrowing func withReadLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (borrowing Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        let attempt = unsafe handle._tryReadLock()
        guard unsafe attempt.acquired else {
            return nil
        }
        _debugRecordHold(.read)

        defer {
            unsafe handle._readUnlock(attempt.slot)
            _debugForgetHold()
        }

        return try unsafe body(value._address.pointee)
    }
}

// MARK: - Write locking

extension RWLock where Value: ~Copyable {
    /// Acquires the lock exclusively, runs `body` against the protected value,
    /// and releases the lock before returning.
    ///
    /// The call blocks until every current reader has departed, and new
    /// readers queue up behind it. The lock is released however `body` exits,
    /// including by throwing.
    ///
    /// - Parameter body: Runs with exclusive access to the value. Mutations
    ///   through its `inout` parameter are what the next caller will see.
    /// - Returns: Whatever `body` returns.
    @inline(always)
    public borrowing func withWriteLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        _debugRecordHoldChecking(.write)
        handle._writeLock()

        defer {
            handle._writeUnlock()
            _debugForgetHold()
        }

        let transfer = unsafe _ExclusiveTransfer(value._address)
        return try unsafe body(&transfer.address.pointee)
    }

    /// Runs `body` with exclusive access if the lock is entirely free — no
    /// readers, no writer — and reports back without blocking otherwise.
    ///
    /// - Parameter body: Runs with exclusive access to the value, and only if
    ///   the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if the lock was held.
    @inline(always)
    public borrowing func withWriteLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard handle._tryWriteLock() else {
            return nil
        }
        _debugRecordHold(.write)

        defer {
            handle._writeUnlock()
            _debugForgetHold()
        }

        let transfer = unsafe _ExclusiveTransfer(value._address)
        return try unsafe body(&transfer.address.pointee)
    }
}
