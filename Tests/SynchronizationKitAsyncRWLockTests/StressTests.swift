//
//  StressTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncCore
import SynchronizationKitAsyncRWLock
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

/// `AsyncRWLock` under as many interleavings as a run has time for.
///
/// The queueing and cancellation suites each set up one shape — a writer
/// queued behind readers, a reader cancelled while a writer holds — and
/// check what the lock does with it. This draws the shapes at random: a mix
/// of readers and writers of every priority, each holding for a random
/// spell, some cancelled at moments the test does not choose. What has to
/// survive every one of them is what `RWLock`'s stress suite checks of it,
/// plus what only an asynchronous lock can get wrong: a queue with somebody
/// still in it after everybody has left. `stressScale` says how many times
/// over.
///
/// Skipped under ThreadSanitizer on Linux for the reason `AsyncRWLockTests`
/// gives.
@Suite(
    "AsyncRWLock stress",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct AsyncRWLockStressTests {
    static let priorities: [TaskPriority] = [.background, .utility, .medium, .high]

    /// A reader and writer mix, named for the report.
    struct Mix: Sendable, CustomTestStringConvertible {
        var readers: Int
        var writers: Int

        var testDescription: String {
            "\(readers) readers, \(writers) writers"
        }
    }

    static let mixes = [
        Mix(readers: 1, writers: 1),
        Mix(readers: 8, writers: 1),
        Mix(readers: 32, writers: 1),
        Mix(readers: 1, writers: 8),
        Mix(readers: 8, writers: 8),
        Mix(readers: 32, writers: 8),
    ]

    /// Two counters a writer moves one at a time, with a suspension between,
    /// so a reader let in alongside it has every chance to see them differ.
    struct Pair {
        var first = 0
        var second = 0
    }

    /// The lock, and the bookkeeping the workers check it against.
    ///
    /// A class so that the workers, which are escaping tasks, have something
    /// to capture the lock through: a `borrowing` parameter cannot be
    /// captured by one.
    final class Fixture: Sendable {
        static let writerBit = 1 << 30

        let lock = AsyncRWLock(Pair())

        /// Who is inside the lock: the top bit for a writer, the low bits
        /// counting readers.
        let occupancy = Mutex(0)
        let violations = Mutex(0)
        let torn = Mutex(0)
        let writes = Mutex(0)

        func enterWriter() {
            let before = occupancy.withLock { word in
                defer { word += Self.writerBit }
                return word
            }
            if before != 0 {
                violations.withLock { $0 += 1 }
            }
        }

        func leaveWriter() {
            let after = occupancy.withLock { word in
                word -= Self.writerBit
                return word
            }
            if after != 0 {
                violations.withLock { $0 += 1 }
            }
        }

        func enterReader(seeing pair: Pair) {
            let before = occupancy.withLock { word in
                defer { word += 1 }
                return word
            }
            if before & Self.writerBit != 0 {
                violations.withLock { $0 += 1 }
            }
            if pair.first != pair.second {
                torn.withLock { $0 += 1 }
            }
        }

        func leaveReader() {
            occupancy.withLock { $0 -= 1 }
        }

        /// Starts the mix, every task at a random priority. A worker that is
        /// cancelled stops where it is; a writer counts each write it
        /// completed, so the value can be checked against what actually ran.
        func start(_ mix: Mix, rounds: Int, seed: UInt64) -> [Task<Void, any Error>] {
            var random = SplitMix64(seed: seed)
            var workers: [Task<Void, any Error>] = []

            for writer in 0 ..< mix.writers {
                let priority = AsyncRWLockStressTests.priorities.randomElement(using: &random)
                workers.append(Task(priority: priority) { @Sendable in
                    var random = SplitMix64(seed: seed &+ UInt64(writer))
                    for _ in 0 ..< rounds {
                        let spell = Int.random(in: 0 ... 3, using: &random)
                        do {
                            try await self.lock.withWriteLock { pair in
                                self.enterWriter()
                                pair.first += 1
                                for _ in 0 ..< spell {
                                    await Task.yield()
                                }
                                pair.second += 1
                                self.leaveWriter()
                            }
                            self.writes.withLock { $0 += 1 }
                        } catch is CancellationError {
                            return
                        }
                    }
                })
            }

            for reader in 0 ..< mix.readers {
                let priority = AsyncRWLockStressTests.priorities.randomElement(using: &random)
                workers.append(Task(priority: priority) { @Sendable in
                    var random = SplitMix64(seed: seed &+ 1_000 &+ UInt64(reader))
                    for _ in 0 ..< rounds {
                        let spell = Int.random(in: 0 ... 3, using: &random)
                        do {
                            try await self.lock.withReadLock { pair in
                                self.enterReader(seeing: pair)
                                for _ in 0 ..< spell {
                                    await Task.yield()
                                }
                                self.leaveReader()
                            }
                        } catch is CancellationError {
                            return
                        }
                    }
                })
            }

            return workers
        }

        func check() async {
            #expect(violations.withLock { $0 } == 0, "somebody was inside alongside a writer")
            #expect(torn.withLock { $0 } == 0, "a reader saw a half-finished write")
            #expect(occupancy.withLock { $0 } == 0)
            #expect(lock.handle._waiterCount == 0, "a waiter was left in the queue")
            // A try rather than a take: a lock left held for writing by a
            // worker that never finished would hold this task with it, past
            // the deadline the tests set.
            guard let pair = await lock.withReadLockIfAvailable({ $0 }) else {
                Issue.record("the lock was left held for writing")
                return
            }
            #expect(pair.first == writes.withLock { $0 })
            #expect(pair.second == writes.withLock { $0 })
        }
    }

    @Test("readers and writers of every priority take turns cleanly", arguments: mixes)
    func priorityChurn(mix: Mix) async throws {
        let fixture = Fixture()
        let workers = fixture.start(mix, rounds: 50 * stressScale, seed: 1)

        try await expectCompletion(of: workers, within: 300)

        await fixture.check()
    }

    /// The same crowd with half of it cancelled at random moments. A
    /// cancelled writer may have been all that held a run of readers back,
    /// and a cancelled reader may have been the last a writer was waiting
    /// on; either way, whoever it was holding back has to be served.
    @Test("cancelling readers and writers at random loses nothing", arguments: mixes)
    func cancellation(mix: Mix) async throws {
        let fixture = Fixture()
        let workers = fixture.start(mix, rounds: 50 * stressScale, seed: 2)

        try await expectCompletion(of: workers, within: 300) {
            var random = SplitMix64(seed: 3)
            for worker in workers where Bool.random(using: &random) {
                for _ in 0 ..< Int.random(in: 0 ..< 16, using: &random) {
                    await Task.yield()
                }
                worker.cancel()
            }
        }

        await fixture.check()
    }
}
