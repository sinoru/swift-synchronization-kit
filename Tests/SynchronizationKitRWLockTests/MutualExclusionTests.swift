//
//  MutualExclusionTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Dispatch
import Foundation
import SynchronizationKitAtomic
import Testing

@testable import SynchronizationKitRWLock

/// Direct checks that nobody shares the lock with a writer.
///
/// The suites elsewhere check results — a total that adds up, a snapshot that
/// agrees with itself. These two check the property itself, and both hold the
/// critical section open for a configurable spell so that an overlap has a wide
/// window to happen in rather than a few instructions.
///
/// - Note: These used to draw ThreadSanitizer reports of reader/writer races on
///   the protected value wherever the Mach semaphore backend ran, and the cause
///   turned out to be the sanitizer rather than the lock. A reader woken from a
///   wait takes no atomic on its way out of it — see `_readLock` — so on that
///   backend the writer's release and the reader's acquire are the semaphore
///   itself, and ThreadSanitizer does not model those calls. A writer, a reader
///   and one cell ordered by nothing but a Mach semaphore reproduces the report
///   on its own, where the same shape ordered by an atomic or a dispatch
///   semaphore does not and the same shape ordered by nothing does.
///
///   `RWLockHandle+Waiting.swift` now tells the sanitizer about that edge where
///   it makes it, so there is nothing left to explain away: this suite runs
///   clean under `-enableThreadSanitizer` on a runtime old enough to take that
///   backend, and reports races there again the moment the annotations are
///   taken out.
@Suite("RWLock mutual exclusion")
struct MutualExclusionTests {
    static let writerBit: Int32 = 1 << 30
    static let dwells: [Int] = [0, 200]

    /// Two counters a writer moves one at a time. A reader that overlaps a
    /// writer at any point during the spell between them sees them disagree.
    struct Pair {
        var first = 0
        var second = 0
    }

    @Test("a reader never sees a writer's half-finished work", arguments: dwells)
    func readersNeverSeeAPartialWrite(dwell: Int) {
        let writers = 4
        let readers = 8
        let iterations = 5_000

        let lock = RWLock(Pair())
        let torn = Atomic<Int32>(0)
        let spinner = Atomic<Int32>(0)
        let done = DispatchSemaphore(value: 0)

        @Sendable func dwellHere() {
            for _ in 0 ..< dwell {
                _ = spinner.load(ordering: .relaxed)
            }
        }

        for _ in 0 ..< writers {
            Thread.detachNewThread {
                for _ in 0 ..< iterations {
                    lock.withWriteLock { pair in
                        pair.first &+= 1
                        dwellHere()
                        pair.second &+= 1
                    }
                }
                done.signal()
            }
        }

        for _ in 0 ..< readers {
            Thread.detachNewThread {
                for _ in 0 ..< iterations {
                    lock.withReadLock { pair in
                        if pair.first != pair.second {
                            torn.wrappingAdd(1, ordering: .relaxed)
                        }
                    }
                }
                done.signal()
            }
        }

        for _ in 0 ..< (writers + readers) {
            expectSignal(done, within: 120)
        }

        #expect(torn.load(ordering: .relaxed) == 0)
        #expect(lock.withReadLock { $0.first } == writers * iterations)
        #expect(lock.withReadLock { $0.second } == writers * iterations)
    }

    /// A word recording who is inside: the top bit for a writer, the low bits
    /// counting readers. A writer that finds it non-zero on entry, or a reader
    /// that finds the writer bit set, has caught the lock letting two parties in
    /// at once.
    @Test("nobody is inside the lock alongside a writer", arguments: dwells)
    func nobodySharesWithAWriter(dwell: Int) {
        let writers = 4
        let readers = 8
        let iterations = 5_000

        let lock = RWLock(0)
        let occupancy = Atomic<Int32>(0)
        let writerViolations = Atomic<Int32>(0)
        let readerViolations = Atomic<Int32>(0)
        let exitViolations = Atomic<Int32>(0)
        let done = DispatchSemaphore(value: 0)

        @Sendable func dwellHere() {
            for _ in 0 ..< dwell {
                _ = occupancy.load(ordering: .relaxed)
            }
        }

        for _ in 0 ..< writers {
            Thread.detachNewThread {
                for _ in 0 ..< iterations {
                    lock.withWriteLock { value in
                        let before = occupancy.wrappingAdd(
                            Self.writerBit, ordering: .acquiringAndReleasing
                        ).oldValue
                        if before != 0 {
                            writerViolations.wrappingAdd(1, ordering: .relaxed)
                        }
                        value &+= 1
                        dwellHere()
                        let after = occupancy.wrappingSubtract(
                            Self.writerBit, ordering: .acquiringAndReleasing
                        ).newValue
                        if after != 0 {
                            exitViolations.wrappingAdd(1, ordering: .relaxed)
                        }
                    }
                }
                done.signal()
            }
        }

        for _ in 0 ..< readers {
            Thread.detachNewThread {
                for _ in 0 ..< iterations {
                    lock.withReadLock { _ in
                        let before = occupancy.wrappingAdd(
                            1, ordering: .acquiringAndReleasing
                        ).oldValue
                        if before & Self.writerBit != 0 {
                            readerViolations.wrappingAdd(1, ordering: .relaxed)
                        }
                        dwellHere()
                        occupancy.wrappingSubtract(1, ordering: .acquiringAndReleasing)
                    }
                }
                done.signal()
            }
        }

        for _ in 0 ..< (writers + readers) {
            expectSignal(done, within: 120)
        }

        #expect(writerViolations.load(ordering: .relaxed) == 0, "a writer entered a busy lock")
        #expect(readerViolations.load(ordering: .relaxed) == 0, "a reader entered behind a writer")
        #expect(
            exitViolations.load(ordering: .relaxed) == 0,
            "the lock was busy when a writer left"
        )
        #expect(occupancy.load(ordering: .relaxed) == 0)
        #expect(lock.withReadLock { $0 } == writers * iterations)
    }
}
#endif
