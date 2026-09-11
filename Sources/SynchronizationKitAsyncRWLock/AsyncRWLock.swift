//
//  AsyncRWLock.swift
//  SynchronizationKit
//

// The import is public for the reason `AsyncMutex`'s is: the locking methods
// are `@inline(always)`.
public import SynchronizationKitCore

/// A reader-writer lock that owns the value it protects and suspends the
/// calling task, rather than blocking its thread, while it waits: any number
/// of concurrent readers, or exactly one writer.
///
/// This is `RWLock` restated for Swift Concurrency, as `AsyncMutex` is
/// `Mutex`. The value is reachable only from inside the locking methods, so
/// there is no way to touch it without holding the lock; readers receive it
/// by borrow and cannot mutate it, and a writer receives it `inout`. The
/// closures are `async`: the lock is held by a task rather than by a thread,
/// so it may be held across an `await`, which `RWLock` forbids because a task
/// can resume on a different thread from the one it suspended on.
///
///     final class ResourceCache: Sendable {
///         private let entries = AsyncRWLock<[Key: Resource]>([:])
///
///         func resource(for key: Key) async throws -> Resource? {
///             try await entries.withReadLock { $0[key] }
///         }
///
///         func store(_ resource: Resource, for key: Key) async throws {
///             try await entries.withWriteLock { $0[key] = resource }
///         }
///     }
///
/// The closures run on the caller's actor, if any, so they may touch
/// actor-isolated state directly.
///
/// ## Waiting, cancellation, and priority
///
/// Acquiring the lock is a suspension point. A reader takes the lock without
/// suspending while no writer holds it and nobody is queued; a writer, while
/// nobody holds it at all. Otherwise the task joins a queue and is resumed
/// when the lock is handed to it, so the lock never has to be re-contended
/// and a waiter cannot be overtaken by a newcomer of the same priority.
/// Waiters are served in priority order, and in arrival order among equals —
/// the same policy `AsyncMutex` follows, with the same consequence that a
/// stream of higher-priority waiters can hold a lower one off indefinitely.
///
/// The lock is writer-preferring in the sense `RWLock` is: a waiting writer
/// stops new readers from taking the lock, so writers cannot starve. When a
/// holder departs, the queue is served from the head for as long as the
/// lock's mode allows — a run of readers at the head is admitted together,
/// and stops at the first writer among them; a writer is admitted alone.
/// Nothing is ever served past a head that must still wait, whatever it asked
/// for.
///
/// A task that is cancelled while waiting stops waiting: the locking method
/// throws `CancellationError` without ever running the closure, and whoever
/// the departed waiter was holding back is served. A task that is already
/// cancelled when it calls a locking method still takes the lock if it can
/// be had without waiting — cancellation ends waiting, not locking, so cleanup
/// code that runs after cancellation can still reach the value — but throws
/// instead of joining the queue. Once the lock is held, cancellation is the
/// closure's business, as it is anywhere else.
///
/// Where the OS provides task priority escalation (macOS 26, iOS 26, tvOS 26,
/// watchOS 26, visionOS 26, and every non-Apple platform), a waiter of higher
/// priority than a holder raises the holder's priority for as long as it
/// holds the lock — every holder, so a writer waiting on a set of readers
/// raises each of them. On earlier Apple releases the queue is still ordered
/// by priority, but no holder is escalated. A waiter that is itself escalated
/// while queued passes that on to the holders, and moves up the queue, when
/// the package is built with Swift 6.4 or later; a 6.3 build leaves a queued
/// waiter at the priority it arrived with. A holder that is a thread is
/// raised by nobody, there being no task to raise, and a waiting thread is
/// not raised either: a thread waits at the priority it arrived with.
///
/// ## Locking from a thread
///
/// Every locking method has a synchronous form for a thread with no task to
/// suspend, on the terms `AsyncMutex` states for its own: the blocking
/// `withReadLock` and `withWriteLock` take the same lock and wait in the
/// same queue as the asynchronous ones, at the priority the runtime reports
/// for the thread, served in turn among the tasks, without cancellation,
/// and blocked for as long as the holders — which may be tasks holding
/// across an `await` — keep the lock; the `IfAvailable` forms never block.
/// All four are unavailable from asynchronous contexts, so a task cannot
/// reach them by mistake, and wrapping one in a synchronous closure to get
/// around that blocks a thread of the cooperative pool for as long as a
/// task's `await` takes, which is the deadlock this is designed against.
///
/// ## When to use this
///
/// Prefer an `actor` when one fits, for the reason `AsyncMutex` gives: actors
/// are reentrant at every `await`, which is what makes them immune to
/// deadlock, and this lock gives that immunity up on purpose; what is left
/// is what `AsyncMutex` lists, restated for readers and a writer. Prefer
/// `AsyncMutex` over this unless reads are frequent, writes are rare, *and*
/// the read closure does enough work — in particular, waits on enough — for
/// concurrent reading to pay: every acquisition and release here passes
/// through one synchronous lock and a little bookkeeping per reader, which a
/// short read section does not amortize.
///
/// - Warning: Neither kind of locking is recursive. Read locking from inside
///   a read section on the same instance waits forever if a writer has queued
///   in between, since the writer stops new readers; write locking from
///   inside any section on the same instance waits for a release that can
///   never come. Neither can the lock detect a cycle across instances, or
///   between an instance and an actor whose method is waiting on it: such
///   waits hang until one of the tasks involved is cancelled.
@_staticExclusiveOnly
public struct AsyncRWLock<Value: ~Copyable>: ~Copyable {
    @usableFromInline
    package let handle = _AsyncRWLockHandle()

