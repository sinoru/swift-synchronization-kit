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
/// A doubly linked list threaded through the waiters themselves, which is
/// what keeps every operation a handoff makes clear of the queue's length:
/// arriving links in at the tail, serving unlinks at the head, and leaving
/// on cancellation unlinks from wherever the waiter is. An array of waiters
/// made the same three a scan, a shift, and a search, and under a few hundred
/// waiters the scan was most of what a handoff cost.
package struct _AsyncWaitQueue<Request: Sendable>: Sendable {
    /// The earliest waiter, which holds the rest through its forward links.
    private var head: _AsyncWaiter<Request>?

    /// The latest waiter, where the next arrival links in.
    private var tail: _AsyncWaiter<Request>?

    /// How many waiters are linked in.
    package private(set) var count = 0

    /// The highest priority among the waiters, or `nil` if none are waiting.
    ///
    /// Kept as waiters come and go rather than found on demand: whether a
    /// holder needs escalating is asked at every handoff and every arrival,
    /// and a scan of the queue at each of those was most of what a handoff
    /// cost under load. Raised by `append` and `raisePriority`, and
    /// recomputed only when the last waiter at that priority leaves — the
    /// actor runtime keeps its queue's maximum in the actor's status word
    /// for the same reason.
    package private(set) var highestPriority: TaskPriority?

    /// How many waiters are at `highestPriority`. Usually all of them, the
    /// common queue being of one priority, which is exactly the queue a
    /// departure would otherwise have to scan every time.
    private var highestPriorityCount = 0

    package init() {}

    package var isEmpty: Bool {
        head == nil
    }

    /// The waiter to serve next: the earliest of those at the highest
    /// priority.
    ///
    /// The maximum is already kept, so this walks only as far as the first
    /// waiter at it — the head, in the common queue of one priority.
    private var nextToServe: _AsyncWaiter<Request>? {
        guard let highest = highestPriority else {
            return nil
        }
        var candidate = head
        while let current = candidate, current.priority < highest {
            candidate = current.next
        }
        return candidate
    }

    package mutating func append(_ waiter: _AsyncWaiter<Request>) {
        precondition(!waiter.isQueued, "queued a waiter twice")
        waiter.previous = tail
        if let tail {
            tail.next = waiter
        } else {
            head = waiter
        }
        tail = waiter
        waiter.isQueued = true
        count += 1
        _noteArrival(at: waiter.priority)
    }

    package mutating func remove(_ waiter: _AsyncWaiter<Request>) {
        guard waiter.isQueued else {
            return
        }
        _unlink(waiter)
        _noteDeparture(at: waiter.priority)
    }

    /// Records `priority` as `waiter`'s, whether or not it has joined the
    /// queue yet — an escalation can land on a waiter still on its way in,
    /// and `append` then takes the raised priority as it is.
    ///
    /// The one way a queued waiter's priority changes, so that the maximum
    /// kept here stays true; nothing else may write it.
    package mutating func raisePriority(of waiter: _AsyncWaiter<Request>, to priority: TaskPriority) {
        let previous = waiter.priority
        guard priority > previous else {
            return
        }
        guard waiter.isQueued else {
            waiter.priority = priority
            return
        }

        // Leave at the old priority, then arrive at the new: the departure
        // is noted before the waiter changes, so that a rescan it sets off
        // — this being the last waiter at the maximum — counts the waiter
        // where it still is, and the arrival then counts it once where it
        // goes. Written first, it would be counted at the new priority by
        // both.
        _noteDeparture(at: previous)
        waiter.priority = priority
        _noteArrival(at: priority)
    }

    /// Takes `waiter` out of the list, wherever it is.
    private mutating func _unlink(_ waiter: _AsyncWaiter<Request>) {
        let previous = waiter.previous
        let next = waiter.next
        if let previous {
            previous.next = next
        } else {
            head = next
        }
        if let next {
            next.previous = previous
        } else {
            tail = previous
        }
        waiter.previous = nil
        waiter.next = nil
        waiter.isQueued = false
        count -= 1
    }

    /// Folds a waiter at `priority` into the maximum.
    private mutating func _noteArrival(at priority: TaskPriority) {
        if let highest = highestPriority {
            if priority > highest {
                highestPriority = priority
                highestPriorityCount = 1
            } else if priority == highest {
                highestPriorityCount += 1
            }
        } else {
            highestPriority = priority
            highestPriorityCount = 1
        }
    }

    /// Settles the maximum after a waiter at `priority` has left: nothing
    /// to do unless it was the last at the maximum, and then a walk of who
    /// is left.
    private mutating func _noteDeparture(at priority: TaskPriority) {
        guard priority == highestPriority else {
            return
        }
        highestPriorityCount -= 1
        guard highestPriorityCount == 0 else {
            return
        }

        var highest: TaskPriority?
        var atHighest = 0
        var candidate = head
        while let remaining = candidate {
            if let current = highest {
                if remaining.priority > current {
                    highest = remaining.priority
                    atHighest = 1
                } else if remaining.priority == current {
                    atHighest += 1
                }
            } else {
                highest = remaining.priority
                atHighest = 1
            }
            candidate = remaining.next
        }
        highestPriority = highest
        highestPriorityCount = atHighest
    }

    /// Takes the waiter to serve next out of the queue.
    package mutating func removeNext() -> _AsyncWaiter<Request>? {
        removeNext { _ in true }
    }

    /// Takes the waiter to serve next out of the queue, if `isAdmissible`
    /// says it may be served; leaves the queue untouched otherwise.
    ///
    /// The answer is asked of the head alone: a waiter behind it is never
    /// served ahead of it, whatever it asked for.
    package mutating func removeNext(
        where isAdmissible: (_AsyncWaiter<Request>) -> Bool
    ) -> _AsyncWaiter<Request>? {
        guard let waiter = nextToServe, isAdmissible(waiter) else {
            return nil
        }
        _unlink(waiter)
        _noteDeparture(at: waiter.priority)
        return waiter
    }
}
