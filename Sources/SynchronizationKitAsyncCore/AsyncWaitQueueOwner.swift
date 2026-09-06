//
//  AsyncWaitQueueOwner.swift
//  SynchronizationKit
//

// `Mutex` is the type of a requirement below, and every requirement here is
// `package`, so the module has to be visible at that level to the targets that
// conform. Not `public`: nothing in this module reaches a client.
package import SynchronizationKitMutex

/// State that carries an `_AsyncWaitQueue` alongside whatever else the owning
/// primitive keeps under its lock.
package protocol _AsyncWaitState: Sendable {
    var queue: _AsyncWaitQueue { get set }
}

/// A primitive that tasks wait on: it keeps a wait queue under a lock, and
/// gets the waiting itself — queueing, suspending, cancellation, and the
/// priority of a queued task — from the extension below.
///
/// ## Lock ordering
///
/// The handlers installed around a wait are what make the order matter: the
/// runtime invokes a cancellation or escalation handler while it holds the
/// affected task's own status lock, and it takes that same status lock to
/// resume or escalate the task. Any lock of ours that a handler waits on must
/// therefore never be held while a task is resumed or escalated, or a thread
/// doing either could wait on a status lock whose owner is waiting on us.
///
/// `state` is innermost. Its critical sections update the state and return;
/// they never resume a continuation or escalate a task. Handlers may take it
/// freely. An owner that adds locks of its own orders them outside it.
package protocol _AsyncWaitQueueOwner: AnyObject, Sendable {
    associatedtype State: _AsyncWaitState

    /// The state proper. See the lock-ordering note above.
    var state: Mutex<State> { get }

    /// Takes what is being waited for if it can be had without waiting.
    ///
    /// The fast path: called before a waiter exists, so an uncontended
    /// acquisition allocates nothing.
    func _tryAcquire() -> Bool

    /// Takes what is being waited for on `waiter`'s behalf if it can be had
    /// without waiting. Called with the state lock held, and only while the
    /// queue is empty.
    func _acquireIfAvailable(_ state: inout State, for waiter: _AsyncWaiter) -> Bool

    /// Called outside the state lock once a waiter has joined the queue.
    func _waiterDidQueue()

    /// Called from a priority escalation handler, outside the state lock,
    /// once a queued waiter's priority has been raised. Must not wait on
    /// anything a handler could be holding.
    func _waiterPriorityDidRise()
}

extension _AsyncWaitQueueOwner {
    package func _waiterDidQueue() {}

    package func _waiterPriorityDidRise() {}
}

// MARK: - Waiting

/// What became of a waiter on its way into the queue.
private enum _Arrival {
    /// It was available after all; the waiter took it.
    case acquired
    /// The waiter joined the queue.
    case queued
    /// The waiter was cancelled before it could join the queue.
    case cancelled
}

extension _AsyncWaitQueueOwner {
    /// Acquires what is being waited for, suspending until it is handed over
    /// if that cannot happen at once.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting,
    ///   or would have to wait while already cancelled.
    package nonisolated(nonsending) func _acquire() async throws {
        if _tryAcquire() {
            return
        }

        let waiter = unsafe withUnsafeCurrentTask { task in
            unsafe _AsyncWaiter(task: task, priority: Task.currentPriority)
        }

        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            try await withTaskPriorityEscalationHandler {
                try await _wait(as: waiter)
            } onPriorityEscalated: { _, newPriority in
                let raised = state.withLock { _ in
                    guard newPriority > waiter.priority else {
                        return false
                    }
                    waiter.priority = newPriority
                    return true
                }
                if raised {
                    _waiterPriorityDidRise()
                }
            }
        } else {
            try await _wait(as: waiter)
        }
    }

    /// Queues `waiter` and suspends until it is granted or cancelled.
    private nonisolated(nonsending) func _wait(as waiter: _AsyncWaiter) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let arrival = state.withLock { state -> _Arrival in
                    // Whatever was contended may have been released between
                    // the fast path and here. A cancelled task may still take
                    // what is free; what it may not do is wait.
                    if state.queue.isEmpty, _acquireIfAvailable(&state, for: waiter) {
                        waiter.phase = .granted
                        return .acquired
                    }

                    switch waiter.phase {
                    case .pending:
                        waiter.phase = .waiting(continuation)
                        state.queue.append(waiter)
                        return .queued
                    case .cancelled:
                        return .cancelled
                    case .waiting, .granted:
                        preconditionFailure("waiter suspended twice")
                    }
                }

                switch arrival {
                case .acquired:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .queued:
                    _waiterDidQueue()
                }
            }
        } onCancel: {
            // Runs before the operation if the task is already cancelled, and
            // concurrently with it otherwise; the phase tells the two apart.
            // Decided under the lock, resumed outside it.
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                switch waiter.phase {
                case .pending:
                    waiter.phase = .cancelled
                    return nil
                case .waiting(let continuation):
                    state.queue.remove(waiter)
                    waiter.phase = .cancelled
                    return continuation
                case .granted, .cancelled:
                    return nil
                }
            }

            continuation?.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Test support

extension _AsyncWaitQueueOwner {
    /// How many tasks are queued. For tests, which need to know when a task
    /// has actually joined the queue before releasing or cancelling.
    package var _waiterCount: Int {
        state.withLock { $0.queue.count }
    }
}
