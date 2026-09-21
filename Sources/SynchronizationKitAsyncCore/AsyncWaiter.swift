//
//  AsyncWaiter.swift
//  SynchronizationKit
//

import CSynchronizationKitCore
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
/// `@safe`: the unsafe parts are the task reference and the backward queue
/// link, and every use of either is marked as such. `@unchecked Sendable`
/// for the task reference: the SDK's `UnsafeCurrentTask` does not declare
/// `Sendable`, and escalating a task from another thread is one of the
/// operations its documentation permits.
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

    // The stored properties are in the order that leaves no padding between
    // them, which is not the order they would be read in: `phase` is nine
    // bytes, and the one-byte fields fill the word it starts — `request` too,
    // where it is that small. That is sixty-four bytes of object rather than
    // eighty, which is one allocation size class down and one cache line
    // rather than two.

    /// The waiting task. Valid for as long as the task waits, and, once
    /// granted, for as long as it then holds what it was granted. `nil` for
    /// a thread, which has no task to escalate.
    @unsafe package let task: UnsafeCurrentTask?

    // The mutable fields below are guarded by the owner's state lock, which
    // is what keeps two accesses to one of them from overlapping; the runtime
    // check for such an overlap proves the same thing again on every access,
    // and on the way to a handoff that was some twenty checks. So they are
    // declared `@exclusivity(unchecked)`.
    //
    // That is safe for any caller, which is what `@safe` claims. An overlap
    // needs an access that lasts — a modify, which an `inout` argument or a
    // mutating call opens — and a read of a copyable value is over by the
    // time it is used. Only this module can write these fields, and it
    // writes them by plain assignment alone. `previous` is the exception,
    // and says why.

    @safe @exclusivity(unchecked) package internal(set) var phase: Phase = .pending

    /// The waiter's priority as last observed. An escalation handler raises
    /// it while the task waits, through `_AsyncWaitQueue.raisePriority`, so
    /// the queue's own record of its maximum keeps up.
    @safe @exclusivity(unchecked) package internal(set) var priority: TaskPriority

    /// Whether the waiter is linked into a queue: what leaving and being
    /// raised consult, in place of a search. The queue's to write, as the
    /// links below are.
    @safe @exclusivity(unchecked) internal var isQueued = false

    /// What the task is waiting for.
    package let request: Request

    // MARK: Queue links

    // The queue is a list threaded through its waiters rather than an array
    // of them, so that a waiter can leave from the middle — which is what a
    // cancellation is — without being searched for. The forward link is what
    // holds every waiter behind the head; the backward one holds nothing, so
    // that two neighbours do not hold each other alive. All of these are the
    // queue's to write, under the owner's state lock like `phase`.

    /// The waiter behind this one, or `nil` at the tail.
    @safe @exclusivity(unchecked) internal var next: _AsyncWaiter<Request>?

    /// The waiter ahead of this one, or `nil` at the head.
    ///
    /// `unowned(unsafe)`: neither retained nor checked. The check has
    /// nothing to catch — a linked waiter's predecessor is held, for as long
    /// as the two stay linked, by the `next` of the waiter ahead of it or by
    /// the queue's head, and `_link` and `_unlink` move both links together
    /// — and a checked `unowned` costs an atomic update of the waiter's
    /// reference counts for every load and store. What that rests on is the
    /// list's invariant rather than anything the declaration can promise, so
    /// this is the one field here that is not `@safe`: every use of it is
    /// marked, and all of them are in those two methods.
    @exclusivity(unchecked) internal unowned(unsafe) var previous: _AsyncWaiter<Request>?

    /// When the waiter joined the queue, as a count of arrivals before it.
    /// What orders it among waiters of the same priority — including a
    /// priority it is raised to after arriving, where it takes the place its
    /// arrival earns rather than the tail.
    @safe @exclusivity(unchecked) internal var arrival: UInt64 = 0

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
    @_specialize(exported: true, where Request == Void)
    @_specialize(exported: true, where Request == _Access)
    package func grant() -> _Grant {
        guard case .waiting(let parking) = phase else {
            preconditionFailure("queued a waiter that was not waiting")
        }
        phase = .granted
        unsafe sk_tsan_release(Unmanaged.passUnretained(self).toOpaque())
        return _Grant(parking: parking)
    }
}
