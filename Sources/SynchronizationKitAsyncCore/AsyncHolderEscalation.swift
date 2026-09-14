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

    /// The highest priority the holder has been observed or escalated to,
    /// once anything has asked. `nil` until then: a holder that took what it
    /// holds without waiting is not asked, since nothing needs the answer
    /// until a waiter arrives, and the fast path is the one a lock is
    /// mostly taken on. The first question reads the task's own priority —
    /// a relaxed load of its status word, which the runtime makes for
    /// `UnsafeCurrentTask.priority` from whichever thread asks and calls
    /// inherently racy itself. Escalation only ever raises a task's
    /// priority, so once recorded this can lag the truth but never overstate
    /// it.
    private var priority: TaskPriority?

    /// Whether an escalation has read `task` to raise it. A release of a
    /// holder so read has to wait the escalation out before the task can be
    /// allowed to finish; one never read can return at once.
    package private(set) var wasReadForEscalation = false

    /// A holder whose priority nothing has asked for yet.
    package init(task: UnsafeCurrentTask?) {
        unsafe self.task = task
    }

    /// A holder that waited, at the priority it was served at.
    package init(task: UnsafeCurrentTask?, priority: TaskPriority) {
        unsafe self.task = task
        self.priority = priority
    }

    /// Whether the holder sits below `priority`, and so is one an escalation
    /// to it would raise. `false` for a holder with no task, which nothing
    /// can raise.
    package func _isBelow(_ priority: TaskPriority) -> Bool {
        guard let task = unsafe task else {
            return false
        }
        return unsafe (self.priority ?? task.priority) < priority
    }

    /// Records `priority` as the holder's if it is higher than what is
    /// recorded, or than what the task reports where nothing is, and
    /// returns the task to escalate to it.
    ///
    /// `nil` if the holder is already at or above `priority`, or has no task
    /// to raise. What was observed on the way is recorded either way, so
    /// the holder is not asked again.
    package mutating func _raise(to priority: TaskPriority) -> UnsafeCurrentTask? {
        guard let task = unsafe task else {
            return nil
        }
        let current = unsafe self.priority ?? task.priority
        guard priority > current else {
            self.priority = current
            return nil
        }
        self.priority = priority
        wasReadForEscalation = true
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
///   pin the holder: `UnsafeCurrentTask` does not keep a task alive, so the
///   release of a holder an escalation has read passes through this lock
///   after giving the hold up, and that holder cannot return — and so cannot
///   finish and be destroyed — while the escalation is in flight. A holder
///   no escalation has read says so, and its release passes through nothing.
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

extension _AsyncHolderEscalating {
    /// A queued waiter matters to an owner that escalates when a holder is
    /// below it — the same question `_needsEscalation` answers, asked in the
    /// critical section that queued the waiter rather than in one of its own.
    package func _queuedWaiterNeedsAttention(_ state: State) -> Bool {
        _needsEscalation(state)
    }
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

    /// What a release does for escalation once it has updated the state and
    /// let go of the state lock, on the two facts the critical section
    /// established: whether the departing holder was `pinned` — read by an
    /// escalation, which may still be using its task — and whether the
    /// holders it left behind are `outranked` by the queue behind them,
    /// which the new holder inherits.
    ///
    /// A pinned departure waits out the escalation in flight, so that the
    /// holder does not return — and so cannot finish and be destroyed —
    /// while its task is still being raised; then it looks at the queue
    /// again, and `outranked` is not consulted. That look is not optional:
    /// holding the escalation lock to pin turns away anyone who tries it
    /// meanwhile — a waiter that has just queued above the new holder
    /// returns from `_escalateHoldersIfNeeded` on the failed try, trusting
    /// whoever holds the lock to look again before letting go — and a pin
    /// looks at nothing. So the departing holder looks, once, after the pin.
    ///
    /// A departure that was never read turns nobody away and has nothing to
    /// wait for, so the answer the critical section gave still stands: it
    /// raises the holders left behind if they are outranked, and is
    /// otherwise done. That is every uncontended release, which therefore
    /// takes no lock past the state lock it has already let go of.
    package func _departHolder(pinned: Bool, outranked: Bool) {
        if pinned {
            escalation._unsafeLock()
            escalation._unsafeUnlock()

            if state.withLock({ _needsEscalation($0) }) {
                _escalateHoldersIfNeeded()
            }
        } else if outranked {
            _escalateHoldersIfNeeded()
        }
    }
}