    @usableFromInline
    internal let value: _Cell<Value>

    /// Creates a reader-writer lock guarding `initialValue`.
    public init(_ initialValue: consuming sending Value) {
        value = _Cell(initialValue)
    }
}

// As with `RWLock`, and unlike `AsyncMutex`: many tasks may borrow the value
// at once, so a non-`Sendable` value could leak shared mutable state through
// that borrow, and sharing the lock across tasks requires a `Sendable` value.
extension AsyncRWLock: @unchecked Sendable where Value: Sendable & ~Copyable {}

// MARK: - Read locking

extension AsyncRWLock where Value: ~Copyable {
    /// Acquires the lock for reading, suspending while a writer holds it or
    /// waits for it, runs `body` against the protected value, and releases
    /// the lock before returning.
    ///
    /// Any number of readers may run at once. The lock is released however
    /// `body` exits, including by throwing. `body` runs on the caller's
    /// actor, if any.
    ///
    /// A reader does not hold other readers up, but it does hold up every
    /// writer, and through the writer every reader queued behind it, for as
    /// long as `body` runs.
    ///
    /// - Parameter body: Runs with shared, read-only access to the value.
    /// - Returns: Whatever `body` returns.
    /// - Throws: `CancellationError` if the task is cancelled before it
    ///   acquires the lock, or whatever `body` throws.
    @inline(always)
    public nonisolated(nonsending) borrowing func withReadLock<Result: ~Copyable>(
        _ body: nonisolated(nonsending) (borrowing Value) async throws -> sending Result
    ) async throws -> sending Result {
        try await handle._readLock()

        defer {
            handle._readUnlock()
        }

        // The pointer stays valid across the suspensions inside `body`, and
        // is taken in its own statement, for the reasons `AsyncMutex` gives.
        let address = unsafe value._address
        return try await unsafe body(address.pointee)
    }

    /// Runs `body` with shared access if no writer holds or awaits the lock,
    /// and reports back without suspending otherwise.
    ///
    /// Taking the lock this way never suspends and is not a cancellation
    /// point; only `body` itself can suspend.
    ///
    /// - Parameter body: Runs with shared, read-only access to the value, and
    ///   only if the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if a writer was in the way.
    @inline(always)
    public nonisolated(nonsending) borrowing func withReadLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: nonisolated(nonsending) (borrowing Value) async throws(E) -> sending Result
    ) async throws(E) -> sending Result? {
        guard handle._tryReadLock() else {
            return nil
        }

        defer {
            handle._readUnlock()
        }

        let address = unsafe value._address
        return try await unsafe body(address.pointee)
    }
}

// MARK: - Write locking

extension AsyncRWLock where Value: ~Copyable {
    /// Acquires the lock exclusively, suspending until every current holder
    /// has departed, runs `body` against the protected value, and releases
    /// the lock before returning.
    ///
    /// New readers queue up behind the call. The lock is released however
    /// `body` exits, including by throwing. `body` runs on the caller's
    /// actor, if any.
    ///
    /// Everything queued behind this call waits for as long as `body` runs,
    /// so keep the section as short as the work allows; the point of an
    /// asynchronous lock is that the section may contain an `await`, not that
    /// it should contain many.
    ///
    /// - Parameter body: Runs with exclusive access to the value. Mutations
    ///   through its `inout` parameter are what the next caller will see.
    /// - Returns: Whatever `body` returns.
    /// - Throws: `CancellationError` if the task is cancelled before it
    ///   acquires the lock, or whatever `body` throws.
    @inline(always)
    public nonisolated(nonsending) borrowing func withWriteLock<Result: ~Copyable>(
        _ body: nonisolated(nonsending) (inout sending Value) async throws -> sending Result
    ) async throws -> sending Result {
        try await handle._writeLock()

        defer {
            handle._writeUnlock()
        }

        let transfer = unsafe _ExclusiveTransfer(value._address)
        return try await unsafe body(&transfer.address.pointee)
    }

    /// Runs `body` with exclusive access if the lock is entirely free — no
    /// readers, no writer, nobody queued — and reports back without
    /// suspending otherwise.
    ///
    /// Taking the lock this way never suspends and is not a cancellation
    /// point; only `body` itself can suspend.
    ///
    /// - Parameter body: Runs with exclusive access to the value, and only if
    ///   the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if the lock was held.
    @inline(always)
    public nonisolated(nonsending) borrowing func withWriteLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: nonisolated(nonsending) (inout sending Value) async throws(E) -> sending Result
    ) async throws(E) -> sending Result? {
        guard handle._tryWriteLock() else {
            return nil
        }

        defer {
            handle._writeUnlock()
        }

        let transfer = unsafe _ExclusiveTransfer(value._address)
        return try await unsafe body(&transfer.address.pointee)
    }
}

