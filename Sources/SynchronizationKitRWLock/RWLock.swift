//
//  RWLock.swift
//  SynchronizationKit
//

import SynchronizationKitCore

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
/// Prefer `Mutex` unless reads are frequent, writes are rare, *and* the read
/// closure does enough work for concurrency to pay: with very short read
/// sections, the cost of tracking readers exceeds what parallel reading saves,
/// and a plain `Mutex` is faster.
///
/// - Warning: The lock is writer-preferring: a blocked `withWriteLock` call
///   stops new readers from acquiring the lock so writers cannot starve. This
///   means read locking is not recursive — `withReadLock` from inside
///   `withReadLock` on the same instance deadlocks if a writer is waiting in
///   between. Write locking is not recursive either, as with `Mutex`.
@_staticExclusiveOnly
public struct RWLock<Value: ~Copyable>: ~Copyable {
    @usableFromInline
    internal let handle = _RWLockHandle()

    @usableFromInline
    internal let value: _Cell<Value>

    /// Creates a reader-writer lock guarding `initialValue`.
    @_transparent
    public init(_ initialValue: consuming sending Value) {
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

/// Detaches the protected storage from `self`'s isolation region so it can be
/// handed to a `sending` closure parameter.
///
/// `Mutex` needs no such device: it is unconditionally `Sendable`, so region
/// isolation never ties its storage to the caller. `RWLock` is `Sendable` only
/// for `Sendable` values (see above), and for any other value the region
/// checker pins the storage to `self` — correctly in general, but not here,
/// where the write lock already guarantees the exclusivity that `sending`
/// asks for.
@unsafe
@usableFromInline
internal struct _ExclusiveTransfer<Value: ~Copyable>: @unchecked Sendable {
    @usableFromInline
    internal let address: UnsafeMutablePointer<Value>

    @_transparent
    @usableFromInline
    internal init(_ address: UnsafeMutablePointer<Value>) {
        unsafe self.address = address
    }
}

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
    @_transparent
    public borrowing func withReadLock<Result: ~Copyable, E: Error>(
        _ body: (borrowing Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        handle._readLock()

        defer {
            handle._readUnlock()
        }

        return try unsafe body(value._address.pointee)
    }

    /// Runs `body` with shared access if no writer holds or awaits the lock,
    /// and reports back without blocking otherwise.
    ///
    /// - Parameter body: Runs with shared, read-only access to the value, and
    ///   only if the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if a writer was in the way.
    @_transparent
    public borrowing func withReadLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (borrowing Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard handle._tryReadLock() else {
            return nil
        }

        defer {
            handle._readUnlock()
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
    @_transparent
    public borrowing func withWriteLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        handle._writeLock()

        defer {
            handle._writeUnlock()
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
    @_transparent
    public borrowing func withWriteLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard handle._tryWriteLock() else {
            return nil
        }

        defer {
            handle._writeUnlock()
        }

        let transfer = unsafe _ExclusiveTransfer(value._address)
        return try unsafe body(&transfer.address.pointee)
    }
}
