//
//  AsyncWaitQueue.swift
//  SynchronizationKit
//

/// The tasks waiting on an asynchronous primitive, in arrival order, served
/// by priority.
///
/// Lives inside the owning primitive's state so that joining the queue and
/// checking whether there is anything to wait for happen under one lock.
package struct _AsyncWaitQueue<Request: Sendable>: Sendable {
    private var waiters: [_AsyncWaiter<Request>] = []

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
        waiters.isEmpty
    }

    package var count: Int {
        waiters.count
    }

    /// The waiter to serve next: the earliest of those at the highest
    /// priority.
    private var indexOfNext: Int? {
        var best: Int?
        for index in waiters.indices {
            if let current = best, waiters[index].priority <= waiters[current].priority {
                continue
            }
            best = index
        }
        return best
    }

    package mutating func append(_ waiter: _AsyncWaiter<Request>) {
        waiters.append(waiter)
        _noteArrival(at: waiter.priority)
    }

    package mutating func remove(_ waiter: _AsyncWaiter<Request>) {
        let count = waiters.count
        waiters.removeAll { $0 === waiter }
        if waiters.count != count {
            _noteDeparture(at: waiter.priority)
        }
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
        guard waiters.contains(where: { $0 === waiter }) else {
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
    /// to do unless it was the last at the maximum, and then a scan of who
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
        var count = 0
        for remaining in waiters {
            if let current = highest {
                if remaining.priority > current {
                    highest = remaining.priority
                    count = 1
                } else if remaining.priority == current {
                    count += 1
                }
            } else {
                highest = remaining.priority
                count = 1
            }
        }
        highestPriority = highest
        highestPriorityCount = count
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
        guard let index = indexOfNext, isAdmissible(waiters[index]) else {
            return nil
        }
        let waiter = waiters.remove(at: index)
        _noteDeparture(at: waiter.priority)
        return waiter
    }
}
