//
//  AsyncMutex.swift
//  SynchronizationKit
//

// The import is public for the reason `Mutex`'s is: the locking methods are
// `@inline(always)`, so the cell the value lives in is part of this module's
// interface. What that buys an asynchronous lock is smaller than what it
// buys `Mutex`, and measured: the generic closure call and the wrapper's own
// frame, about a tenth of an uncontended take. `_Cell` and the handle stay
// `package`, which is what keeps them away from clients. The handle's entry
// points are its own, so the core module is not on this one's interface.
public import SynchronizationKitCore

/// A lock that owns the value it protects and suspends the calling task,
/// rather than blocking its thread, while another task holds it.
///
/// Like `Mutex`, the value is reachable only from inside `withLock`, so there
/// is no way to touch it without holding the lock. Unlike `Mutex`, the
/// closure is `async`: the lock is held by a task rather than by a thread, so
/// it may be held across an `await`, which the standard library's `Mutex`
/// forbids because a task can resume on a different thread from the one it
/// suspended on.
///
///     final class ImageCache: Sendable {
///         private let entries = AsyncMutex<[URL: Image]>([:])
///
///         func image(at url: URL) async throws -> Image {
///             try await entries.withLock { entries in
///                 if let image = entries[url] {
///                     return image
///                 }
///                 let image = try await download(url)
///                 entries[url] = image
///                 return image
///             }
///         }
///     }
///
/// The closure runs on the caller's actor, if any, so it may touch
/// actor-isolated state directly.
///
/// ## Waiting, cancellation, and priority
///
/// Acquiring the lock is a suspension point. When the lock is free the call
/// takes it without suspending; otherwise the task joins a queue and is
/// resumed when the lock is handed to it, so the lock never has to be
/// re-contended and a waiter cannot be overtaken by a newcomer of the same
/// priority. Waiters are served in priority order, and in arrival order among
/// equals — the same policy the actor runtime uses for its queues, with the
/// same consequence that a stream of higher-priority waiters can hold a lower
/// one off indefinitely. A waiter's priority is the one `Task.currentPriority`
/// reports, which for a child of a task group is its parent's even when the
/// child was given a higher one.
///
/// A task that is cancelled while waiting stops waiting: `withLock` throws
/// `CancellationError` without ever running the closure. A task that is
/// already cancelled when it calls `withLock` still takes the lock if the
/// lock is free — cancellation ends waiting, not locking, so cleanup code
/// that runs after cancellation can still reach the value — but throws
/// instead of joining the queue. Once the lock is held, cancellation is the
/// closure's business, as it is anywhere else.
///
/// Where the OS provides task priority escalation (macOS 26, iOS 26, tvOS 26,
/// watchOS 26, visionOS 26, and every non-Apple platform), a waiter of higher
/// priority than the holder raises the holder's priority for as long as it
/// holds the lock, as the actor runtime does for actors and the kernel does
/// for `Mutex`. On earlier Apple releases the queue is still ordered by
/// priority, but a holder is not escalated. A waiter that is itself escalated
/// while queued passes that on to the holder, and moves up the queue, when
/// the package is built with Swift 6.4 or later; a 6.3 build leaves a queued
/// waiter at the priority it arrived with. A holder that is a thread is
/// raised by nobody, there being no task to raise, and a waiting thread is
/// not raised either: a thread waits at the priority it arrived with.
///
/// ## Locking from a thread
///
/// `withLock` and `withLockIfAvailable` have synchronous forms for a thread
/// with no task to suspend. The blocking `withLock` takes the same lock and
/// waits in the same queue as the asynchronous one, at the priority
/// `Task.currentPriority` reports for the thread — its QoS on Darwin — and
/// is served in its turn among the tasks; it cannot be cancelled, and it
/// blocks the calling thread for as long as the holder, which may be a task
/// holding across an `await`, keeps the lock. That is what makes the lock a
/// bridge: a task and a thread take turns on one value, each holding it the
/// way it can. A synchronous caller running inside a task holds it as that
/// task, whether it found the lock free or waited, and is raised as any
/// holder is; a thread with no task holds it as none, and is raised by nobody.
///
/// The synchronous forms are unavailable from asynchronous contexts, as
/// `Semaphore.wait()` is, so a task cannot reach them by mistake — including
/// from a `Task { }` body with no other `await` in it, where overload
/// resolution alone would have chosen them. Wrapping the call in a
/// synchronous closure gets around that, as it does for every `noasync`
/// declaration, and blocks a thread of the cooperative pool for as long as
/// the holding task's `await` takes, which is the deadlock this is designed
/// against.
///
/// ## When to use this
///
/// Prefer an `actor` when one fits: actors are reentrant at every `await`,
/// which is what makes them immune to deadlock, and this lock gives that
/// immunity up on purpose. What is left for `AsyncMutex` is what an actor
/// cannot express. A critical section that must span an `await` — a cache
/// that must not fetch the same key twice, a connection whose request and
/// reply must not interleave with another's — since an actor lets every
/// `await` in it through. A section that must run on the caller's own actor,
/// touching that actor's state, while the lock keeps it from overlapping
/// with itself: the closure runs where it was called, where an actor's
/// method would hop away. And a value that a thread and a task must take
/// turns on, through the synchronous `withLock` above.
///
/// - Warning: The lock is not recursive. Calling `withLock` from inside
///   `withLock` on the same instance waits for a release that can never come.
///   Neither can it detect a cycle across instances, or between an instance
///   and an actor whose method is waiting on it: such waits hang until one of
///   the tasks involved is cancelled.
@_staticExclusiveOnly
public struct AsyncMutex<Value: ~Copyable>: ~Copyable {
    @usableFromInline
    package let handle = _AsyncMutexHandle()

