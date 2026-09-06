//
//  AsyncWaitQueueOwner.swift
//  SynchronizationKit
//

// `Mutex` is the type of a requirement below, and every requirement here is
// `package`, so the module has to be visible at that level to the targets that
// conform. Not `public`: nothing in this module reaches a client.
package import SynchronizationKitMutex
import CSynchronizationKitAsyncCore

/// State that carries an `_AsyncWaitQueue` alongside whatever else the owning
/// primitive keeps under its lock.
package protocol _AsyncWaitState: Sendable {
    /// What a waiter asks for. `Void` where there is only one thing to ask.
    associatedtype Request: Sendable

    var queue: _AsyncWaitQueue<Request> { get set }
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

    typealias Request = State.Request

    /// The state proper. See the lock-ordering note above.
    var state: Mutex<State> { get }

    /// Takes `request` if it can be had without waiting.
    ///
    /// The fast path: called before a waiter exists, so an uncontended
    /// acquisition allocates nothing.
    func _tryAcquire(_ request: Request) -> Bool

    /// Takes what `waiter` asks for on its behalf if it can be had without
    /// waiting. Called with the state lock held, and only while the queue is
    /// empty.
    func _acquireIfAvailable(_ state: inout State, for waiter: _AsyncWaiter<Request>) -> Bool

    /// Whether the waiter that just joined the queue, or was just raised
    /// while in it, is one the owner has to act on — a holder outranked by
    /// it, for an owner that escalates holders. Called with the state lock
    /// held, from the same critical section that queued or raised the
    /// waiter, so the answer costs no lock of its own; `_waiterDidQueue` or
    /// `_waiterPriorityDidRise` follows outside the lock only when it is
    /// true.
    func _queuedWaiterNeedsAttention(_ state: State) -> Bool

    /// Called outside the state lock once a waiter has joined the queue and
    /// `_queuedWaiterNeedsAttention` has said it matters.
    func _waiterDidQueue()

    /// Called from a priority escalation handler, outside the state lock,
    /// once a queued waiter's priority has been raised and
    /// `_queuedWaiterNeedsAttention` has said it matters. Must not wait on
    /// anything a handler could be holding, and must not resume a task: the
    /// handler runs under the escalated task's own status lock.
    func _waiterPriorityDidRise()

    /// Called in the waiting task, outside the state lock, once a cancelled
    /// waiter has been resumed — whether it left the queue or never joined
    /// it. Nothing of the runtime's is held here, which is what lets an owner
    /// serve from here a waiter the departed one was holding back; a handler
    /// could not, since it runs under the cancelled task's status lock.
    func _waiterDidCancel()
}

extension _AsyncWaitQueueOwner {
    package func _queuedWaiterNeedsAttention(_ state: State) -> Bool {
        false
    }

    package func _waiterDidQueue() {}

    package func _waiterPriorityDidRise() {}

    package func _waiterDidCancel() {}
}

extension _AsyncWaitQueueOwner where Request == Void {
    package func _tryAcquire() -> Bool {
        _tryAcquire(())
    }

    /// `_acquire(_:)` for the one thing there is to ask for.
    package nonisolated(nonsending) func _acquire() async throws {
        try await _acquire(())
    }
}

// MARK: - Waiting

/// What became of a waiter on its way into the queue.
private enum _Arrival {
    /// It was available after all; the waiter took it.
    case acquired
    /// The waiter joined the queue; the owner asked to hear of it or not.
    case queued(matters: Bool)
    /// The waiter was cancelled before it could join the queue.
    case cancelled
}

extension _AsyncWaitQueueOwner {
    /// Acquires `request`, suspending until it is handed over if that cannot
    /// happen at once.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting,
    ///   or would have to wait while already cancelled.
    package nonisolated(nonsending) func _acquire(_ request: Request) async throws {
        if _tryAcquire(request) {
            return
        }

        let waiter = unsafe withUnsafeCurrentTask { task in
            unsafe _AsyncWaiter(task: task, request: request, priority: Task.currentPriority)
        }

        // The escalation handler is installed only when the compiler is 6.4
        // or later. `withTaskPriorityEscalationHandler` is emitted into its
        // caller, and its body calls two runtime entry points that exist
        // from macOS 26 and iOS 26; Swift 6.3 leaves those as strong
        // references, so a binary it built would fail to load on any earlier
        // OS — at dlopen, before a line of it ran — where 6.4 links them
        // weakly and the `#available` below is what decides. Declaring the
        // entry points here with `@_weakLinked` is not an option either: the
        // compiler reserves their names for the runtime and warns on the
        // reference.
        //
        // What a 6.3 build gives up is narrow: a task escalated while it is
        // already queued is not moved up the queue, and a mutex holder is not
        // escalated on its account. A waiter that arrives at a higher
        // priority than the holder still escalates it, since that path calls
        // `escalatePriority(to:)`, which links weakly on both compilers.
        //
        // Remove the `#else` branch, and this note, once the package's
        // minimum toolchain is 6.4.
        #if compiler(>=6.4)
        if #available(anyAppleOS 26.0, *) {
            try await withTaskPriorityEscalationHandler {
                try await _wait(as: waiter)
            } onPriorityEscalated: { _, newPriority in
                let matters = state.withLock { state in
                    guard newPriority > waiter.priority else {
                        return false
                    }
                    state.queue.raisePriority(of: waiter, to: newPriority)
                    return _queuedWaiterNeedsAttention(state)
                }
                if matters {
                    _waiterPriorityDidRise()
                }
            }
        } else {
            try await _wait(as: waiter)
        }
        #else
        try await _wait(as: waiter)
        #endif
    }

    /// Queues `waiter` and suspends until it is granted or cancelled.
    private nonisolated(nonsending) func _wait(as waiter: _AsyncWaiter<Request>) async throws {
        do {
            try await _suspend(as: waiter)
            // Back in the task with the grant: the other end of the edge
            // `grant()` records. The runtime records one of its own only on
            // the path where the task was enqueued to resume; a task granted
            // before it had finished suspending continues in place, and that
            // path records nothing. `CSynchronizationKitAsyncCore.h` says
            // what the sanitizer then reports.
            unsafe sk_async_core_tsan_acquire(Unmanaged.passUnretained(waiter).toOpaque())
        } catch {
            // Back in the task, with nothing held: the one place a waiter's
            // leaving can safely be acted on.
            _waiterDidCancel()
            throw error
        }
    }

    private nonisolated(nonsending) func _suspend(as waiter: _AsyncWaiter<Request>) async throws {
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
                        return .queued(matters: _queuedWaiterNeedsAttention(state))
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
                case .queued(matters: true):
                    _waiterDidQueue()
                case .queued(matters: false):
                    break
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
