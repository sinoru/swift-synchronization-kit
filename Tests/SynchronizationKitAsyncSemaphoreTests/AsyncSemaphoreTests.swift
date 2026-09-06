//
//  AsyncSemaphoreTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncCore
import SynchronizationKitAsyncSemaphore
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

// Every suite here is skipped under ThreadSanitizer where the lock beneath
// the state is the standard library's Linux mutex, for the reason `MutexTests`
// records: its futex is not modelled, so two tasks taking turns under `state`
// read as a race in every test that has two of them. The sanitized coverage
// of these paths is the macOS row, where the same code runs over this
// package's own `os_unfair_lock`.
@Suite(
    "AsyncSemaphore",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncSemaphoreTests {
    @Test("wait takes a positive count without suspending")
    func waitTakesCount() async throws {
        let semaphore = AsyncSemaphore(value: 2)

        try await semaphore.wait()
        try await semaphore.wait()

        // Both counts are gone: a third wait has to queue.
        let third = Task { @Sendable in try await semaphore.wait() }
        await semaphore.waitForWaiters(1)
        #expect(semaphore._waiterCount == 1)

        semaphore.signal()
        try await third.value
    }

    @Test("wait suspends on a zero count until a signal")
    func waitSuspendsUntilSignal() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let passed = Mutex(false)

        let waiter = Task { @Sendable in
            try await semaphore.wait()
            passed.withLock { $0 = true }
        }
        await semaphore.waitForWaiters(1)
        #expect(passed.withLock { $0 } == false)

        #expect(semaphore.signal() == true)
        try await waiter.value
        #expect(passed.withLock { $0 } == true)
    }

    @Test("signal with nobody waiting raises the count for the next wait")
    func signalRaisesCount() async throws {
        let semaphore = AsyncSemaphore(value: 0)

        #expect(semaphore.signal() == false)
        #expect(semaphore.signal() == false)

        // Both signals were kept; neither wait suspends.
        try await semaphore.wait()
        try await semaphore.wait()
        #expect(semaphore._waiterCount == 0)
    }

    @Test("a task other than the one that waited may signal")
    func signalFromAnotherTask() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let ready = Gate()

        let consumer = Task { @Sendable in
            ready.open()
            try await semaphore.wait()
            return "produced"
        }

        await ready.wait()
        await semaphore.waitForWaiters(1)
        semaphore.signal()

        #expect(try await consumer.value == "produced")
    }

    @Test("bounds how many tasks run at once")
    func boundsConcurrency() async throws {
        let limit = 3
        let semaphore = AsyncSemaphore(value: limit)
        let running = Mutex(0)
        let peak = Mutex(0)
        let tasks = 32

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<tasks {
                group.addTask { @Sendable in
                    try await semaphore.wait()
                    defer { semaphore.signal() }

                    let now = running.withLock { $0 += 1; return $0 }
                    peak.withLock { $0 = max($0, now) }
                    await Task.yield()
                    running.withLock { $0 -= 1 }
                }
            }
            try await group.waitForAll()
        }

        // The bound is what is promised; reaching it is up to the scheduler.
        #expect(peak.withLock { $0 } <= limit)
        #expect(running.withLock { $0 } == 0)

        // Every count came back.
        for _ in 0..<limit {
            try await semaphore.wait()
        }
        #expect(semaphore._waiterCount == 0)
    }
    /// The wait holds the semaphore, through the cancellation handler it
    /// installs, so a waiter can never be left suspended on a semaphore that
    /// no longer exists. The `unowned` capture keeps the waiter's own closure
    /// from being what holds it.
    @Test("a waiting task keeps the semaphore alive")
    func waiterKeepsSemaphoreAlive() async throws {
        weak var weakSemaphore: AsyncSemaphore?
        let waiter: Task<Void, any Error>
        do {
            let semaphore = AsyncSemaphore(value: 0)
            weakSemaphore = semaphore
            waiter = Task { @Sendable [unowned semaphore] in
                try await semaphore.wait()
            }
            await semaphore.waitForWaiters(1)
        }

        #expect(weakSemaphore != nil, "the wait let go of the semaphore")

        weakSemaphore?.signal()
        try await waiter.value
        #expect(
            await eventually { weakSemaphore == nil },
            "the semaphore outlived its last waiter"
        )
    }

}

// MARK: - Queueing

