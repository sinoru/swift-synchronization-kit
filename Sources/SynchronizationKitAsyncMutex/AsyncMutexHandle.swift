//
//  AsyncMutexHandle.swift
//  SynchronizationKit
//

import SynchronizationKitMutex

/// The bookkeeping behind `AsyncMutex`: which task holds the lock, and which
/// tasks are waiting for it.
///
/// This is a class where `_MutexHandle` is inline storage because the
/// cancellation and priority-escalation handlers installed around a wait are
/// closures that reach this state from whichever thread cancels or escalates
/// the waiting task, and a closure cannot capture a borrowed inline value. It
/// costs one allocation per lock; the protected value itself is still stored
/// inline in the `AsyncMutex`.
///
/// ## Lock ordering
///
/// Three locks meet here, and the handlers above are what make the order
/// matter: the runtime invokes a cancellation or escalation handler while it
/// holds the affected task's own status lock, and it takes that same status
/// lock to resume or escalate the task. Any lock of ours that a handler waits
/// on must therefore never be held while we resume or escalate a task, or a
/// thread escalating the holder could wait on a status lock whose owner is
/// waiting on us.
///
/// - `state` is innermost. Its critical sections update the state and
///   return; they never resume a continuation or escalate a task. Handlers
///   may take it freely.
/// - `escalation` is held while escalating the holder, which is why handlers
///   only ever *try* to take it and never wait on it. Its second job is to
///   pin the holder: `UnsafeCurrentTask` does not keep a task alive, so
///   `_unlock` passes through this lock after giving the lock up, and a
///   departing holder cannot return — and so cannot finish and be destroyed —
///   while an escalation that already read it is in flight.
/// - The runtime's status locks are taken only from inside `escalation`, and
///   from `resume`, which is always called with neither of ours held.
@usableFromInline
internal final class _AsyncMutexHandle: @unchecked Sendable {
    /// The state proper. See the lock-ordering note above.
    private let state = Mutex<_State>(_State())

    /// Held while escalating the holder's priority, and passed through by
    /// `_unlock` to pin the holder. See the lock-ordering note above.
    private let escalation = Mutex<Void>(())

    internal init() {}
}

/// Who holds the lock and who is waiting for it. Guarded by `state`.
private struct _State: Sendable {
    /// The task holding the lock, or `nil` while the lock is free.
    var holder: _Holder?

    /// Tasks waiting for the lock, in arrival order.
    var waiters: [_Waiter] = []

    /// The waiter to hand the lock to next: the earliest of those at the
    /// highest priority.
    var indexOfNextWaiter: Int? {
        var best: Int?
        for index in waiters.indices {
            if let current = best, waiters[index].priority <= waiters[current].priority {
                continue
            }
            best = index
        }
        return best
    }

    /// The highest priority among the waiters, or `nil` if none are waiting.
    var highestWaitingPriority: TaskPriority? {
        waiters.lazy.map(\.priority).max()
    }
}

/// The task holding the lock.
///
/// `@safe`: the unsafe part is the task reference, and every read of it is
/// marked as such. `@unchecked Sendable` for the same reference: the SDK's
/// `UnsafeCurrentTask` does not declare `Sendable`, and escalating a task
/// from another thread is one of the operations its documentation permits.
@safe
private struct _Holder: @unchecked Sendable {
    /// The holding task. Valid only while `_State.holder` still names it;
    /// `_AsyncMutexHandle`'s lock-ordering note explains what pins it.
    @unsafe let task: UnsafeCurrentTask?

    /// The highest priority the holder has been observed or escalated to.
    /// Escalation only ever raises a task's priority, so this can lag the
    /// truth but never overstate it.
    var priority: TaskPriority
}

/// A task waiting for the lock. Everything but `task` is guarded by `state`.
///
/// `@safe` for the reason `_Holder` is.
@safe
private final class _Waiter: @unchecked Sendable {
    enum Phase {
        /// Created, but not yet suspended on a continuation.
        case pending
        /// In the queue, suspended on this continuation.
        case waiting(CheckedContinuation<Void, any Error>)
        /// Handed the lock; the continuation has been resumed.
        case granted
        /// Left the queue by cancellation; the continuation has been resumed,
        /// or will be told not to suspend at all.
        case cancelled
    }

    /// The waiting task. Valid for as long as the task waits, and, once
    /// granted, for as long as it then holds the lock.
    @unsafe let task: UnsafeCurrentTask?

    /// The waiter's priority as last observed. An escalation handler raises
    /// it while the task waits.
    var priority: TaskPriority

    var phase: Phase = .pending

    init(task: UnsafeCurrentTask?, priority: TaskPriority) {
        unsafe self.task = task
        self.priority = priority
    }
}

// MARK: - Acquiring

extension _AsyncMutexHandle {
    /// Takes the lock if it is free, without suspending.
    internal func _tryLock() -> Bool {
        let task = unsafe withUnsafeCurrentTask { unsafe $0 }
        let priority = Task.currentPriority

        return state.withLock { state in
            guard state.holder == nil else {
                return false
            }
            state.holder = unsafe _Holder(task: task, priority: priority)
            return true
        }
    }

