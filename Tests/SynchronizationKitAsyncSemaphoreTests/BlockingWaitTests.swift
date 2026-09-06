//
//  BlockingWaitTests.swift
//  SynchronizationKit
//

import Foundation
import SynchronizationKitAsyncCore
import SynchronizationKitAsyncSemaphore
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

/// The synchronous `wait()`: a thread in the queue beside the tasks.
///
/// What is checked is that the two kinds of waiter share one count and one
/// queue — that a signal from either side reaches a waiter of either kind,
/// and that a thread is served in its turn among the tasks rather than
/// ahead of or behind them as a class. The thread is always a thread of the
/// test's own making, never one of the cooperative pool: the blocking wait
/// is unavailable from asynchronous contexts, and the test runs inside one.
///
/// Skipped under ThreadSanitizer on Linux for the reason `AsyncSemaphoreTests`
/// gives.
@Suite(
    "AsyncSemaphore blocking wait",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncSemaphoreBlockingWaitTests {
    /// Whether a thread has returned from its wait. Polled rather than
    /// signalled: the tests run in tasks, and a bounded `DispatchSemaphore`
    /// wait is unavailable there for the reason the wait under test is.
    final class Returned: Sendable {
        private let flag = Mutex(false)

        var value: Bool {
            flag.withLock { $0 }
        }

        fileprivate func set() {
            flag.withLock { $0 = true }
        }
    }

    /// A thread blocked in `wait()` on `semaphore`, and whether it has
    /// returned.
    ///
    /// Started at `qualityOfService`, which is the priority the thread
    /// waits at on Darwin; elsewhere the runtime reports no priority for a
    /// thread that is not the main one, and the QoS is a hint to the
    /// scheduler and nothing more.
    private static func blockingWaiter(
        on semaphore: AsyncSemaphore,
        qualityOfService: QualityOfService = .default
    ) -> Returned {
        let returned = Returned()
        let thread = Thread {
            semaphore.wait()
            returned.set()
        }
        thread.qualityOfService = qualityOfService
        thread.start()
        return returned
    }

    /// Whether a thread stays in its wait: a fifth of a second of polls
    /// without it returning.
    private static func staysBlocked(_ returned: Returned) async -> Bool {
        !(await eventually(attempts: 200) { returned.value })
    }

    @Test("wait takes a positive count without blocking")
    func waitTakesCount() async throws {
        let semaphore = AsyncSemaphore(value: 2)

        for attempt in 1 ... 2 {
            let returned = Self.blockingWaiter(on: semaphore)
            #expect(
                await eventually { returned.value },
                "wait \(attempt) of 2 blocked with a count outstanding"
            )
        }

        // Both counts are gone: a third wait has to queue, and it is a
        // thread in the queue that the count of waiters reports.
        let third = Self.blockingWaiter(on: semaphore)
        #expect(await eventually { semaphore._waiterCount == 1 })
        #expect(await Self.staysBlocked(third), "a wait returned that no signal had earned")

        #expect(semaphore.signal(), "the signal found nobody waiting")
        #expect(await eventually { third.value }, "the signal never woke the thread")
        #expect(semaphore._waiterCount == 0)
    }

    @Test("a task's signal wakes a waiting thread")
    func taskSignalsThread() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let returned = Self.blockingWaiter(on: semaphore)
        #expect(await eventually { semaphore._waiterCount == 1 })

        let signaller = Task { @Sendable in semaphore.signal() }
        #expect(await signaller.value, "the signal found nobody waiting")
        #expect(await eventually { returned.value }, "the signal never woke the thread")
    }

    @Test("a thread's signal wakes a waiting task")
    func threadSignalsTask() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let waiter = Task { @Sendable in try await semaphore.wait() }
        await semaphore.waitForWaiters(1)

        let woke = Mutex<Bool?>(nil)
        Thread.detachNewThread {
            let didWake = semaphore.signal()
            woke.withLock { $0 = didWake }
        }
        #expect(await eventually { woke.withLock { $0 } != nil })
        #expect(woke.withLock { $0 } == true, "the signal found nobody waiting")

        try await expectCompletion(within: 30, "the signal never woke the task") {
            try await waiter.value
        }
    }

    @Test("a higher-priority task is served ahead of a queued thread")
    func priorityOrdersThreadAmongTasks() async throws {
        let semaphore = AsyncSemaphore(value: 0)

        // The thread first, below the task that follows it. Whatever priority
        // the runtime reports for the thread — its QoS on Darwin, none
        // elsewhere — the task outranks it.
        //
        // `.utility` rather than `.background`, though the bottom of the scale
        // would make the point more plainly. Darwin throttles background QoS,
        // and the stress suite runs in this process at the same time; on a
        // loaded runner a background thread has gone unscheduled for as long
        // as that suite ran, past the polls below, while a utility one was
        // served in the middle of it.
        let thread = Self.blockingWaiter(on: semaphore, qualityOfService: .utility)
        #expect(await eventually { semaphore._waiterCount == 1 })
        let task = Task(priority: .high) { @Sendable in try await semaphore.wait() }
        await semaphore.waitForWaiters(2)

        semaphore.signal()
        try await expectCompletion(within: 30, "the task was not served first") {
            try await task.value
        }
        #expect(await Self.staysBlocked(thread), "the thread was served with the task")
        #expect(semaphore._waiterCount == 1)

        semaphore.signal()
        #expect(await eventually { thread.value }, "the second signal never woke the thread")
        #expect(semaphore._waiterCount == 0)
    }

    #if canImport(Darwin)
    // Only Darwin gives a thread a priority of its own to be equal at:
    // `Task.currentPriority` reads the thread's QoS there, and reports
    // nothing for a thread elsewhere, which sorts below any task.
    @Test("a thread and a task of equal priority are served in arrival order")
    func arrivalOrdersEquals() async throws {
        let semaphore = AsyncSemaphore(value: 0)

        // `.utility` QoS is `.utility` task priority; the thread arrives
        // first.
        let thread = Self.blockingWaiter(on: semaphore, qualityOfService: .utility)
        #expect(await eventually { semaphore._waiterCount == 1 })
        let task = Task(priority: .utility) { @Sendable in try await semaphore.wait() }
        await semaphore.waitForWaiters(2)

        semaphore.signal()
        #expect(await eventually { thread.value }, "the thread was not served first")
        #expect(semaphore._waiterCount == 1, "the task was served with the thread")

        semaphore.signal()
        try await expectCompletion(within: 30, "the second signal never woke the task") {
            try await task.value
        }
        #expect(semaphore._waiterCount == 0)
    }
    #endif

    /// Consumers of both kinds drawing on producers of both kinds. Every
    /// count signalled is taken exactly once, and by the end nothing is
    /// queued and nothing is left.
    @Test("threads and tasks share one count", arguments: stressWorkerCounts)
    func mixedConsumers(perKind: Int) async throws {
        let share = 20 * stressScale
        let semaphore = AsyncSemaphore(value: 0)
        let takenByThreads = Mutex(0)
        let takenByTasks = Mutex(0)
        let threadsDone = Mutex(0)

        for _ in 0 ..< perKind {
            Thread.detachNewThread {
                for _ in 0 ..< share {
                    semaphore.wait()
                    takenByThreads.withLock { $0 += 1 }
                }
                threadsDone.withLock { $0 += 1 }
            }
        }
        let tasks = (0 ..< perKind).map { _ in
            Task { @Sendable in
                for _ in 0 ..< share {
                    try await semaphore.wait()
                    takenByTasks.withLock { $0 += 1 }
                }
            }
        }

        // Half the signals from a thread, half from a task, interleaved
        // with the consumers' arrival rather than after it.
        let total = 2 * perKind * share
        Thread.detachNewThread {
            for _ in 0 ..< total / 2 {
                semaphore.signal()
            }
        }
        let producer = Task { @Sendable in
            for _ in 0 ..< total - total / 2 {
                semaphore.signal()
                if Bool.random() {
                    await Task.yield()
                }
            }
        }

        try await expectCompletion(of: tasks, within: 300)
        await producer.value
        #expect(
            await eventually(attempts: 300_000) { threadsDone.withLock { $0 } == perKind },
            "a thread never got its share"
        )

        #expect(takenByThreads.withLock { $0 } == perKind * share)
        #expect(takenByTasks.withLock { $0 } == perKind * share)
        #expect(semaphore._waiterCount == 0)

        // Nothing left over: the next wait has to queue.
        let extra = Task { @Sendable in try await semaphore.wait() }
        #expect(await eventually { semaphore._waiterCount == 1 }, "a count was left over")
        semaphore.signal()
        try await expectCompletion(within: 30) { try await extra.value }
    }
}