    @usableFromInline
    internal let value: _Cell<Value>

    /// Creates a lock guarding `initialValue`.
    public init(_ initialValue: consuming sending Value) {
        value = _Cell(initialValue)
    }
}

// The lock hands the value to exactly one task at a time, and the `inout
// sending` parameter of `withLock` keeps that task from leaving a reference
// behind, so an `AsyncMutex` is safe to share whatever the value is — the
// same reasoning that makes `Mutex` unconditionally `Sendable`.
extension AsyncMutex: @unchecked Sendable where Value: ~Copyable {}

// MARK: - Locking

extension AsyncMutex where Value: ~Copyable {
    /// Acquires the lock, suspending while another task holds it, runs `body`
    /// against the protected value, and releases the lock before returning.
    ///
    /// The lock is released however `body` exits, including by throwing.
    /// `body` runs on the caller's actor, if any.
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
    public nonisolated(nonsending) borrowing func withLock<Result: ~Copyable>(
        _ body: nonisolated(nonsending) (inout sending Value) async throws -> sending Result
    ) async throws -> sending Result {
        try await handle._lock()

        defer {
            handle._unlock()
        }

        // The pointer stays valid across the suspensions inside `body` for the
        // reasons `_Cell` documents: raw-layout storage is the value's own,
        // and `@_staticExclusiveOnly` keeps it from moving out from under the
        // borrow of `self` that this call holds until it returns.
        //
        // The pointer is taken in its own statement rather than inline in the
        // `inout` argument. Under ThreadSanitizer the compiler marks every
        // stored property on the path to an `inout` argument as modified, and
        // `&value._address.pointee` would mark `self` — which is only
        // borrowed, and which another task reads `handle` from before it takes
        // the lock. That read against the phantom write is a race report, and
        // the only one the sanitizer had for this lock. `Mutex` writes the
        // same expression inline and is not reported, because its handle is
        // inline storage that no instruction loads from.
        let address = unsafe value._address
        return try await unsafe body(&address.pointee)
    }

    /// Runs `body` if the lock is free, and reports back without suspending
    /// if it is not.
    ///
    /// Taking the lock this way never suspends and is not a cancellation
    /// point; only `body` itself can suspend.
    ///
    /// - Parameter body: Runs with exclusive access to the value, and only if
    ///   the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if the lock was already held.
    @inline(always)
    public nonisolated(nonsending) borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: nonisolated(nonsending) (inout sending Value) async throws(E) -> sending Result
    ) async throws(E) -> sending Result? {
        guard handle._tryLock() else {
            return nil
        }

        defer {
            handle._unlock()
        }

        // In its own statement for the reason `withLock` gives.
        let address = unsafe value._address
        return try await unsafe body(&address.pointee)
    }
}

// MARK: - Locking from a thread

extension AsyncMutex where Value: ~Copyable {
    /// Acquires the lock, blocking the calling thread while another task or
    /// thread holds it, runs `body` against the protected value, and releases
    /// the lock before returning.
    ///
    /// This is the `withLock` for a thread with no task to suspend. It takes
    /// the same lock and waits in the same queue as the asynchronous one, at
    /// the priority `Task.currentPriority` reports for the thread, and is
    /// served in its turn among the tasks. It cannot be cancelled, and it
    /// blocks for as long as the holder — which may be a task holding across
    /// an `await` — keeps the lock. It is unavailable from asynchronous
    /// contexts, where the asynchronous `withLock` is chosen instead; the
    /// type's documentation says what getting around that costs.
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
    @available(*, noasync, message: "Blocks the thread; await withLock(_:) instead")
    public borrowing func withLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        handle._lockBlocking()

        defer {
            handle._unlock()
        }

        // In its own statement for the reason the asynchronous `withLock`
        // gives.
        let address = unsafe value._address
        return try unsafe body(&address.pointee)
    }

    /// Runs `body` if the lock is free, and reports back at once if it is
    /// not, without blocking.
    ///
    /// The synchronous `withLockIfAvailable`, for a thread with no task: the
    /// one to reach for from a synchronous callback that may not wait. It is
    /// unavailable from asynchronous contexts, where the asynchronous form
    /// is chosen instead.
    ///
    /// - Parameter body: Runs with exclusive access to the value, and only if
    ///   the lock was acquired.
    /// - Returns: What `body` returned, or `nil` if the lock was already held.
    // Disfavored so that a synchronous closure handed to the asynchronous
    // form from asynchronous code still selects that form: the closure's
    // type would otherwise rank this overload first, and `noasync` is not
    // consulted until the choice is made.
    @_disfavoredOverload
    @inline(always)
    @available(*, noasync, message: "Use the asynchronous withLockIfAvailable(_:) from a task")
    public borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard handle._tryLock() else {
            return nil
        }

        defer {
            handle._unlock()
        }

        let address = unsafe value._address
        return try unsafe body(&address.pointee)
    }
}
