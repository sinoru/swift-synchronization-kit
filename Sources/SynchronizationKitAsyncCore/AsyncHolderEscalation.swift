//
//  AsyncHolderEscalation.swift
//  SynchronizationKit
//

// `Mutex` is the type of a requirement below, as in `_AsyncWaitQueueOwner`.
package import SynchronizationKitMutex

/// A task holding what others wait for.
///
/// `@safe` and `@unchecked Sendable` for the reasons `_AsyncWaiter` is.
@safe
package struct _AsyncHolder: @unchecked Sendable {
    /// The holding task. Valid only while the owner's state still names it;
    /// `_AsyncHolderEscalating` explains what pins it.
    @unsafe package let task: UnsafeCurrentTask?

    /// The highest priority the holder has been observed or escalated to.
    /// Escalation only ever raises a task's priority, so this can lag the
    /// truth but never overstate it.
    package var priority: TaskPriority

    package init(task: UnsafeCurrentTask?, priority: TaskPriority) {
        unsafe self.task = task
        self.priority = priority
    }

    /// Records `priority` as the holder's if it is higher than what is
    /// recorded, and returns the task to escalate to it.
    ///
    /// `nil` if the holder is already at or above `priority`, or has no task
    /// to raise — which the record still notes, so the holder is not offered
    /// again.
    package mutating func _raise(to priority: TaskPriority) -> UnsafeCurrentTask? {
        guard priority > self.priority else {
            return nil
        }
        self.priority = priority
        return unsafe task
    }
}

/// A wait-queue owner whose holders are tasks, and which raises them to the
/// priority of whoever waits on them: what the actor runtime does for actors
/// and the kernel does for `Mutex`, and what the runtime cannot do on its own
/// for a task suspended on a continuation, since it does not know who will
/// resume it.
///
/// The owner names its holders through `_nextEscalation` and
/// `_needsEscalation`; the loop that raises them, and the lock that guards
/// it, are here.
///
/// ## Lock ordering
///
/// `_AsyncWaitQueueOwner` explains why `state` is innermost and never resumes
/// or escalates a task. The lock added here sits outside it:
///
/// - `escalation` is held while escalating a holder, which is why handlers
///   only ever *try* to take it and never wait on it. Its second job is to
///   pin the holder: `UnsafeCurrentTask` does not keep a task alive, so a
///   release passes through this lock after giving the hold up, and a
///   departing holder cannot return — and so cannot finish and be destroyed —
///   while an escalation that already read it is in flight.
/// - The runtime's status locks are taken only from inside `escalation`, and
///   from `resume`, which is always called with neither of ours held.
package protocol _AsyncHolderEscalating: _AsyncWaitQueueOwner {
    /// Held while escalating a holder, and passed through by a release to pin
    /// the departing holder. See the lock-ordering note above.
    var escalation: Mutex<Void> { get }

    /// Records the next escalation to perform, and returns it: a holder below
    /// the highest waiting priority, raised to it. Called with the state lock
    /// held, and only from inside `escalation`, which is what keeps the holder
    /// alive between this read and the escalation itself.
    func _nextEscalation(_ state: inout State) -> (UnsafeCurrentTask, TaskPriority)?

    /// Whether any holder is below the highest waiting priority. Called with
    /// the state lock held.
    func _needsEscalation(_ state: State) -> Bool
}

@available(anyAppleOS 26.0, *)
extension _AsyncHolderEscalating {
    /// Raises every holder's priority to the highest waiting priority, where
    /// that is higher, and keeps doing so until nothing is left to raise.
    ///
    /// Safe to call from an escalation handler: it never waits. If another
    /// thread is already escalating, that thread re-checks the queue before
    /// it gives the escalation lock up, so a priority raised in the meantime
    /// is not lost.
    package func _escalateHoldersIfNeeded() {
        while true {
            guard escalation._unsafeTryLock() else {
                return
            }

            while let (task, priority) = unsafe state.withLock({ unsafe _nextEscalation(&$0) }) {
                unsafe task.escalatePriority(to: priority)
            }

            escalation._unsafeUnlock()

            guard state.withLock({ _needsEscalation($0) }) else {
                return
            }
        }
    }

    /// Waits out any escalation in flight, so that a holder which has just
    /// given its hold up does not return — and so cannot finish and be
    /// destroyed — while an escalation that read its task is still using it.
    ///
    /// Called by a release, after the state has been updated and outside
    /// every lock.
    package func _pinDepartingHolder() {
        escalation._unsafeLock()
        escalation._unsafeUnlock()
    }
}
