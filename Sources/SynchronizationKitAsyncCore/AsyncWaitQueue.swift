//
//  AsyncWaitQueue.swift
//  SynchronizationKit
//

/// The tasks waiting on an asynchronous primitive, in arrival order, served
/// by priority.
///
/// Lives inside the owning primitive's state so that joining the queue and
/// checking whether there is anything to wait for happen under one lock.
package struct _AsyncWaitQueue: Sendable {
    private var waiters: [_AsyncWaiter] = []

    package init() {}

    package var isEmpty: Bool {
        waiters.isEmpty
    }

    package var count: Int {
        waiters.count
    }

    /// The highest priority among the waiters, or `nil` if none are waiting.
    package var highestPriority: TaskPriority? {
        waiters.lazy.map(\.priority).max()
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

    package mutating func append(_ waiter: _AsyncWaiter) {
        waiters.append(waiter)
    }

    package mutating func remove(_ waiter: _AsyncWaiter) {
        waiters.removeAll { $0 === waiter }
    }

    /// Takes the waiter to serve next out of the queue.
    package mutating func removeNext() -> _AsyncWaiter? {
        guard let index = indexOfNext else {
            return nil
        }
        return waiters.remove(at: index)
    }
}
