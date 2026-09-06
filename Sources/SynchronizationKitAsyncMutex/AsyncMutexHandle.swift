//
//  AsyncMutexHandle.swift
//  SynchronizationKit
//

// Both name types in this handle's `package` declarations — the wait queue
// and the mutex it lives under — so both are imported at that level.
package import SynchronizationKitAsyncCore
package import SynchronizationKitMutex

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
/// The waiting — queueing, suspending, cancellation — comes from
/// `_AsyncWaitQueueOwner`; what this adds is the holder, and its escalation.
///
/// ## Lock ordering
///
/// `_AsyncWaitQueueOwner` explains why `state` is innermost and never resumes
/// or escalates a task. The lock added here sits outside it:
///
/// - `escalation` is held while escalating the holder, which is why handlers
///   only ever *try* to take it and never wait on it. Its second job is to
///   pin the holder: `UnsafeCurrentTask` does not keep a task alive, so
///   `_release` passes through this lock after giving the lock up, and a
///   departing holder cannot return — and so cannot finish and be destroyed —
///   while an escalation that already read it is in flight.
/// - The runtime's status locks are taken only from inside `escalation`, and
///   from `resume`, which is always called with neither of ours held.
package final class _AsyncMutexHandle: _AsyncWaitQueueOwner {
    /// The state proper. See the lock-ordering note above.
    package let state = Mutex<_State>(_State())

    /// Held while escalating the holder's priority, and passed through by
    /// `_release` to pin the holder. See the lock-ordering note above.
    private let escalation = Mutex<Void>(())

    internal init() {}
}

/// Who holds the lock and who is waiting for it. Guarded by `state`.
package struct _State: _AsyncWaitState {
    /// The task holding the lock, or `nil` while the lock is free.
    var holder: _Holder?

    package var queue = _AsyncWaitQueue()
}

/// The task holding the lock.
///
/// `@safe` and `@unchecked Sendable` for the reasons `_AsyncWaiter` is.
@safe
internal struct _Holder: @unchecked Sendable {
    /// The holding task. Valid only while `_State.holder` still names it;
    /// `_AsyncMutexHandle`'s lock-ordering note explains what pins it.
    @unsafe let task: UnsafeCurrentTask?

    /// The highest priority the holder has been observed or escalated to.
    /// Escalation only ever raises a task's priority, so this can lag the
    /// truth but never overstate it.
    var priority: TaskPriority
}

// MARK: - Acquiring

extension _AsyncMutexHandle {
    /// Takes the lock if it is free, without suspending.
    package func _tryAcquire() -> Bool {
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

    package func _acquireIfAvailable(_ state: inout _State, for waiter: _AsyncWaiter) -> Bool {
        guard state.holder == nil else {
            return false
        }
        state.holder = unsafe _Holder(task: waiter.task, priority: waiter.priority)
        return true
    }

    package func _waiterDidQueue() {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            _escalateHolderIfNeeded()
        }
    }

    package func _waiterPriorityDidRise() {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            _escalateHolderIfNeeded()
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
    internal func _release() {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            precondition(state.holder != nil, "AsyncMutex released while not held")

            guard let waiter = state.queue.removeNext() else {
                state.holder = nil
                return nil
            }

            state.holder = unsafe _Holder(task: waiter.task, priority: waiter.priority)
            return waiter.grant()
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
                  let priority = state.queue.highestPriority,
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
            guard let holder = state.holder, let priority = state.queue.highestPriority else {
                return false
            }
            return priority > holder.priority
        }
    }
}