@Suite(
    "AsyncSemaphore queueing",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncSemaphoreQueueingTests {
    @Test("resumes waiters in arrival order")
    func arrivalOrder() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let order = Mutex([Int]())

        var waiters: [Task<Void, any Error>] = []
        for index in 1...5 {
            waiters.append(Task { @Sendable in
                try await semaphore.wait()
                order.withLock { $0.append(index) }
            })
            await semaphore.waitForWaiters(index)
        }

        // One signal at a time: signalling all five at once would resume all
        // five, and which of them then runs first is the scheduler's call.
        for waiter in waiters {
            semaphore.signal()
            try await waiter.value
        }

        #expect(order.withLock { $0 } == [1, 2, 3, 4, 5])
    }

    @Test("resumes a higher-priority waiter before an earlier lower-priority one")
    func priorityOrder() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let order = Mutex([String]())

        let low = Task(priority: .low) { @Sendable in
            try await semaphore.wait()
            order.withLock { $0.append("low") }
        }
        await semaphore.waitForWaiters(1)
        let high = Task(priority: .high) { @Sendable in
            try await semaphore.wait()
            order.withLock { $0.append("high") }
        }
        await semaphore.waitForWaiters(2)

        // One signal, one waiter: the high-priority one, leaving the earlier
        // low-priority one still queued.
        semaphore.signal()
        try await high.value
        #expect(order.withLock { $0 } == ["high"])
        #expect(semaphore._waiterCount == 1)

        semaphore.signal()
        try await low.value
        #expect(order.withLock { $0 } == ["high", "low"])
    }

    @Test("a signal hands the count to the waiter rather than to a newcomer")
    func handoffIsDirect() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let order = Mutex([String]())

        let waiter = Task { @Sendable in
            try await semaphore.wait()
            order.withLock { $0.append("waiter") }
        }
        await semaphore.waitForWaiters(1)

        // The signal is the waiter's; a wait right after it must queue rather
        // than take the count the waiter has not yet resumed to collect.
        semaphore.signal()
        let newcomer = Task { @Sendable in
            try await semaphore.wait()
            order.withLock { $0.append("newcomer") }
        }
        await semaphore.waitForWaiters(1)
        try await waiter.value

        semaphore.signal()
        try await newcomer.value

        #expect(order.withLock { $0 } == ["waiter", "newcomer"])
    }

    // Only a 6.4 build installs the handler this relies on; `_acquire` says
    // why.
    #if compiler(>=6.4)
    @Test("a waiter escalated while queued moves up the queue")
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    func escalatedWaiterMovesUp() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let order = Mutex([String]())

        let first = Task(priority: .low) { @Sendable in
            try await semaphore.wait()
            order.withLock { $0.append("first") }
        }
        await semaphore.waitForWaiters(1)
        let second = Task(priority: .low) { @Sendable in
            try await semaphore.wait()
            order.withLock { $0.append("second") }
        }
        await semaphore.waitForWaiters(2)

        // The runtime runs escalation handlers before this returns, so the
        // queue has been told by the time the signals go out.
        second.escalatePriority(to: .high)

        semaphore.signal()
        try await second.value
        #expect(order.withLock { $0 } == ["second"])
        #expect(semaphore._waiterCount == 1)

        semaphore.signal()
        try await first.value
        #expect(order.withLock { $0 } == ["second", "first"])
    }
    #endif
}

// MARK: - Cancellation

@Suite(
    "AsyncSemaphore cancellation",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncSemaphoreCancellationTests {
    @Test("a waiter cancelled while queued throws, leaves the queue, and takes no count")
    func cancelledWhileWaiting() async throws {
        let semaphore = AsyncSemaphore(value: 0)

        let waiter = Task { @Sendable in
            try await semaphore.wait()
        }
        await semaphore.waitForWaiters(1)
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(semaphore._waiterCount == 0)

        // Nobody is left to hand the count to, so it goes up instead.
        #expect(semaphore.signal() == false)
        try await semaphore.wait()
    }

    @Test("an already-cancelled task does not wait on a zero count")
    func cancelledBeforeWaiting() async throws {
        let semaphore = AsyncSemaphore(value: 0)

        let cancelled = Task { @Sendable in
            // Wait for the cancellation below to land first: `wait` must then
            // see a zero count and a cancelled task, and not join the queue.
            while !Task.isCancelled {
                await Task.yield()
            }
            try await semaphore.wait()
        }
        cancelled.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(semaphore._waiterCount == 0)
        #expect(semaphore.signal() == false)
    }

    @Test("an already-cancelled task still takes a positive count")
    func cancelledTakesCount() async throws {
        let semaphore = AsyncSemaphore(value: 1)

        let task = Task { @Sendable in
            while !Task.isCancelled {
                await Task.yield()
            }
            try await semaphore.wait()
            return Task.isCancelled
        }
        task.cancel()

        #expect(try await task.value == true)

        // The count was consumed: the next wait has to queue.
        let next = Task { @Sendable in try await semaphore.wait() }
        await semaphore.waitForWaiters(1)
        semaphore.signal()
        try await next.value
    }

    @Test("cancelling one waiter does not disturb the others")
    func cancellingOneWaiter() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let order = Mutex([Int]())

        var waiters: [Task<Void, any Error>] = []
        for index in 1...3 {
            waiters.append(Task { @Sendable in
                try await semaphore.wait()
                order.withLock { $0.append(index) }
            })
            await semaphore.waitForWaiters(index)
        }
        waiters[1].cancel()
        await #expect(throws: CancellationError.self) {
            try await waiters[1].value
        }

        // One signal at a time, as in `arrivalOrder`.
        semaphore.signal()
        try await waiters[0].value
        semaphore.signal()
        try await waiters[2].value

        #expect(order.withLock { $0 } == [1, 3])
        #expect(semaphore._waiterCount == 0)
    }
}
