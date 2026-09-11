//
//  BlockingLockTests.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import SynchronizationKitAsyncCore
import SynchronizationKitAsyncMutex
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

/// The synchronous `withLock`: a thread in the queue beside the tasks, and a
/// thread holding the value the tasks wait for.
///
/// What is checked is that the two kinds of caller share one lock and one
/// queue — that a thread waits out a task holding across an `await` and a
/// task waits out a thread, and that a thread is served in its turn among
/// the tasks rather than ahead of or behind them as a class — and that the
/// escalation machinery has nothing to say to a holder without a task. The
/// thread is always one of the test's own making, never one of the
/// cooperative pool: the blocking lock is unavailable from asynchronous
/// contexts, and the test runs inside one.
///
/// Skipped under ThreadSanitizer on Linux for the reason `AsyncMutexTests`
/// gives.
@Suite(
    "AsyncMutex blocking lock",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncMutexBlockingLockTests {
    /// The lock, held by reference so that a thread's closure can reach it.
    final class Shared: Sendable {
        let mutex = AsyncMutex(0)
    }

    /// Whether a thread has returned from its lock. Polled rather than
    /// signalled: the tests run in tasks, and a bounded `DispatchSemaphore`
    /// wait is unavailable there for the reason the lock under test is.
    final class Returned: Sendable {
        private let flag = Mutex(false)

        var value: Bool {
            flag.withLock { $0 }
        }

        fileprivate func set() {
            flag.withLock { $0 = true }
        }
    }

    /// A thread that takes `shared.mutex` with the blocking `withLock`, runs
    /// `body` inside, and reports when it has returned.
    ///
    /// Started at `qualityOfService`, which is the priority the thread
    /// waits at on Darwin; elsewhere the runtime reports no priority for a
    /// thread that is not the main one, and the QoS is a hint to the
    /// scheduler and nothing more.
    private static func blockingLocker(
        on shared: Shared,
        qualityOfService: QualityOfService = .default,
        _ body: @escaping @Sendable (inout Int) -> Void
    ) -> Returned {
        let returned = Returned()
        let thread = Thread {
            shared.mutex.withLock { value in body(&value) }
            returned.set()
        }
        thread.qualityOfService = qualityOfService
        thread.start()
        return returned
    }

    /// The blocking lock from a synchronous function: what a task reaches
    /// when it calls one, `noasync` guarding asynchronous contexts and not
    /// what they call.
    private static func lockSynchronously(_ shared: Shared) -> Int {
        shared.mutex.withLock { value in
            value *= 10
            return value
        }
    }

    /// Whether a thread stays in its wait: a fifth of a second of polls
    /// without it returning.
    private static func staysBlocked(_ returned: Returned) async -> Bool {
        !(await eventually(attempts: 200) { returned.value })
    }

    @Test("withLock from a thread takes a free lock without blocking")
    func threadTakesFreeLock() async throws {
        let shared = Shared()

        let returned = Self.blockingLocker(on: shared) { $0 += 1 }
        #expect(await eventually { returned.value }, "the lock was free and the thread blocked")
        #expect(try await shared.mutex.withLock { $0 } == 1)
        #expect(shared.mutex.handle._waiterCount == 0)
    }

    @Test("withLockIfAvailable from a thread reports a held lock without blocking")
    func threadTriesHeldLock() async throws {
        let shared = Shared()
        let acquired = Gate()
        let release = Gate()

        let holder = Task { @Sendable in
            try await shared.mutex.withLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let tried = Mutex<Bool?>(nil)
        Thread.detachNewThread {
            let ran = shared.mutex.withLockIfAvailable { $0 += 1 } != nil
            tried.withLock { $0 = ran }
        }
        #expect(await eventually { tried.withLock { $0 } != nil }, "the try never returned")
        #expect(tried.withLock { $0 } == false, "the try took a lock a task was holding")

        release.open()
        try await holder.value
        #expect(try await shared.mutex.withLock { $0 } == 0)
    }

    @Test("a thread waits out a task holding across an await")
    func threadWaitsForTask() async throws {
        let shared = Shared()
        let acquired = Gate()
        let release = Gate()

        let holder = Task { @Sendable in
            try await shared.mutex.withLock { value in
                acquired.open()
                await release.wait()
                value = 1
            }
        }
        await acquired.wait()

        let thread = Self.blockingLocker(on: shared) { $0 *= 10 }
        #expect(await eventually { shared.mutex.handle._waiterCount == 1 })
        #expect(await Self.staysBlocked(thread), "the thread took a lock a task was holding")

        release.open()
        try await holder.value
        #expect(await eventually { thread.value }, "the release never reached the thread")
        // The task wrote first and the thread multiplied what it wrote.
        #expect(try await shared.mutex.withLock { $0 } == 10)
        #expect(shared.mutex.handle._waiterCount == 0)
    }

    @Test("a task waits out a thread holding the lock")
    func taskWaitsForThread() async throws {
        let shared = Shared()
        let entered = Returned()
        let release = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            shared.mutex.withLock { value in
                entered.set()
                release.wait()
                value = 1
            }
        }
        #expect(await eventually { entered.value })

        let waiter = Task { @Sendable in
            try await shared.mutex.withLock { $0 *= 10 }
        }
        await shared.mutex.waitForWaiters(1)

        release.signal()
        try await expectCompletion(within: 30, "the thread's release never reached the task") {
            try await waiter.value
        }
        #expect(try await shared.mutex.withLock { $0 } == 10)
        #expect(shared.mutex.handle._waiterCount == 0)
    }

    /// A synchronous caller inside a task that had to wait holds the lock as
    /// the task once served, as one that found it free does; here that it
    /// is served at all and releases cleanly. The wait is on a thread of the
    /// test's own and short, so the pool thread it blocks is soon given back.
    @Test("a synchronous caller inside a task that waited takes and releases the lock")
    func synchronousCallerInTaskWaits() async throws {
        let shared = Shared()
        let entered = Returned()

        // The holder lets go on its own once the caller has queued, so that
        // nothing here needs a thread of the cooperative pool while the
        // caller is blocking one: on a pool one worker wide, a release that
        // waited on this task would never be sent.
        Thread.detachNewThread {
            shared.mutex.withLock { value in
                entered.set()
                _ = spin(untilTrue: { shared.mutex.handle._waiterCount == 1 })
                value = 1
            }
        }
        #expect(await eventually { entered.value })

        let caller = Task { @Sendable in
            Self.lockSynchronously(shared)
        }
        try await expectCompletion(within: 30, "the thread's release never reached the caller") {
            _ = await caller.value
        }
        #expect(await caller.value == 10)
        #expect(try await shared.mutex.withLock { $0 } == 10)
        #expect(shared.mutex.handle._waiterCount == 0)
    }

    @Test("a higher-priority task is served ahead of a queued thread")
    func priorityOrdersThreadAmongTasks() async throws {
        let shared = Shared()
        let acquired = Gate()
        let release = Gate()
        let order = Mutex<[String]>([])

        let holder = Task { @Sendable in
            try await shared.mutex.withLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        // The thread first, below the task that follows it; `.utility`
        // rather than `.background` for the reason the semaphore's suite
        // gives.
        let thread = Self.blockingLocker(on: shared, qualityOfService: .utility) { _ in
            order.withLock { $0.append("thread") }
        }
        #expect(await eventually { shared.mutex.handle._waiterCount == 1 })
        let task = Task(priority: .high) { @Sendable in
            try await shared.mutex.withLock { _ in
                order.withLock { $0.append("task") }
            }
        }
        await shared.mutex.waitForWaiters(2)

        release.open()
        try await holder.value
        try await expectCompletion(within: 30) { try await task.value }
        #expect(await eventually { thread.value })
        #expect(
            order.withLock { $0 } == ["task", "thread"],
            "the thread was served ahead of the task"
        )
    }

    #if canImport(Darwin)
    // Only Darwin gives a thread a priority of its own to be equal at:
    // `Task.currentPriority` reads the thread's QoS there, and reports
    // nothing for a thread elsewhere, which sorts below any task.
    @Test("a thread and a task of equal priority are served in arrival order")
    func arrivalOrdersEquals() async throws {
        let shared = Shared()
        let acquired = Gate()
        let release = Gate()
        let order = Mutex<[String]>([])

        let holder = Task { @Sendable in
            try await shared.mutex.withLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        // `.utility` QoS is `.utility` task priority; the thread arrives
        // first.
        let thread = Self.blockingLocker(on: shared, qualityOfService: .utility) { _ in
            order.withLock { $0.append("thread") }
        }
        #expect(await eventually { shared.mutex.handle._waiterCount == 1 })
        let task = Task(priority: .utility) { @Sendable in
            try await shared.mutex.withLock { _ in
                order.withLock { $0.append("task") }
            }
        }
        await shared.mutex.waitForWaiters(2)

        release.open()
        try await holder.value
        try await expectCompletion(within: 30) { try await task.value }
        #expect(await eventually { thread.value })
        #expect(
            order.withLock { $0 } == ["thread", "task"],
            "the task was served ahead of the thread"
        )
    }
    #endif

    /// A holder without a task is one the escalation path has to pass over:
    /// a waiter that outranks it finds nothing to raise, and is served when
    /// the thread lets go.
    @Test("a higher-priority task waiting on a thread holder has nothing to raise")
    func nothingToEscalate() async throws {
        let shared = Shared()
        let entered = Returned()
        let release = DispatchSemaphore(value: 0)

        let thread = Thread {
            shared.mutex.withLock { value in
                entered.set()
                release.wait()
                value = 1
            }
        }
        thread.qualityOfService = .utility
        thread.start()
        #expect(await eventually { entered.value })

        let waiter = Task(priority: .high) { @Sendable in
            try await shared.mutex.withLock { $0 *= 10 }
        }
        await shared.mutex.waitForWaiters(1)

        release.signal()
        try await expectCompletion(within: 30, "the thread's release never reached the task") {
            try await waiter.value
        }
        #expect(try await shared.mutex.withLock { $0 } == 10)
    }

    /// Threads and tasks incrementing one value in turn. Every increment
    /// lands, and by the end nothing is queued.
    @Test("threads and tasks take turns on one value", arguments: stressWorkerCounts)
    func mixedHolders(perKind: Int) async throws {
        let share = 20 * stressScale
        let shared = Shared()
        let threadsDone = Mutex(0)

        for _ in 0 ..< perKind {
            Thread.detachNewThread {
                for _ in 0 ..< share {
                    shared.mutex.withLock { $0 += 1 }
                }
                threadsDone.withLock { $0 += 1 }
            }
        }
        let tasks = (0 ..< perKind).map { _ in
            Task { @Sendable in
                for _ in 0 ..< share {
                    try await shared.mutex.withLock { value in
                        value += 1
                        if Bool.random() {
                            await Task.yield()
                        }
                    }
                }
            }
        }

        try await expectCompletion(of: tasks, within: 300)
        #expect(
            await eventually(attempts: 300_000) { threadsDone.withLock { $0 } == perKind },
            "a thread never got its share"
        )

        #expect(try await shared.mutex.withLock { $0 } == 2 * perKind * share)
        #expect(shared.mutex.handle._waiterCount == 0)
    }
}
