//
//  AsyncRWLockTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncCore
import SynchronizationKitAsyncRWLock
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
    "AsyncRWLock",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncRWLockTests {
    @Test("withReadLock returns the closure's result")
    func withReadLockReturns() async throws {
        let lock = AsyncRWLock(42)
        #expect(try await lock.withReadLock { $0 * 2 } == 84)
    }

    @Test("withWriteLock returns the closure's result and can mutate the value")
    func withWriteLockMutates() async throws {
        let lock = AsyncRWLock(0)

        let returned = try await lock.withWriteLock { value -> String in
            value = 42
            return "done"
        }

        #expect(returned == "done")
        #expect(try await lock.withReadLock { $0 } == 42)
    }

    @Test("withReadLock propagates a thrown error and still unlocks")
    func withReadLockRethrows() async throws {
        struct Boom: Error {}
        let lock = AsyncRWLock(1)

        await #expect(throws: Boom.self) {
            try await lock.withReadLock { _ in throw Boom() }
        }

        // If the failing call had leaked its hold, this would never return.
        #expect(try await lock.withWriteLock { $0 } == 1)
    }

    @Test("withWriteLock propagates a thrown error and still unlocks")
    func withWriteLockRethrows() async throws {
        struct Boom: Error {}
        let lock = AsyncRWLock(1)

        await #expect(throws: Boom.self) {
            try await lock.withWriteLock { _ in throw Boom() }
        }

        #expect(try await lock.withWriteLock { $0 } == 1)
    }

    @Test("the closures may suspend while holding the lock")
    func closuresSuspend() async throws {
        let lock = AsyncRWLock([Int]())

        try await lock.withWriteLock { value in
            value.append(1)
            await Task.yield()
            value.append(2)
        }
        let seen = try await lock.withReadLock { value -> [Int] in
            let first = value
            await Task.yield()
            return first + value
        }

        #expect(seen == [1, 2, 1, 2])
    }

    @Test("readers run concurrently")
    func readersRunConcurrently() async throws {
        let lock = AsyncRWLock(0)
        let inside = Mutex(0)
        let release = Gate()
        let readers = 4

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<readers {
                group.addTask { @Sendable in
                    try await lock.withReadLock { _ in
                        inside.withLock { $0 += 1 }
                        await release.wait()
                    }
                }
            }

            // Every reader is inside at once, which serialized readers could
            // never manage.
            #expect(await eventually { inside.withLock { $0 } == readers })
            release.open()
            try await group.waitForAll()
        }
    }

    @Test("a reader blocks writers but not readers")
    func readerBlocksWriters() async throws {
        let lock = AsyncRWLock(0)
        let acquired = Gate()
        let release = Gate()

        let reader = Task { @Sendable in
            try await lock.withReadLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        #expect(await lock.withWriteLockIfAvailable { _ in } == nil)
        #expect(await lock.withReadLockIfAvailable { $0 } == 0)

        release.open()
        try await reader.value
    }

    @Test("a writer blocks both readers and writers")
    func writerBlocksAll() async throws {
        let lock = AsyncRWLock(0)
        let acquired = Gate()
        let release = Gate()

        let writer = Task { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        #expect(await lock.withReadLockIfAvailable { _ in } == nil)
        #expect(await lock.withWriteLockIfAvailable { _ in } == nil)

        release.open()
        try await writer.value
    }

    @Test("IfAvailable variants succeed on an uncontended lock")
    func ifAvailableUncontended() async throws {
        let lock = AsyncRWLock(7)
        #expect(await lock.withReadLockIfAvailable { $0 } == 7)
        #expect(await lock.withWriteLockIfAvailable { value -> Int in
            value += 1
            return value
        } == 8)
    }

    @Test("holds a noncopyable value")
    func noncopyableValue() async throws {
        struct Token: ~Copyable {
            var id: Int
        }

        let lock = AsyncRWLock(Token(id: 1))
        try await lock.withWriteLock { $0.id = 2 }
        #expect(try await lock.withReadLock { $0.id } == 2)
    }

    @Test("runs the closures on the caller's actor")
    func closuresRunOnCallersActor() async throws {
        actor Recorder {
            let lock = AsyncRWLock(0)
            var seen: [Int] = []

            func record() async throws {
                try await lock.withWriteLock { value in
                    value += 1
                    // Synchronous access to actor state from inside the
                    // closure only compiles if the closure is isolated to
                    // this actor.
                    seen.append(value)
                }
                try await lock.withReadLock { value in
                    seen.append(-value)
                }
            }
        }

        let recorder = Recorder()
        try await recorder.record()
        try await recorder.record()
        #expect(await recorder.seen == [1, -1, 2, -2])
    }

    @Test("writers exclude each other even when they suspend inside the lock")
    func serializesMutation() async throws {
        let lock = AsyncRWLock(0)
        let overlaps = Mutex(0)
        let inside = Mutex(0)
        let tasks = 32
        let iterations = 20

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<tasks {
                group.addTask { @Sendable in
                    for _ in 0..<iterations {
                        try await lock.withWriteLock { value in
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

        #expect(try await lock.withReadLock { $0 } == tasks * iterations)
        #expect(overlaps.withLock { $0 } == 0)
    }

    @Test("readers never observe a torn write")
    func readersSeeConsistentWrites() async throws {
        // A writer keeps both halves equal, and suspends between updating
        // them; a reader that ran during a write would see them differ.
        let lock = AsyncRWLock((0, 0))
        let torn = Mutex(0)
        let iterations = 50

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @Sendable in
                for round in 1...iterations {
                    try await lock.withWriteLock { value in
                        value.0 = round
                        await Task.yield()
                        value.1 = round
                    }
                }
            }
            for _ in 0..<4 {
                group.addTask { @Sendable in
                    for _ in 0..<iterations {
                        try await lock.withReadLock { value in
                            if value.0 != value.1 {
                                torn.withLock { $0 += 1 }
                            }
                            await Task.yield()
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(torn.withLock { $0 } == 0)
    }
}

// MARK: - Queueing

@Suite(
    "AsyncRWLock queueing",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncRWLockQueueingTests {
    @Test("a waiting writer stops new readers")
    func waitingWriterBlocksReaders() async throws {
        let lock = AsyncRWLock(0)
        let order = Mutex([String]())
        let acquired = Gate()
        let release = Gate()

        let reader = Task { @Sendable in
            try await lock.withReadLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let writer = Task { @Sendable in
            try await lock.withWriteLock { _ in order.withLock { $0.append("writer") } }
        }
        await lock.waitForWaiters(1)

        // The lock is only read-held, but the queued writer is in the way.
        #expect(await lock.withReadLockIfAvailable { _ in } == nil)
        let lateReader = Task { @Sendable in
            try await lock.withReadLock { _ in order.withLock { $0.append("reader") } }
        }
        await lock.waitForWaiters(2)

        release.open()
        try await reader.value
        try await writer.value
        try await lateReader.value

        #expect(order.withLock { $0 } == ["writer", "reader"])
    }

    @Test("a departing writer admits every reader queued behind it together")
    func departingWriterAdmitsReaders() async throws {
        let lock = AsyncRWLock(0)
        let inside = Mutex(0)
        let acquired = Gate()
        let releaseWriter = Gate()
        let releaseReaders = Gate()
        let readers = 3

        let writer = Task { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await releaseWriter.wait()
            }
        }
        await acquired.wait()

        var tasks: [Task<Void, any Error>] = []
        for index in 1...readers {
            tasks.append(Task { @Sendable in
                try await lock.withReadLock { _ in
                    inside.withLock { $0 += 1 }
                    await releaseReaders.wait()
                }
            })
            await lock.waitForWaiters(index)
        }

        releaseWriter.open()
        try await writer.value

        #expect(await eventually { inside.withLock { $0 } == readers })
        releaseReaders.open()
        for task in tasks {
            try await task.value
        }
    }

    @Test("a run of readers at the head stops at the first writer")
    func readersStopAtWriter() async throws {
        let lock = AsyncRWLock(0)
        let order = Mutex([String]())
        let acquired = Gate()
        let firstReaderInside = Gate()
        let releaseWriter = Gate()
        let releaseFirstReader = Gate()

        let writer = Task { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await releaseWriter.wait()
            }
        }
        await acquired.wait()

        // Queued in this order, at one priority: reader, writer, reader.
        let firstReader = Task { @Sendable in
            try await lock.withReadLock { _ in
                order.withLock { $0.append("reader 1") }
                firstReaderInside.open()
                await releaseFirstReader.wait()
            }
        }
        await lock.waitForWaiters(1)
        let secondWriter = Task { @Sendable in
            try await lock.withWriteLock { _ in order.withLock { $0.append("writer") } }
        }
        await lock.waitForWaiters(2)
        let secondReader = Task { @Sendable in
            try await lock.withReadLock { _ in order.withLock { $0.append("reader 2") } }
        }
        await lock.waitForWaiters(3)

        releaseWriter.open()
        try await writer.value
        await firstReaderInside.wait()

        // The first reader is in alone: the writer behind it holds the second
        // reader back, though the lock is only read-held.
        #expect(lock.handle._waiterCount == 2)
        #expect(order.withLock { $0 } == ["reader 1"])

        releaseFirstReader.open()
        try await firstReader.value
        try await secondWriter.value
        try await secondReader.value

        #expect(order.withLock { $0 } == ["reader 1", "writer", "reader 2"])
    }

    @Test("serves a higher-priority reader before an earlier lower-priority writer")
    func priorityOrder() async throws {
        let lock = AsyncRWLock(0)
        let order = Mutex([String]())
        let acquired = Gate()
        let release = Gate()

        let holder = Task { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let lowWriter = Task(priority: .low) { @Sendable in
            try await lock.withWriteLock { _ in order.withLock { $0.append("low writer") } }
        }
        await lock.waitForWaiters(1)
        let highReader = Task(priority: .high) { @Sendable in
            try await lock.withReadLock { _ in order.withLock { $0.append("high reader") } }
        }
        await lock.waitForWaiters(2)

        release.open()
        try await holder.value
        try await lowWriter.value
        try await highReader.value

        #expect(order.withLock { $0 } == ["high reader", "low writer"])
    }

    @Test("hands the lock to writers in arrival order")
    func writersInArrivalOrder() async throws {
        let lock = AsyncRWLock(0)
        let order = Mutex([Int]())
        let acquired = Gate()
        let release = Gate()

        let holder = Task { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        var writers: [Task<Void, any Error>] = []
        for index in 1...5 {
            writers.append(Task { @Sendable in
                try await lock.withWriteLock { _ in order.withLock { $0.append(index) } }
            })
            await lock.waitForWaiters(index)
        }

        release.open()
        try await holder.value
        for writer in writers {
            try await writer.value
        }

        #expect(order.withLock { $0 } == [1, 2, 3, 4, 5])
    }
}

// MARK: - Cancellation

@Suite(
    "AsyncRWLock cancellation",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncRWLockCancellationTests {
    @Test("a reader cancelled while queued throws and leaves the queue")
    func readerCancelledWhileWaiting() async throws {
        let lock = AsyncRWLock(0)
        let acquired = Gate()
        let release = Gate()

        let writer = Task { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let reader = Task { @Sendable in
            try await lock.withReadLock { _ in Issue.record("a cancelled reader ran") }
        }
        await lock.waitForWaiters(1)
        reader.cancel()

        await #expect(throws: CancellationError.self) {
            try await reader.value
        }
        #expect(lock.handle._waiterCount == 0)

        // The writer is unaffected, and the lock still works afterwards.
        release.open()
        try await writer.value
        #expect(try await lock.withReadLock { $0 } == 0)
    }

    @Test("a writer cancelled while queued lets the readers it held back in")
    func cancelledWriterReleasesReaders() async throws {
        let lock = AsyncRWLock(0)
        let inside = Mutex(0)
        let release = Gate()

        let reader = Task { @Sendable in
            try await lock.withReadLock { _ in
                inside.withLock { $0 += 1 }
                await release.wait()
            }
        }
        #expect(await eventually { inside.withLock { $0 } == 1 })

        let writer = Task { @Sendable in
            try await lock.withWriteLock { _ in Issue.record("a cancelled writer ran") }
        }
        await lock.waitForWaiters(1)

        // Queued behind the writer, and so kept out of a lock that is only
        // read-held.
        let lateReader = Task { @Sendable in
            try await lock.withReadLock { _ in
                inside.withLock { $0 += 1 }
                await release.wait()
            }
        }
        await lock.waitForWaiters(2)
        #expect(inside.withLock { $0 } == 1)

        writer.cancel()
        await #expect(throws: CancellationError.self) {
            try await writer.value
        }

        // With the writer gone, the late reader joins the first one — while
        // the first still holds the lock.
        #expect(await eventually { inside.withLock { $0 } == 2 })
        #expect(lock.handle._waiterCount == 0)

        release.open()
        try await reader.value
        try await lateReader.value
    }

    @Test("an already-cancelled task does not wait for a held lock")
    func cancelledBeforeWaiting() async throws {
        let lock = AsyncRWLock(0)
        let acquired = Gate()
        let release = Gate()

        let writer = Task { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        let cancelled = Task { @Sendable in
            // Wait for the cancellation below to land first: the call must
            // then see a held lock and a cancelled task, and not join the
            // queue.
            while !Task.isCancelled {
                await Task.yield()
            }
            try await lock.withReadLock { _ -> Void in Issue.record("a cancelled reader ran") }
        }
        cancelled.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        #expect(lock.handle._waiterCount == 0)

        release.open()
        try await writer.value
    }

    @Test("an already-cancelled task still takes a free lock")
    func cancelledTakesFreeLock() async throws {
        let lock = AsyncRWLock(0)

        let task = Task { @Sendable in
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await lock.withWriteLock { value -> Bool in
                value = 1
                return Task.isCancelled
            }
        }
        task.cancel()

        #expect(try await task.value == true)
        #expect(try await lock.withReadLock { $0 } == 1)
    }

    @Test("cancelling one waiter does not disturb the others")
    func cancellingOneWaiter() async throws {
        let lock = AsyncRWLock(0)
        let order = Mutex([Int]())
        let acquired = Gate()
        let release = Gate()

        let holder = Task { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        var waiters: [Task<Void, any Error>] = []
        for index in 1...3 {
            waiters.append(Task { @Sendable in
                try await lock.withWriteLock { _ in order.withLock { $0.append(index) } }
            })
            await lock.waitForWaiters(index)
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
