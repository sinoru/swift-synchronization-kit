//
//  BlockingLockTests.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import SynchronizationKitAsyncCore
import SynchronizationKitAsyncRWLock
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

/// The synchronous locking methods: a thread in the queue beside the tasks,
/// and a thread holding the value the tasks wait for.
///
/// What is checked is what `AsyncMutex`'s blocking suite checks, restated
/// for readers and a writer: a thread reads alongside a task, a thread
/// writer waits out a task reader and stops the readers behind it, and a
/// task writer waits out a thread reader. The thread is always one of the
/// test's own making, never one of the cooperative pool: the blocking locks
/// are unavailable from asynchronous contexts, and the test runs inside one.
///
/// Skipped under ThreadSanitizer on Linux for the reason `AsyncRWLockTests`
/// gives.
@Suite(
    "AsyncRWLock blocking lock",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncRWLockBlockingLockTests {
    /// The lock, held by reference so that a thread's closure can reach it.
    final class Shared: Sendable {
        let lock = AsyncRWLock(0)
    }

    /// Whether a thread has returned from its lock; polled, for the reason
    /// `AsyncMutexBlockingLockTests.Returned` gives.
    final class Returned: Sendable {
        private let flag = Mutex(false)

        var value: Bool {
            flag.withLock { $0 }
        }

        fileprivate func set() {
            flag.withLock { $0 = true }
        }
    }

    /// A thread that takes `shared.lock` for writing with the blocking
    /// `withWriteLock`, runs `body` inside, and reports when it has returned.
    private static func blockingWriter(
        on shared: Shared,
        qualityOfService: QualityOfService = .default,
        _ body: @escaping @Sendable (inout Int) -> Void
    ) -> Returned {
        let returned = Returned()
        let thread = Thread {
            shared.lock.withWriteLock { value in body(&value) }
            returned.set()
        }
        thread.qualityOfService = qualityOfService
        thread.start()
        return returned
    }

    /// A thread that takes `shared.lock` for reading with the blocking
    /// `withReadLock`, runs `body` inside, and reports when it has returned.
    private static func blockingReader(
        on shared: Shared,
        _ body: @escaping @Sendable (Int) -> Void
    ) -> Returned {
        let returned = Returned()
        Thread.detachNewThread {
            shared.lock.withReadLock { value in body(value) }
            returned.set()
        }
        return returned
    }

    /// The blocking read from a synchronous function: what a task reaches
    /// when it calls one, `noasync` guarding asynchronous contexts and not
    /// what they call.
    private static func readSynchronously(_ shared: Shared) -> Int {
        shared.lock.withReadLock { $0 }
    }

    /// Whether a thread stays in its wait: a fifth of a second of polls
    /// without it returning.
    private static func staysBlocked(_ returned: Returned) async -> Bool {
        !(await eventually(attempts: 200) { returned.value })
    }

    @Test("a thread reads alongside a task holding the lock for reading")
    func threadReadsBesideTask() async throws {
        let shared = Shared()
        let acquired = Gate()
        let release = Gate()

        let reader = Task { @Sendable in
            try await shared.lock.withReadLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let seen = Mutex<Int?>(nil)
        let thread = Self.blockingReader(on: shared) { value in
            seen.withLock { $0 = value }
        }
        #expect(await eventually { thread.value }, "a reader blocked on another reader")
        #expect(seen.withLock { $0 } == 0)
        #expect(shared.lock.handle._waiterCount == 0)

        release.open()
        try await reader.value
    }

    @Test("a thread writer waits out a task reader and stops the readers behind it")
    func threadWriterWaitsForTaskReader() async throws {
        let shared = Shared()
        let acquired = Gate()
        let release = Gate()

        let reader = Task { @Sendable in
            try await shared.lock.withReadLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let writer = Self.blockingWriter(on: shared) { $0 = 1 }
        #expect(await eventually { shared.lock.handle._waiterCount == 1 })
        #expect(await Self.staysBlocked(writer), "a writer took a lock a reader was holding")

        // A reader arriving behind the queued writer waits its turn, whether
        // it is a task or a thread, and sees the write once it is let in.
        let taskReader = Task { @Sendable in
            try await shared.lock.withReadLock { $0 }
        }
        await shared.lock.waitForWaiters(2)
        let seenByThread = Mutex<Int?>(nil)
        let threadReader = Self.blockingReader(on: shared) { value in
            seenByThread.withLock { $0 = value }
        }
        #expect(await eventually { shared.lock.handle._waiterCount == 3 })
        #expect(await Self.staysBlocked(threadReader), "a reader passed a waiting writer")

        // Where the thread has a priority of its own — its QoS, on Darwin —
        // it equals the task's and arrival order holds: the writer first,
        // then the task reader, which sees the write. Elsewhere the runtime
        // reports no priority for a thread, so the task outranks the queued
        // writer, is placed ahead of it, and is served first: the order the
        // queue promises, and the value before the write is what it sees.
        #if canImport(Darwin)
        let seenByTask = 1
        #else
        let seenByTask = 0
        #endif

        release.open()
        try await reader.value
        #expect(await eventually { writer.value }, "the release never reached the writer")
        #expect(try await taskReader.value == seenByTask, "the task reader was served out of order")
        #expect(await eventually { threadReader.value })
        #expect(seenByThread.withLock { $0 } == 1, "the thread reader was served before the write")
        #expect(shared.lock.handle._waiterCount == 0)
    }

    @Test("a task writer waits out a thread reader")
    func taskWriterWaitsForThreadReader() async throws {
        let shared = Shared()
        let entered = Returned()
        let release = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            shared.lock.withReadLock { _ in
                entered.set()
                release.wait()
            }
        }
        #expect(await eventually { entered.value })

        let writer = Task { @Sendable in
            try await shared.lock.withWriteLock { $0 = 1 }
        }
        await shared.lock.waitForWaiters(1)

        release.signal()
        try await expectCompletion(within: 30, "the thread's release never reached the writer") {
            try await writer.value
        }
        #expect(try await shared.lock.withReadLock { $0 } == 1)
        #expect(shared.lock.handle._waiterCount == 0)
    }

    /// A synchronous caller inside a task that had to wait is recorded as
    /// the task once served, as one that found the lock free is, so that the
    /// release finds the hold it made. The wait is on a thread of the test's
    /// own and short, so the pool thread it blocks is soon given back.
    @Test("a synchronous caller inside a task that waited releases its read hold")
    func synchronousCallerInTaskWaits() async throws {
        let shared = Shared()
        let entered = Returned()

        // The holder lets go on its own once the caller has queued, so that
        // nothing here needs a thread of the cooperative pool while the
        // caller is blocking one: on a pool one worker wide, a release that
        // waited on this task would never be sent.
        Thread.detachNewThread {
            shared.lock.withWriteLock { value in
                entered.set()
                _ = spin(untilTrue: { shared.lock.handle._waiterCount == 1 })
                value = 1
            }
        }
        #expect(await eventually { entered.value })

        let reader = Task { @Sendable in
            Self.readSynchronously(shared)
        }
        try await expectCompletion(within: 30, "the thread's release never reached the caller") {
            _ = await reader.value
        }
        #expect(await reader.value == 1)
        #expect(shared.lock.handle._waiterCount == 0)
    }

    @Test("the IfAvailable forms report a held lock from a thread without blocking")
    func threadTriesHeldLock() async throws {
        let shared = Shared()
        let acquired = Gate()
        let release = Gate()

        let writer = Task { @Sendable in
            try await shared.lock.withWriteLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let tried = Mutex<(read: Bool, write: Bool)?>(nil)
        Thread.detachNewThread {
            let read = shared.lock.withReadLockIfAvailable { _ in } != nil
            let write = shared.lock.withWriteLockIfAvailable { _ in } != nil
            tried.withLock { $0 = (read, write) }
        }
        #expect(await eventually { tried.withLock { $0 } != nil }, "a try never returned")
        #expect(tried.withLock { $0 }?.read == false, "a read try passed a writer")
        #expect(tried.withLock { $0 }?.write == false, "a write try passed a writer")

        release.open()
        try await writer.value
    }

    /// Threads and tasks reading and writing one value. Every write lands,
    /// every read sees a value some write left, and by the end nothing is
    /// queued.
    @Test("threads and tasks share one lock", arguments: stressWorkerCounts)
    func mixedHolders(perKind: Int) async throws {
        let share = 20 * stressScale
        let shared = Shared()
        let threadsDone = Mutex(0)
        let torn = Mutex(false)

        for _ in 0 ..< perKind {
            Thread.detachNewThread {
                for turn in 0 ..< share {
                    if turn % 4 == 0 {
                        shared.lock.withWriteLock { $0 += 1 }
                    } else {
                        let value = shared.lock.withReadLock { $0 }
                        if value < 0 {
                            torn.withLock { $0 = true }
                        }
                    }
                }
                threadsDone.withLock { $0 += 1 }
            }
        }
        let tasks = (0 ..< perKind).map { _ in
            Task { @Sendable in
                for turn in 0 ..< share {
                    if turn % 4 == 0 {
                        try await shared.lock.withWriteLock { value in
                            value += 1
                            if Bool.random() {
                                await Task.yield()
                            }
                        }
                    } else {
                        try await shared.lock.withReadLock { value in
                            if value < 0 {
                                torn.withLock { $0 = true }
                            }
                            if Bool.random() {
                                await Task.yield()
                            }
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

        let writesPerWorker = (share + 3) / 4
        #expect(try await shared.lock.withReadLock { $0 } == 2 * perKind * writesPerWorker)
        #expect(!torn.withLock { $0 })
        #expect(shared.lock.handle._waiterCount == 0)
    }
}
