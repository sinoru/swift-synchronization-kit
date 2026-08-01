//
//  Mutex.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
// `_Cell` is the inline storage `Mutex` is built out of, reached from members
// that inline into their callers, so the module is part of this one's
// interface. `_Cell` itself stays `package`, which is what keeps it away from
// clients.
//
// The locking methods are `@inline(always)` and `init` is `@_transparent`. The
// line between them is measured rather than chosen: `@_transparent` inlines
// before the mandatory cleanup passes and so folds away the stack traffic of a
// value passing through a wrapper, while `@inline(always)` inlines after them
// and leaves it behind. `init` hands its value to `_Cell`, so it has such a
// wrapper — 45 SIL instructions against 53 at a client's call site under
// `-Onone`. `withLock` has none, and measures 59 either way.
//
// Where the cost is nil, `@inline(always)` is the one to take: it is the
// official spelling, it keeps the debug info `@_transparent` drops, and it
// makes no promise that the body may never change — a promise this body has
// already broken once, and one worth keeping breakable in the place a deadlock
// is debugged from. `AtomicStorage` records the other side of the same rule.
public import SynchronizationKitCore

/// A lock that owns the value it protects.
///
/// The value is reachable only from inside `withLock`, so there is no way to
/// touch it without holding the lock — the usual failure mode of a lock sitting
/// beside the data it guards, where nothing stops a caller from reading the
/// data directly.
///
/// The lock and the value are stored inline, so a `Mutex` can be a `let` on a
/// class or a global with no allocation of its own:
///
///     final class ResourceCache {
///         private let entries = Mutex<[Key: Resource]>([:])
///
///         func store(_ resource: Resource, for key: Key) {
///             entries.withLock { $0[key] = resource }
///         }
///     }
///
/// - Warning: The lock is not recursive. Calling `withLock` from inside
///   `withLock` on the same instance will not re-acquire it; on Darwin this
///   traps rather than deadlocking, but do not rely on which way it fails.
@available(macOS, deprecated: 15.0, message: "Use Synchronization.Mutex instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(iOS, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(tvOS, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(watchOS, deprecated: 11.0, message: "Use Synchronization.Mutex instead")
@available(visionOS, deprecated: 2.0, message: "Use Synchronization.Mutex instead")
@_staticExclusiveOnly
public struct Mutex<Value: ~Copyable>: ~Copyable {
    @usableFromInline
    internal let handle = _MutexHandle()

    @usableFromInline
    internal let value: _Cell<Value>

    /// Creates a mutex guarding `initialValue`.
    @_transparent
    public init(_ initialValue: consuming sending Value) {
        value = _Cell(initialValue)
    }
}

// Every extension of `Mutex` repeats the type's deprecation: a use inside a
// deprecated context is not diagnosed, so this is what keeps the package from
// warning about itself when the deployment target reaches the versions above.
@available(macOS, deprecated: 15.0, message: "Use Synchronization.Mutex instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(iOS, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(tvOS, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(watchOS, deprecated: 11.0, message: "Use Synchronization.Mutex instead")
@available(visionOS, deprecated: 2.0, message: "Use Synchronization.Mutex instead")
extension Mutex: @unchecked Sendable where Value: ~Copyable {}

// MARK: - Locking

@available(macOS, deprecated: 15.0, message: "Use Synchronization.Mutex instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(iOS, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(tvOS, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(watchOS, deprecated: 11.0, message: "Use Synchronization.Mutex instead")
@available(visionOS, deprecated: 2.0, message: "Use Synchronization.Mutex instead")
extension Mutex where Value: ~Copyable {
    /// Acquires the lock, runs `body` against the protected value, and releases
    /// the lock before returning.
    ///
    /// The lock is released however `body` exits, including by throwing.
    ///
    /// Keep the closure short. The calling thread blocks for as long as the
    /// lock is held, so anything slow inside it — I/O, an `await`, a callback
    /// into code you don't control — stalls every other caller. Copy what you
    /// need out and do the slow work afterwards.
    ///
    /// - Parameter body: Runs with exclusive access to the value. Mutations
    ///   through its `inout` parameter are what the next caller will see.
    /// - Returns: Whatever `body` returns.
    @inline(always)
    public borrowing func withLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        handle._lock()

        defer {
            handle._unlock()
        }

        return try unsafe body(&value._address.pointee)
    }

    /// Runs `body` if the lock is free, and reports back without blocking if it
    /// is not.
    ///
    /// Useful when there is something else worth doing instead of waiting —
    /// skipping a redundant refresh, say. It is not a way to avoid contention:
    /// a caller that must eventually see the value still has to call
    /// `withLock`.
    ///
    /// - Parameter body: Runs with exclusive access to the value, and only if
    ///   the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if the lock was already held.
    @inline(always)
    public borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard handle._tryLock() else {
            return nil
        }

        defer {
            handle._unlock()
        }

        return try unsafe body(&value._address.pointee)
    }
}

// MARK: - Unguarded locking

@available(macOS, deprecated: 15.0, message: "Use Synchronization.Mutex instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(iOS, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(tvOS, deprecated: 18.0, message: "Use Synchronization.Mutex instead")
@available(watchOS, deprecated: 11.0, message: "Use Synchronization.Mutex instead")
@available(visionOS, deprecated: 2.0, message: "Use Synchronization.Mutex instead")
extension Mutex where Value == Void {
    /// Acquires the lock without scoping it to a closure.
    ///
    /// Balancing this with `_unsafeUnlock` is the caller's responsibility;
    /// `withLock` does it for you and should be preferred.
    @inline(always)
    public borrowing func _unsafeLock() {
        handle._lock()
    }

    /// Acquires the lock if it is free, without scoping it to a closure.
    @inline(always)
    public borrowing func _unsafeTryLock() -> Bool {
        handle._tryLock()
    }

    /// Releases a lock taken by `_unsafeLock` or `_unsafeTryLock`.
    @inline(always)
    public borrowing func _unsafeUnlock() {
        handle._unlock()
    }
}
#else
import Synchronization

public typealias Mutex = Synchronization.Mutex
#endif
