//
//  StressTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncCore
import SynchronizationKitAsyncMutex
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

/// `AsyncMutex` under as many interleavings as a run has time for.
///
/// `AsyncMutexCancellationTests` sets up each cancellation at one moment —
/// while queued, before queueing, after the handoff — and checks what
/// follows. This cancels at moments it does not choose, across a crowd of
/// tasks of every priority, and checks that whatever moment it was, nothing
/// was lost: no two tasks inside at once, every completed closure counted,
/// and nobody left in the queue. `stressScale` says how many times over.
///
/// Skipped under ThreadSanitizer on Linux for the reason `AsyncMutexTests`
/// gives. On macOS these are what the sanitized coverage of the wait queue's
/// handoff annotations rests on: a handoff fast enough to grant a waiter
/// before it has finished suspending, which only a suite at this volume
/// reaches, is one of the two cases `CSynchronizationKitCore.h` exists for.
@Suite(
    "AsyncMutex stress",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncMutexStressTests {
    static let priorities: [TaskPriority] = [.background, .utility, .medium, .high]

    /// A crowd taking the lock in turn, half of it cancelled at random
    /// moments along the way. A closure that ran counted itself; the value
    /// has to agree with that count, however many closures cancellation
    /// kept from running.
    @Test("cancelling waiters at random loses nothing", arguments: stressWorkerCounts)
    func cancellation(tasks: Int) async throws {
        let rounds = 50 * stressScale
        let mutex = AsyncMutex(0)
        let inside = Mutex(0)
        let overlaps = Mutex(0)
        let completed = Mutex(0)

        let workers = (0 ..< tasks).map { _ in
            Task { @Sendable in
                for _ in 0 ..< rounds {
                    do {
                        try await mutex.withLock { value in
                            if inside.withLock({ $0 += 1; return $0 }) != 1 {
                                overlaps.withLock { $0 += 1 }
                            }
                            let snapshot = value
                            await Task.yield()
                            value = snapshot + 1
                            inside.withLock { $0 -= 1 }
                        }
                        completed.withLock { $0 += 1 }
                    } catch is CancellationError {
                        return
                    }
                }
            }
        }

        // Paced by yields rather than by the clock, so the cancellations land
        // on the same scale as the workers' progress: about half while
        // queued, the rest while holding or between turns.
        try await expectCompletion(of: workers, within: 300) {
            var random = SplitMix64(seed: UInt64(tasks))
            for worker in workers where Bool.random(using: &random) {
                for _ in 0 ..< Int.random(in: 0 ..< 16, using: &random) {
                    await Task.yield()
                }
                worker.cancel()
            }
        }

        #expect(overlaps.withLock { $0 } == 0, "two tasks were inside the lock at once")
        #expect(mutex.handle._waiterCount == 0, "a cancelled waiter was left in the queue")
        // A try rather than a take: a lock left held by a worker that never
        // finished would hold this task with it, past the deadline above.
        guard let value = await mutex.withLockIfAvailable({ $0 }) else {
            Issue.record("the lock was left held")
            return
        }
        #expect(value == completed.withLock { $0 })
    }

    /// A crowd of every priority, so that a higher-priority waiter keeps
    /// arriving at a lower-priority holder and the escalation paths run
    /// against the handoff as often as the handoff runs at all.
    @Test("holders of every priority hand over cleanly", arguments: stressWorkerCounts)
    func priorityChurn(tasks: Int) async throws {
        let rounds = 50 * stressScale
        let mutex = AsyncMutex(0)
        let inside = Mutex(0)
        let overlaps = Mutex(0)

        var random = SplitMix64(seed: UInt64(tasks))
        let workers = (0 ..< tasks).map { _ in
            // Drawn here rather than in the task: the generator is not
            // shared, and the priority has to be known to start the task.
            let priority = Self.priorities.randomElement(using: &random)
            return Task(priority: priority) { @Sendable in
                for _ in 0 ..< rounds {
                    try await mutex.withLock { value in
                        if inside.withLock({ $0 += 1; return $0 }) != 1 {
                            overlaps.withLock { $0 += 1 }
                        }
                        value += 1
                        await Task.yield()
                        inside.withLock { $0 -= 1 }
                    }
                }
            }
        }

        try await expectCompletion(of: workers, within: 300)

        #expect(overlaps.withLock { $0 } == 0, "two tasks were inside the lock at once")
        #expect(mutex.handle._waiterCount == 0)
        guard let value = await mutex.withLockIfAvailable({ $0 }) else {
            Issue.record("the lock was left held")
            return
        }
        #expect(value == tasks * rounds)
    }
}
