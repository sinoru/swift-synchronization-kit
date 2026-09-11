//
//  AsyncWaiter.swift
//  SynchronizationKit
//

import CSynchronizationKitCore
package import SynchronizationKitSemaphore

/// A task, or a thread, waiting in an `_AsyncWaitQueue`. Everything but
/// `task` and `request` is guarded by the owning primitive's state lock.
///
/// Most waiters are tasks, suspended on a continuation. A waiter may also be
/// a thread, blocked on a `_ThreadPark`: what `AsyncSemaphore` queues for its
/// blocking `wait()`. The queue does not tell the two apart — both have a
/// request and a priority, and both are served by `grant()` — and only the
/// end of the wait differs, which is `_Grant.complete()`'s business.
///
/// `Request` is what the task asked for, for a primitive that hands out more
/// than one kind of access — read or write, say. A primitive with one kind
/// uses `Void`.
///
/// `@safe`: the unsafe part is the task reference, and every read of it is
/// marked as such. `@unchecked Sendable` for the same reference: the SDK's
/// `UnsafeCurrentTask` does not declare `Sendable`, and escalating a task
/// from another thread is one of the operations its documentation permits.
///
/// A waiter's own address is the token its handoff is annotated on for
/// ThreadSanitizer: `grant()` releases it, `_AsyncWaitQueueOwner._wait`
/// acquires it once the task is back, and the two pair exactly once per
/// waiter. The handle's address would pair every grant with every resumption
/// and put edges on record that were never made.
@safe
package final class _AsyncWaiter<Request: Sendable>: @unchecked Sendable {
    package enum Phase {
        /// Created, but not yet suspended or blocked.
        case pending
        /// In the queue, suspended or blocked as `_Parking` says.
        case waiting(_Parking)
        /// Granted what it waited for; the waiter has been, or is being,
        /// woken.
        case granted
        /// Left the queue by cancellation; the continuation has been resumed,
        /// or will be told not to suspend at all. Only a task can be here: a
        /// thread has no cancellation.
        case cancelled
    }

    /// The waiting task. Valid for as long as the task waits, and, once
    /// granted, for as long as it then holds what it was granted. `nil` for
    /// a thread, which has no task to escalate.
    @unsafe package let task: UnsafeCurrentTask?

    /// What the task is waiting for.
    package let request: Request

    /// The waiter's priority as last observed. An escalation handler raises
    /// it while the task waits, through `_AsyncWaitQueue.raisePriority`, so
    /// the queue's own record of its maximum keeps up.
    package internal(set) var priority: TaskPriority

    package var phase: Phase = .pending

    // MARK: Queue links

    // The queue is a list threaded through its waiters rather than an array
    // of them, so that a waiter can leave from the middle — which is what a
    // cancellation is — without being searched for. The forward link is what
    // holds every waiter behind the head; the backward one is `unowned` so
    // that two neighbours do not hold each other alive. All of these are the
    // queue's to write, under the owner's state lock like `phase`.

    /// The waiter behind this one, or `nil` at the tail.
    internal var next: _AsyncWaiter<Request>?

    /// The waiter ahead of this one, or `nil` at the head.
    internal unowned var previous: _AsyncWaiter<Request>?

    /// Whether the waiter is linked into a queue: what leaving and being
    /// raised consult, in place of a search.
    internal var isQueued = false

    /// When the waiter joined the queue, as a count of arrivals before it.
    /// What orders it among waiters of the same priority — including a
    /// priority it is raised to after arriving, where it takes the place its
    /// arrival earns rather than the tail.
    internal var arrival: UInt64 = 0

    package init(task: UnsafeCurrentTask?, request: Request, priority: TaskPriority) {
        unsafe self.task = task
        self.request = request
        self.priority = priority
    }

    /// Marks the waiter as granted and returns the grant that wakes it, for
    /// the caller to complete once it has let go of the state lock.
    ///
    /// Also where the handoff is put on record for ThreadSanitizer: before
    /// the grant is handed back, so the edge exists by the time anything can
    /// wake on it. Under the state lock, which is fine — the call is an
    /// annotation, not a wait.
    ///
    /// - Precondition: The waiter is queued, which is to say suspended or
    ///   blocked.
    package func grant() -> _Grant {
        guard case .waiting(let parking) = phase else {
            preconditionFailure("queued a waiter that was not waiting")
        }
        phase = .granted
        unsafe sk_tsan_release(Unmanaged.passUnretained(self).toOpaque())
        return _Grant(parking: parking)
    }
}

// MARK: - How a waiter waits

/// Where a queued waiter is parked: what a grant has to poke to wake it.
package enum _Parking: Sendable {
    /// A task, suspended on this continuation.
    case continuation(CheckedContinuation<Void, any Error>)
    /// A thread, blocked in `_ThreadPark.semaphore`.
    case thread(_ThreadPark)
}

/// The semaphore a thread blocks on while it waits in the queue.
///
/// A class rather than a semaphore on the waiting thread's stack, so that the
/// signaling side holds a reference of its own for as long as it is inside
/// `signal()`. Otherwise the waiter, woken by the count going up, could
/// return and free the semaphore while the signaler is still in the wake
/// call on it — the classic way to destroy a semaphore out from under a
/// post. The queue entry and the waiting thread each keep it alive; the
/// grant takes the last reference the signaler needs.
package final class _ThreadPark: Sendable {
    package let semaphore = Semaphore(value: 0)

    package init() {}
}

/// A waiter taken out of the queue with what it asked for, waiting to be
/// woken.
///
/// Returned by `_AsyncWaiter.grant()` under the state lock, and completed
/// outside it: waking a task takes the task's status lock, which the lock
/// ordering in `_AsyncWaitQueueOwner` forbids inside ours, and waking a thread
/// is a kernel call there is no reason to hold a lock across.
package struct _Grant: Sendable {
    private let parking: _Parking

    fileprivate init(parking: _Parking) {
        self.parking = parking
    }

    /// Wakes the waiter: resumes the task, or signals the thread's park.
    package consuming func complete() {
        switch parking {
        case .continuation(let continuation):
            continuation.resume()
        case .thread(let park):
            park.semaphore.signal()
        }
    }
}
