//
//  StressTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncCore
import SynchronizationKitAsyncSemaphore
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

/// `AsyncSemaphore` under as many handoffs as a run has time for.
///
/// What `Semaphore`'s stress suite looks for — a wake lost or invented — and
/// what only the asynchronous one can get wrong on top: a count handed to a
/// waiter at the moment it is cancelled has to end up in exactly one place,
/// with the waiter if it was resumed first and back on the semaphore if the
/// cancellation was. `stressScale` says how many times over.
///
/// Skipped under ThreadSanitizer on Linux for the reason `AsyncSemaphoreTests`
/// gives.
@Suite(
    "AsyncSemaphore stress",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncSemaphoreStressTests {
    static let priorities: [TaskPriority] = [.background, .utility, .medium, .high]

    /// Drains `semaphore` of exactly `count` and checks that nothing is left:
    /// that many waits go through, and the next has to queue.
    private func expectCount(_ count: Int, on semaphore: AsyncSemaphore) async throws {
        try await expectCompletion(within: 30, "a count that was signalled is missing") {
            for _ in 0 ..< count {
                try await semaphore.wait()
            }
        }

        // Polled with a bound rather than through `waitForWaiters`: a count
        // left over lets the extra wait through without queueing, and the
        // failure has to be reported rather than waited for.
        let extra = Task { @Sendable in try await semaphore.wait() }
        #expect(await eventually { semaphore._waiterCount == 1 }, "a count was left over")
        semaphore.signal()
        try await expectCompletion(within: 30, "the signal never woke the extra wait") {
            try await extra.value
        }
        #expect(semaphore._waiterCount == 0)
    }

    /// Producers signalling into a crowd of consumers of every priority,
    /// half of which are cancelled at random moments. A consumer counts each
    /// wait that returned; what the producers signalled has to equal that
    /// plus what is left on the semaphore, to the count.
    @Test("cancelling consumers at random loses no count", arguments: stressWorkerCounts)
    func cancellation(consumers: Int) async throws {
        let share = 50 * stressScale
        let semaphore = AsyncSemaphore(value: 0)
        let consumed = Mutex(0)

        var random = SplitMix64(seed: UInt64(consumers))
        let workers = (0 ..< consumers).map { _ in
            let priority = Self.priorities.randomElement(using: &random)
            return Task(priority: priority) { @Sendable in
                for _ in 0 ..< share {
                    do {
                        try await semaphore.wait()
                    } catch is CancellationError {
                        return
                    }
                    consumed.withLock { $0 += 1 }
                }
            }
        }
        // One producer per consumer, each signalling that consumer's share,
        // so the signals arrive from several tasks at once.
        let producers: [Task<Void, any Error>] = (0 ..< consumers).map { _ in
            Task { @Sendable in
                for _ in 0 ..< share {
                    semaphore.signal()
                    await Task.yield()
                }
            }
        }

        try await expectCompletion(of: workers + producers, within: 300) {
            var random = SplitMix64(seed: UInt64(consumers) &+ 1)
            for worker in workers where Bool.random(using: &random) {
                for _ in 0 ..< Int.random(in: 0 ..< 16, using: &random) {
                    await Task.yield()
                }
                worker.cancel()
            }
        }

        let signalled = consumers * share
        let taken = consumed.withLock { $0 }
        #expect(taken <= signalled, "a wait returned that no signal had earned")
        #expect(semaphore._waiterCount == 0, "a cancelled waiter was left in the queue")
        try await expectCount(signalled - taken, on: semaphore)
    }

    /// The bound, held across a crowd of every priority with some of it
    /// cancelled: at no point are more tasks through than there are counts,
    /// and every count comes back.
    @Test("the bound holds however many tasks press on it", arguments: stressWorkerCounts)
    func bound(tasks: Int) async throws {
        let limit = 3
        let rounds = 50 * stressScale
        let semaphore = AsyncSemaphore(value: limit)
        let inside = Mutex(0)
        let overLimit = Mutex(0)

        var random = SplitMix64(seed: UInt64(tasks))
        let workers = (0 ..< tasks).map { _ in
            let priority = Self.priorities.randomElement(using: &random)
            return Task(priority: priority) { @Sendable in
                for _ in 0 ..< rounds {
                    do {
                        try await semaphore.wait()
                    } catch is CancellationError {
                        return
                    }
                    let now = inside.withLock { $0 += 1; return $0 }
                    if now > limit {
                        overLimit.withLock { $0 += 1 }
                    }
                    await Task.yield()
                    inside.withLock { $0 -= 1 }
                    semaphore.signal()
                }
            }
        }

        try await expectCompletion(of: workers, within: 300) {
            var random = SplitMix64(seed: UInt64(tasks) &+ 1)
            for worker in workers where Bool.random(using: &random) {
                for _ in 0 ..< Int.random(in: 0 ..< 16, using: &random) {
                    await Task.yield()
                }
                worker.cancel()
            }
        }

        #expect(overLimit.withLock { $0 } == 0, "more tasks were through than counts")
        #expect(inside.withLock { $0 } == 0)
        #expect(semaphore._waiterCount == 0, "a cancelled waiter was left in the queue")
        try await expectCount(limit, on: semaphore)
    }
}