// MARK: - Locking from a thread

extension AsyncRWLock where Value: ~Copyable {
    /// Acquires the lock for reading, blocking the calling thread while a
    /// writer holds it or waits for it, runs `body` against the protected
    /// value, and releases the lock before returning.
    ///
    /// The `withReadLock` for a thread with no task to suspend: it takes the
    /// same lock and waits in the same queue as the asynchronous one, at the
    /// priority `Task.currentPriority` reports for the thread, and is served
    /// in its turn among the tasks. It cannot be cancelled, and it blocks for
    /// as long as a writer — which may be a task holding across an `await` —
    /// keeps the lock. It is unavailable from asynchronous contexts, where
    /// the asynchronous form is chosen instead; the type's documentation says
    /// what getting around that costs.
    ///
    /// - Parameter body: Runs with shared, read-only access to the value.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Whatever `body` throws.
    // Disfavored so that a synchronous closure handed to the asynchronous
    // form from asynchronous code still selects that form: the closure's
    // type would otherwise rank this overload first, and `noasync` is not
    // consulted until the choice is made.
    @_disfavoredOverload
    @inline(always)
    @available(*, noasync, message: "Blocks the thread; await withReadLock(_:) instead")
    public borrowing func withReadLock<Result: ~Copyable, E: Error>(
        _ body: (borrowing Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        handle._readLockBlocking()

        defer {
            handle._readUnlock()
        }

        return try unsafe body(value._address.pointee)
    }

    /// Runs `body` with read access if that can be had at once, and reports
    /// back otherwise, without blocking.
    ///
    /// The synchronous `withReadLockIfAvailable`, for a thread with no task.
    /// It is unavailable from asynchronous contexts, where the asynchronous
    /// form is chosen instead.
    ///
    /// - Parameter body: Runs with shared, read-only access to the value,
    ///   and only if the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if a writer held the lock
    ///   or was waiting for it.
    // Disfavored so that a synchronous closure handed to the asynchronous
    // form from asynchronous code still selects that form: the closure's
    // type would otherwise rank this overload first, and `noasync` is not
    // consulted until the choice is made.
    @_disfavoredOverload
    @inline(always)
    @available(*, noasync, message: "Use the asynchronous withReadLockIfAvailable(_:) from a task")
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

    /// Acquires the lock for writing, blocking the calling thread while
    /// anyone holds it, runs `body` against the protected value, and
    /// releases the lock before returning.
    ///
    /// The `withWriteLock` for a thread with no task to suspend, on the terms
    /// the synchronous `withReadLock` states: same lock, same queue, served
    /// in turn, no cancellation, and blocked for as long as every holder —
    /// each of which may be a task holding across an `await` — keeps the
    /// lock.
    ///
    /// - Parameter body: Runs with exclusive access to the value. Mutations
    ///   through its `inout` parameter are what the next caller will see.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Whatever `body` throws.
    // Disfavored so that a synchronous closure handed to the asynchronous
    // form from asynchronous code still selects that form: the closure's
    // type would otherwise rank this overload first, and `noasync` is not
    // consulted until the choice is made.
    @_disfavoredOverload
    @inline(always)
    @available(*, noasync, message: "Blocks the thread; await withWriteLock(_:) instead")
    public borrowing func withWriteLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        handle._writeLockBlocking()

        defer {
            handle._writeUnlock()
        }

        // Through `_ExclusiveTransfer`, for the reason `RWLock` gives.
        let transfer = unsafe _ExclusiveTransfer(value._address)
        return try unsafe body(&transfer.address.pointee)
    }

    /// Runs `body` with write access if that can be had at once, and reports
    /// back otherwise, without blocking.
    ///
    /// The synchronous `withWriteLockIfAvailable`, for a thread with no task.
    /// It is unavailable from asynchronous contexts, where the asynchronous
    /// form is chosen instead.
    ///
    /// - Parameter body: Runs with exclusive access to the value, and only if
    ///   the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if anyone held the lock or
    ///   was waiting for it.
    // Disfavored so that a synchronous closure handed to the asynchronous
    // form from asynchronous code still selects that form: the closure's
    // type would otherwise rank this overload first, and `noasync` is not
    // consulted until the choice is made.
    @_disfavoredOverload
    @inline(always)
    @available(*, noasync, message: "Use the asynchronous withWriteLockIfAvailable(_:) from a task")
    public borrowing func withWriteLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard handle._tryWriteLock() else {
            return nil
        }

        defer {
            handle._writeUnlock()
        }

        // Through `_ExclusiveTransfer`, for the reason `RWLock` gives.
        let transfer = unsafe _ExclusiveTransfer(value._address)
        return try unsafe body(&transfer.address.pointee)
    }
}
