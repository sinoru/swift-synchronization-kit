//
//  StressTests.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import SynchronizationKitAtomic
import SynchronizationKitTestUtils
import Testing

@testable import SynchronizationKitRWLock

/// `RWLock` under as many interleavings as a run has time for.
///
/// `MutualExclusionTests` checks the property — nobody inside alongside a
/// writer — for one reader and writer mix at two fixed dwells. This runs the
/// same check across a matrix of mixes, with the dwell drawn at random per
/// critical section and the `IfAvailable` variants mixed in, so that the
/// lock's every path is taken against every other from every side.
/// `stressScale` says how many times over.
@Suite("RWLock stress")
struct RWLockStressTests {
    /// A reader and writer mix, named for the report.
    struct Mix: Sendable, CustomTestStringConvertible {
        var readers: Int
        var writers: Int

        var testDescription: String {
            "\(readers) readers, \(writers) writers"
        }
    }

    /// The mixes, after swift-atomics' matrices: one side alone, so each
    /// handoff path is covered without the other; then both together, up to
    /// more workers than any CI runner has cores.
    static let mixes = [
        Mix(readers: 1, writers: 1),
        Mix(readers: 4, writers: 1),
        Mix(readers: 16, writers: 1),
        Mix(readers: 1, writers: 4),
        Mix(readers: 4, writers: 4),
        Mix(readers: 8, writers: 4),
        Mix(readers: 16, writers: 8),
    ]

    static let writerBit: Int32 = 1 << 30

    /// Two counters a writer moves one at a time, and a word recording who is
    /// inside: the top bit for a writer, the low bits counting readers.
    ///
    /// A reader that finds the counters disagreeing, or the writer bit set,
    /// has caught the lock letting it in alongside a writer; a writer that
    /// finds the word non-zero has caught it letting anybody in alongside
    /// itself.
    struct Pair {
        var first = 0
        var second = 0
    }

    @Test("nobody shares the lock with a writer, whatever the mix", arguments: mixes)
    func exclusion(mix: Mix) {
        let iterations = 2_000 * stressScale
        let lock = RWLock(Pair())
        let occupancy = Atomic<Int32>(0)
        let torn = Atomic<Int32>(0)
        let violations = Atomic<Int32>(0)
        let writes = Atomic<Int>(0)
        let done = DispatchSemaphore(value: 0)

        @Sendable func dwell(_ spell: Int) {
            for _ in 0 ..< spell {
                _ = occupancy.load(ordering: .relaxed)
            }
        }

        @Sendable func write(_ pair: inout Pair, dwelling spell: Int) {
            if occupancy.wrappingAdd(Self.writerBit, ordering: .acquiringAndReleasing).oldValue != 0 {
                violations.wrappingAdd(1, ordering: .relaxed)
            }
            pair.first &+= 1
            dwell(spell)
            pair.second &+= 1
            if occupancy.wrappingSubtract(Self.writerBit, ordering: .acquiringAndReleasing).newValue != 0 {
                violations.wrappingAdd(1, ordering: .relaxed)
            }
        }

        @Sendable func read(_ pair: borrowing Pair, dwelling spell: Int) {
            if occupancy.wrappingAdd(1, ordering: .acquiringAndReleasing).oldValue & Self.writerBit != 0 {
                violations.wrappingAdd(1, ordering: .relaxed)
            }
            if pair.first != pair.second {
                torn.wrappingAdd(1, ordering: .relaxed)
            }
            dwell(spell)
            occupancy.wrappingSubtract(1, ordering: .acquiringAndReleasing)
        }

        for writer in 0 ..< mix.writers {
            Thread.detachNewThread {
                var random = SplitMix64(seed: UInt64(writer))
                var count = 0
                for _ in 0 ..< iterations {
                    let spell = Int.random(in: 0 ... 64, using: &random)
                    if Bool.random(using: &random) {
                        lock.withWriteLock { write(&$0, dwelling: spell) }
                        count += 1
                    } else if lock.withWriteLockIfAvailable({ write(&$0, dwelling: spell) }) != nil {
                        count += 1
                    }
                }
                writes.wrappingAdd(count, ordering: .relaxed)
                done.signal()
            }
        }

        for reader in 0 ..< mix.readers {
            Thread.detachNewThread {
                var random = SplitMix64(seed: UInt64(1_000 + reader))
                for _ in 0 ..< iterations {
                    let spell = Int.random(in: 0 ... 64, using: &random)
                    if Bool.random(using: &random) {
                        lock.withReadLock { read($0, dwelling: spell) }
                    } else {
                        _ = lock.withReadLockIfAvailable { read($0, dwelling: spell) }
                    }
                }
                done.signal()
            }
        }

        for _ in 0 ..< (mix.readers + mix.writers) {
            expectSignal(done, within: 300)
        }

        #expect(violations.load(ordering: .relaxed) == 0, "somebody was inside alongside a writer")
        #expect(torn.load(ordering: .relaxed) == 0, "a reader saw a half-finished write")
        #expect(occupancy.load(ordering: .relaxed) == 0)
        // A try rather than a take: a writer left holding or waiting by a
        // worker that never finished would block this thread with it, past
        // the bound the joins above set.
        guard let pair = lock.withReadLockIfAvailable({ $0 }) else {
            Issue.record("the lock was left held or awaited by a writer")
            return
        }
        #expect(pair.first == writes.load(ordering: .relaxed))
        #expect(pair.second == writes.load(ordering: .relaxed))
    }
}
