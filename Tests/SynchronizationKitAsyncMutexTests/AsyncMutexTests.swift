//
//  AsyncMutexTests.swift
//  SynchronizationKit
//

import SynchronizationKitMutex
import Testing

@testable import SynchronizationKitAsyncMutex

@Suite("AsyncMutex")
struct AsyncMutexTests {
    @Test("withLock returns the closure's result and can mutate the value")
    func withLockMutates() async throws {
        let mutex = AsyncMutex(0)

        let returned = try await mutex.withLock { value -> String in
            value = 42
            return "done"
        }

        #expect(returned == "done")
        #expect(try await mutex.withLock { $0 } == 42)
    }

    @Test("withLock propagates a thrown error and still unlocks")
    func withLockRethrows() async throws {
        struct Boom: Error {}
        let mutex = AsyncMutex(1)

        await #expect(throws: Boom.self) {
            try await mutex.withLock { _ in throw Boom() }
        }

        // If the failing call had leaked the lock, this would never return.
        #expect(try await mutex.withLock { $0 } == 1)
    }

    @Test("the closure may suspend while holding the lock")
    func withLockSuspends() async throws {
        let mutex = AsyncMutex([Int]())

        try await mutex.withLock { value in
            value.append(1)
            await Task.yield()
            value.append(2)
        }

        #expect(try await mutex.withLock { $0 } == [1, 2])
    }

    @Test("withLockIfAvailable succeeds on an uncontended lock")
    func withLockIfAvailableUncontended() async throws {
        let mutex = AsyncMutex(7)
        #expect(await mutex.withLockIfAvailable { $0 } == 7)
    }

    @Test("withLockIfAvailable returns nil while another task holds the lock")
    func withLockIfAvailableContended() async throws {
        let mutex = AsyncMutex(0)
        let acquired = Gate()
        let release = Gate()

        let holder = Task { @Sendable in
            try await mutex.withLock { _ in
                acquired.open()
                await release.wait()
            }
        }

        await acquired.wait()
        let result = await mutex.withLockIfAvailable { $0 }
        release.open()
        try await holder.value

        #expect(result == nil)
    }

    @Test("holds a noncopyable value")
    func noncopyableValue() async throws {
        struct Token: ~Copyable {
            var id: Int
        }

        let mutex = AsyncMutex(Token(id: 1))
        try await mutex.withLock { $0.id = 2 }
        #expect(try await mutex.withLock { $0.id } == 2)
    }

    @Test("runs the closure on the caller's actor")
    func closureRunsOnCallersActor() async throws {
        actor Recorder {
            let mutex = AsyncMutex(0)
            var seen: [Int] = []

            func record() async throws {
                try await mutex.withLock { value in
                    value += 1
                    // Synchronous access to actor state from inside the
                    // closure only compiles if the closure is isolated to
                    // this actor.
                    seen.append(value)
                }
            }
        }

        let recorder = Recorder()
        try await recorder.record()
        try await recorder.record()
        #expect(await recorder.seen == [1, 2])
    }

    @Test("excludes concurrent tasks even when they suspend inside the lock")
    func mutualExclusion() async throws {
        let mutex = AsyncMutex(0)
        let overlaps = Mutex(0)
        let inside = Mutex(0)
        let tasks = 64
        let iterations = 20

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<tasks {
                group.addTask { @Sendable in
                    for _ in 0..<iterations {
                        try await mutex.withLock { value in
                            if inside.withLock({ $0 += 1; return $0 }) != 1 {
                                overlaps.withLock { $0 += 1 }
                            }
                            let snapshot = value
                            await Task.yield()
                            value = snapshot + 1
                            inside.withLock { $0 -= 1 }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(try await mutex.withLock { $0 } == tasks * iterations)
        #expect(overlaps.withLock { $0 } == 0)
    }
}

// MARK: - Queueing

@Suite("AsyncMutex queueing")
struct AsyncMutexQueueingTests {
    @Test("hands the lock to waiters in arrival order")
    func arrivalOrder() async throws {
        let mutex = AsyncMutex(0)
        let order = Mutex([Int]())
        let release = Gate()

        let holder = Task { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        var waiters: [Task<Void, any Error>] = []
        for index in 1...5 {
            waiters.append(Task { @Sendable in
                try await mutex.withLock { _ in order.withLock { $0.append(index) } }
            })
            await mutex.waitForWaiters(index)
        }

        release.open()
        try await holder.value
        for waiter in waiters {
            try await waiter.value
        }

        #expect(order.withLock { $0 } == [1, 2, 3, 4, 5])
    }

    @Test("serves a higher-priority waiter before an earlier lower-priority one")
    func priorityOrder() async throws {
        let mutex = AsyncMutex(0)
        let order = Mutex([String]())
        let release = Gate()

        let holder = Task { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        let low = Task(priority: .low) { @Sendable in
            try await mutex.withLock { _ in order.withLock { $0.append("low") } }
        }
        await mutex.waitForWaiters(1)
        let high = Task(priority: .high) { @Sendable in
            try await mutex.withLock { _ in order.withLock { $0.append("high") } }
        }
        await mutex.waitForWaiters(2)

        release.open()
        try await holder.value
        try await low.value
        try await high.value

        #expect(order.withLock { $0 } == ["high", "low"])
    }

    @Test("a newcomer cannot overtake a queued waiter of the same priority")
    func handoffIsDirect() async throws {
        let mutex = AsyncMutex(0)
        let order = Mutex([String]())
        let release = Gate()

        let holder = Task { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        let waiter = Task { @Sendable in
            try await mutex.withLock { _ in order.withLock { $0.append("waiter") } }
        }
        await mutex.waitForWaiters(1)

        // Release, then immediately try to barge in from this task. The
        // handoff already gave the lock to the waiter, so this must queue
        // behind it rather than slip in first.
        release.open()
        try await holder.value
        try await mutex.withLock { _ in order.withLock { $0.append("newcomer") } }
        try await waiter.value

        #expect(order.withLock { $0 } == ["waiter", "newcomer"])
    }
}

// MARK: - Cancellation

@Suite("AsyncMutex cancellation")
struct AsyncMutexCancellationTests {
    @Test("a waiter cancelled while queued throws and leaves the queue")
    func cancelledWhileWaiting() async throws {
        let mutex = AsyncMutex(0)
        let release = Gate()

        let holder = Task { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        let waiter = Task { @Sendable in
            try await mutex.withLock { value in value = -1 }
        }
        await mutex.waitForWaiters(1)
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(mutex.handle._waiterCount == 0)

        // The holder is unaffected, and the lock still works afterwards.
        release.open()
        try await holder.value
        #expect(try await mutex.withLock { $0 } == 0)
    }

    @Test("an already-cancelled task does not wait for a held lock")
    func cancelledBeforeWaiting() async throws {
        let mutex = AsyncMutex(0)
        let release = Gate()

        let holder = Task { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        let cancelled = Task { @Sendable in
            // Cancelled below before it gets to run; `withLock` then sees a
            // held lock and a cancelled task, and must not join the queue.
            await Task.yield()
            try await mutex.withLock { value in value = -1 }
        }
        cancelled.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(mutex.handle._waiterCount == 0)

        release.open()
        try await holder.value
        #expect(try await mutex.withLock { $0 } == 0)
    }

    @Test("an already-cancelled task still takes a free lock")
    func cancelledTakesFreeLock() async throws {
        let mutex = AsyncMutex(0)

        let task = Task { @Sendable in
            await Task.yield()
            return try await mutex.withLock { value -> Bool in
                value = 1
                return Task.isCancelled
            }
        }
        task.cancel()

        #expect(try await task.value == true)
        #expect(try await mutex.withLock { $0 } == 1)
    }

    @Test("cancellation after the handoff is left to the closure")
    func cancelledAfterHandoff() async throws {
        let mutex = AsyncMutex(0)
        let release = Gate()
        let waiterEntered = Gate()

        let holder = Task { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        let waiter = Task { @Sendable in
            try await mutex.withLock { value -> Bool in
                waiterEntered.open()
                // Spin until the cancellation below lands, inside the lock.
                while !Task.isCancelled {
                    await Task.yield()
                }
                value = 1
                return true
            }
        }
        await mutex.waitForWaiters(1)

        release.open()
        try await holder.value
        await waiterEntered.wait()
        waiter.cancel()

        #expect(try await waiter.value == true)
        #expect(try await mutex.withLock { $0 } == 1)
    }

    @Test("cancelling one waiter does not disturb the others")
    func cancellingOneWaiter() async throws {
        let mutex = AsyncMutex(0)
        let order = Mutex([Int]())
        let release = Gate()

        let holder = Task { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        var waiters: [Task<Void, any Error>] = []
        for index in 1...3 {
            waiters.append(Task { @Sendable in
                try await mutex.withLock { _ in order.withLock { $0.append(index) } }
            })
            await mutex.waitForWaiters(index)
        }
        waiters[1].cancel()
        await #expect(throws: CancellationError.self) {
            try await waiters[1].value
        }

        release.open()
        try await holder.value
        try await waiters[0].value
        try await waiters[2].value

        #expect(order.withLock { $0 } == [1, 3])
    }
}

/// Suspends until some task holds `mutex`.
///
/// Probing takes the lock for an instant if it is free. That cannot steal it
/// from the task the test expects to hold it: if that task arrives while the
/// probe holds the lock, it queues, and the probe's release hands the lock
/// straight to it.
func eventuallyHeld(_ mutex: borrowing AsyncMutex<Int>) async {
    while await mutex.withLockIfAvailable({ _ in }) != nil {
        await Task.yield()
    }
}
