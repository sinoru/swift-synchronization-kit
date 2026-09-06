//
//  AsyncSemaphore.swift
//  SynchronizationKit
//

// `AsyncSemaphore` is public and conforms to `_AsyncWaitQueueOwner` directly,
// where `AsyncMutex` puts a handle in between. A conformance on a public type
// counts as public however the protocol is declared, and the compiler will not
// admit one from a module that is not imported publicly. Nothing leaks by it:
// everything the module declares is `package`, so a client can name none of
// it.
public import SynchronizationKitAsyncCore
package import SynchronizationKitMutex

/// A counting semaphore that suspends the calling task, rather than blocking
/// its thread, while it waits for a signal.
///
/// This is `DispatchSemaphore` restated for Swift Concurrency: `wait()`
/// decrements the count, suspending until a signal arrives if it is zero, and
/// `signal()` increments it, resuming a waiting task if there is one. The
/// difference is that the wait is a suspension point instead of a blocked
/// thread, which is what lets it be called from a task at all —
/// `DispatchSemaphore.wait()` is unavailable from asynchronous contexts.
///
///     final class Downloader: Sendable {
///         private let slots = AsyncSemaphore(value: 4)
///
///         func download(_ url: URL) async throws -> Data {
///             try await slots.wait()
///             defer { slots.signal() }
///             return try await fetch(url)
///         }
///     }
///
/// A semaphore is a count, not a lock: the task that signals need not be the
/// one that waited, which is what makes it fit for handing work between tasks
/// or bounding how many of them run at once. For protecting a value, use
/// `AsyncMutex`, which owns the value and knows who holds it.
///
/// ## Waiting, cancellation, and priority
///
/// When the count is positive `wait()` takes one without suspending;
/// otherwise the task joins a queue and is resumed by a signal, which hands
/// it the count directly, so a newcomer cannot overtake it. Waiters are
/// served in priority order, and in arrival order among equals.
///
/// A task that is cancelled while waiting stops waiting: `wait()` throws
/// `CancellationError` and the count is untouched. A task that is already
/// cancelled when it calls `wait()` still takes a positive count —
/// cancellation ends waiting, not acquiring — but throws instead of joining
/// the queue.
///
/// Cancellation is also how a wait is bounded in time. There is no
/// `wait(timeout:)`, for the reason `Task.sleep` has none: in Swift
/// Concurrency a deadline is a task that gets cancelled. Keep what the count
/// is used for inside the task that waited, so a count granted just as the
/// deadline lands is put back rather than stranded:
///
///     try await withThrowingTaskGroup(of: Void.self) { group in
///         group.addTask {
///             try await slots.wait()
///             defer { slots.signal() }
///             try await work()
///         }
///         group.addTask {
///             try await Task.sleep(for: .seconds(10))
///             throw TimedOut()
///         }
///         try await group.next()
///         group.cancelAll()
///     }
///
/// Unlike `AsyncMutex`, a semaphore has no holder to escalate: a count may be
/// taken by many tasks at once and given back by any task, so there is no one
/// task whose priority a waiter could raise. `DispatchSemaphore` has no
/// ownership for the same reason. A waiter's own escalation does move it up
/// the queue.
///
/// - Precondition: A semaphore must not be deallocated while tasks are
///   waiting on it. Each waiting task is suspended on a continuation that
///   only a signal can resume.
public final class AsyncSemaphore: Sendable {
    package let state: Mutex<_State>

    /// Creates a semaphore whose count starts at `value`.
    ///
    /// - Parameter value: How many waits can succeed before one has to
    ///   suspend. Must not be negative.
    public init(value: Int) {
        precondition(value >= 0, "AsyncSemaphore requires a non-negative initial value")
        state = Mutex(_State(value: value))
    }

    deinit {
        precondition(
            state.withLock { $0.queue.isEmpty },
            "AsyncSemaphore deallocated while tasks are waiting on it"
        )
    }
}

/// The count and who is waiting for it. Guarded by `state`.
///
/// The queue is non-empty only while `value` is zero: a signal that finds a
/// waiter hands the count to it rather than incrementing, so the two never
/// coexist.
package struct _State: _AsyncWaitState {
    var value: Int

    package var queue = _AsyncWaitQueue()
}

// MARK: - Waiting

extension AsyncSemaphore: _AsyncWaitQueueOwner {
    package func _tryAcquire() -> Bool {
        state.withLock { state in
            guard state.value > 0 else {
                return false
            }
            state.value -= 1
            return true
        }
    }

    package func _acquireIfAvailable(_ state: inout _State, for waiter: _AsyncWaiter) -> Bool {
        guard state.value > 0 else {
            return false
        }
        state.value -= 1
        return true
    }

    /// Decrements the count, suspending until a signal arrives if it is zero.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting,
    ///   or would have to wait while already cancelled.
    public nonisolated(nonsending) func wait() async throws {
        try await _acquire()
    }
}

// MARK: - Signaling

extension AsyncSemaphore {
    /// Increments the count, resuming the next waiting task if there is one.
    ///
    /// - Returns: Whether a task was resumed. `false` means nobody was
    ///   waiting, and the count went up instead.
    @discardableResult
    public func signal() -> Bool {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard let waiter = state.queue.removeNext() else {
                state.value += 1
                return nil
            }
            return waiter.grant()
        }

        guard let next else {
            return false
        }
        next.resume()
        return true
    }
}