    /// Takes the lock, suspending until it is handed over if another task
    /// holds it.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting,
    ///   or would have to wait while already cancelled.
    internal nonisolated(nonsending) func _lock() async throws {
        if _tryLock() {
            return
        }

        let waiter = unsafe withUnsafeCurrentTask { task in
            unsafe _Waiter(task: task, priority: Task.currentPriority)
        }

        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            try await withTaskPriorityEscalationHandler {
                try await _wait(as: waiter)
            } onPriorityEscalated: { _, newPriority in
                state.withLock { _ in
                    if newPriority > waiter.priority {
                        waiter.priority = newPriority
                    }
                }
                _escalateHolderIfNeeded()
            }
        } else {
            try await _wait(as: waiter)
        }
    }

    private enum _Arrival {
        /// The lock was free after all; `waiter` took it.
        case acquired
        /// `waiter` joined the queue.
        case queued
        /// `waiter` was cancelled before it could join the queue.
        case cancelled
    }

    /// Queues `waiter` and suspends until it is handed the lock or cancelled.
    private nonisolated(nonsending) func _wait(as waiter: _Waiter) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let arrival = state.withLock { state -> _Arrival in
                    // The lock may have been released between the fast path
                    // and here. A cancelled task may still take a free lock;
                    // what it may not do is wait.
                    if state.holder == nil {
                        state.holder = unsafe _Holder(task: waiter.task, priority: waiter.priority)
                        waiter.phase = .granted
                        return .acquired
                    }

                    switch waiter.phase {
                    case .pending:
                        waiter.phase = .waiting(continuation)
                        state.waiters.append(waiter)
                        return .queued
                    case .cancelled:
                        return .cancelled
                    case .waiting, .granted:
                        preconditionFailure("AsyncMutex waiter suspended twice")
                    }
                }

                switch arrival {
                case .acquired:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .queued:
                    if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
                        _escalateHolderIfNeeded()
                    }
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
                    state.waiters.removeAll { $0 === waiter }
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

// MARK: - Releasing

extension _AsyncMutexHandle {
    /// Releases the lock, handing it directly to the next waiter if there is
    /// one.
    ///
    /// The handoff transfers ownership while the lock stays marked as held,
    /// so a newcomer cannot slip in between a release and the waiter's
    /// resumption, and the waiter never has to contend again.
    internal func _unlock() {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            precondition(state.holder != nil, "AsyncMutex released while not held")

            guard let index = state.indexOfNextWaiter else {
                state.holder = nil
                return nil
            }

            let waiter = state.waiters.remove(at: index)
            guard case .waiting(let continuation) = waiter.phase else {
                preconditionFailure("AsyncMutex queued a waiter that was not waiting")
            }
            waiter.phase = .granted
            state.holder = unsafe _Holder(task: waiter.task, priority: waiter.priority)
            return continuation
        }

        next?.resume()

        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            // Pin: an escalation that read the departing holder before the
            // handoff above is still using its task reference, and this task
            // must not get the chance to finish until that is over.
            escalation._unsafeLock()
            escalation._unsafeUnlock()

            // The new holder inherits the queue that was behind it, which may
            // outrank it.
            _escalateHolderIfNeeded()
        }
    }
}

// MARK: - Priority escalation

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension _AsyncMutexHandle {
    /// Raises the holder's priority to the highest waiting priority, if that
    /// is higher, and keeps doing so until nothing is left to raise.
    ///
    /// Safe to call from an escalation handler: it never waits. If another
    /// thread is already escalating, that thread re-checks the queue before
    /// it gives the escalation lock up, so a priority raised in the meantime
    /// is not lost.
    internal func _escalateHolderIfNeeded() {
        while true {
            guard escalation._unsafeTryLock() else {
                return
            }

            while let (task, priority) = unsafe _nextEscalation() {
                unsafe task.escalatePriority(to: priority)
            }

            escalation._unsafeUnlock()

            guard _needsEscalation() else {
                return
            }
        }
    }

    /// Records the next escalation to perform, and returns it. Called only
    /// with `escalation` held, which is what keeps the holder alive between
    /// this read and the escalation itself.
    @unsafe
    private func _nextEscalation() -> (UnsafeCurrentTask, TaskPriority)? {
        unsafe state.withLock { state -> (UnsafeCurrentTask, TaskPriority)? in
            guard var holder = state.holder,
                  let task = unsafe holder.task,
                  let priority = state.highestWaitingPriority,
                  priority > holder.priority
            else {
                return nil
            }
            holder.priority = priority
            state.holder = holder
            return unsafe (task, priority)
        }
    }

    private func _needsEscalation() -> Bool {
        state.withLock { state in
            guard let holder = state.holder, let priority = state.highestWaitingPriority else {
                return false
            }
            return priority > holder.priority
        }
    }
}

// MARK: - Test support

extension _AsyncMutexHandle {
    /// How many tasks are queued for the lock. For tests, which need to know
    /// when a task has actually joined the queue before releasing the lock
    /// or cancelling it.
    internal var _waiterCount: Int {
        state.withLock { $0.waiters.count }
    }
}
