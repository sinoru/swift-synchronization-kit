//
//  AsyncWaitQueue.swift
//  SynchronizationKit
//

/// The tasks waiting on an asynchronous primitive, in arrival order, served
/// by priority.
///
/// Lives inside the owning primitive's state so that joining the queue and
/// checking whether there is anything to wait for happen under one lock.
///
/// A doubly linked list threaded through the waiters themselves, kept in
/// the order it is served: by priority, and by arrival among equals. The
/// head is therefore always the waiter to serve next, and the highest
/// priority present is the head's. Arriving links in behind the last waiter
/// that outranks or matches the newcomer — found through a record of the
/// last waiter at each priority present, of which there are as many as
/// there are priorities in use, a handful at most — and leaving, on
/// cancellation or on being served, unlinks in place. Nothing walks the
/// queue: an array of waiters made serving a scan, cancellation a search,
/// and every operation the length of the queue, which under a few hundred
/// waiters was most of what a handoff cost; and a list served from the head
/// still walked past every lower-priority waiter to reach a higher one at
/// the tail, and walked the whole queue again when it left.
///
/// Noncopyable, for the reason `_AsyncWaitState` gives.
package struct _AsyncWaitQueue<Request: Sendable>: ~Copyable, Sendable {
    /// The earliest waiter at the highest priority, which holds the rest
    /// through its forward links.
    private var head: _AsyncWaiter<Request>?

    /// The priorities present among the waiters, highest first, and the last
    /// waiter at each: `priorities[i]` and `lastAtPriority[i]` are one entry.
    ///
    /// Where an arrival at that priority goes, and where one at a priority
    /// not yet present goes: behind the last waiter of the nearest higher
    /// one. One entry per priority in use, so the walk over it is short
    /// however long the queue is.
    ///
    /// Two arrays rather than one of pairs. The walk that finds an entry
    /// reads priorities alone, and a pair holding a waiter is a value type
    /// containing a reference, which needs reference counting wherever one
    /// is read. The waiters are a `ContiguousArray` because an `Array` of a
    /// class type carries the check for an `NSArray` backing where the
    /// Objective-C runtime is present.
    private var priorities: [TaskPriority] = []
    private var lastAtPriority: ContiguousArray<_AsyncWaiter<Request>> = []

    /// How many waiters have ever joined; stamped on each as it does.
    private var arrivals: UInt64 = 0

    /// How many waiters are linked in.
    package private(set) var count = 0

    @_specialize(exported: true, where Request == Void)
    @_specialize(exported: true, where Request == _Access)
    package init() {}

    package var isEmpty: Bool {
        @_specialize(exported: true, where Request == Void)
        @_specialize(exported: true, where Request == _Access)
        get { head == nil }
    }

    /// The highest priority among the waiters, or `nil` if none are waiting.
    ///
    /// Asked at every handoff and every arrival, to know whether a holder
    /// needs escalating; the head's, since the queue is kept in that order.
    package var highestPriority: TaskPriority? {
        @_specialize(exported: true, where Request == Void)
        @_specialize(exported: true, where Request == _Access)
        get { head?.priority }
    }

    @_specialize(exported: true, where Request == Void)
    @_specialize(exported: true, where Request == _Access)
    package mutating func append(_ waiter: _AsyncWaiter<Request>) {
        precondition(!waiter.isQueued, "queued a waiter twice")
        waiter.arrival = arrivals
        arrivals += 1
        _link(waiter)
    }

    @_specialize(exported: true, where Request == Void)
    @_specialize(exported: true, where Request == _Access)
    package mutating func remove(_ waiter: _AsyncWaiter<Request>) {
        guard waiter.isQueued else {
            return
        }
        _unlink(waiter)
    }

    /// Records `priority` as `waiter`'s, whether or not it has joined the
    /// queue yet — an escalation can land on a waiter still on its way in,
    /// and `append` then places it by the raised priority as it is.
    ///
    /// The one way a queued waiter's priority changes, so that the order
    /// kept here stays true; nothing else may write it. A queued waiter is
    /// taken out and put back where the new priority sends it, among those
    /// of that priority by when it arrived.
    internal mutating func raisePriority(of waiter: _AsyncWaiter<Request>, to priority: TaskPriority) {
        guard priority > waiter.priority else {
            return
        }
        guard waiter.isQueued else {
            waiter.priority = priority
            return
        }
        _unlink(waiter)
        waiter.priority = priority
        _link(waiter)
    }

    /// Whether any queued waiter satisfies `predicate`.
    ///
    /// A walk of the whole queue, which nothing on the way to a handoff asks
    /// for: only a check on the way to a trap does, once it has found the
    /// waiter's own task among the holders.
    @_specialize(exported: true, where Request == Void)
    @_specialize(exported: true, where Request == _Access)
    package func contains(where predicate: (_AsyncWaiter<Request>) -> Bool) -> Bool {
        var current = head
        while let waiter = current {
            if predicate(waiter) {
                return true
            }
            current = waiter.next
        }
        return false
    }

    /// Takes the waiter to serve next out of the queue.
    @_specialize(exported: true, where Request == Void)
    @_specialize(exported: true, where Request == _Access)
    package mutating func removeNext() -> _AsyncWaiter<Request>? {
        removeNext { _ in true }
    }

    /// Takes the waiter to serve next out of the queue, if `isAdmissible`
    /// says it may be served; leaves the queue untouched otherwise.
    ///
    /// The answer is asked of the head alone: a waiter behind it is never
    /// served ahead of it, whatever it asked for.
    @_specialize(exported: true, where Request == Void)
    @_specialize(exported: true, where Request == _Access)
    package mutating func removeNext(
        where isAdmissible: (_AsyncWaiter<Request>) -> Bool
    ) -> _AsyncWaiter<Request>? {
        guard let waiter = head, isAdmissible(waiter) else {
            return nil
        }
        _unlink(waiter)
        return waiter
    }

    // MARK: - Linking

    /// Puts `waiter` where its priority and arrival place it: behind every
    /// waiter of higher priority, and among those of its own behind the ones
    /// that arrived earlier.
    private mutating func _link(_ waiter: _AsyncWaiter<Request>) {
        let priority = waiter.priority

        // Past the priorities that outrank this one. What they leave behind
        // is the last waiter of the nearest, which a newcomer at a priority
        // not yet present goes behind.
        var index = 0
        while index < priorities.count, priorities[index] > priority {
            index += 1
        }
        var after = index > 0 ? lastAtPriority[index - 1] : nil

        if index < priorities.count, priorities[index] == priority {
            // Waiters at this priority are already queued. A fresh arrival
            // is the latest of them and goes last; one put back after being
            // raised goes behind those that arrived before it, which this
            // walks back to — over the later arrivals at this priority only,
            // and a raised waiter is the rare case.
            let last = lastAtPriority[index]
            var candidate: _AsyncWaiter<Request>? = last
            while let current = candidate, current.priority == priority, current.arrival > waiter.arrival {
                candidate = unsafe current.previous
            }
            after = candidate
            if after === last {
                lastAtPriority[index] = waiter
            }
        } else {
            priorities.insert(priority, at: index)
            lastAtPriority.insert(waiter, at: index)
        }

        if let after {
            unsafe waiter.previous = after
            waiter.next = after.next
            unsafe after.next?.previous = waiter
            after.next = waiter
        } else {
            unsafe waiter.previous = nil
            waiter.next = head
            unsafe head?.previous = waiter
            head = waiter
        }
        waiter.isQueued = true
        count += 1
    }

    /// Takes `waiter` out of the list, wherever it is.
    private mutating func _unlink(_ waiter: _AsyncWaiter<Request>) {
        let priority = waiter.priority
        if let index = priorities.firstIndex(of: priority),
            lastAtPriority[index] === waiter
        {
            // The last at its priority. The one ahead of it takes over if it
            // is at the same priority; otherwise the priority is gone.
            if let previous = unsafe waiter.previous, previous.priority == priority {
                lastAtPriority[index] = previous
            } else {
                priorities.remove(at: index)
                lastAtPriority.remove(at: index)
            }
        }

        let previous = unsafe waiter.previous
        let next = waiter.next
        if let previous {
            previous.next = next
        } else {
            head = next
        }
        unsafe next?.previous = previous
        unsafe waiter.previous = nil
        waiter.next = nil
        waiter.isQueued = false
        count -= 1
    }
}
