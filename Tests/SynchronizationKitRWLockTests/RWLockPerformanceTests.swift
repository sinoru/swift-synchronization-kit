//
//  RWLockPerformanceTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Dispatch
import Foundation
import SynchronizationKitAtomic
import SynchronizationKitTestSupport
import XCTest

@testable import SynchronizationKitRWLock

/// What `RWLock` costs, on whichever Darwin backend the running OS provides.
///
/// XCTest rather than the testing library: measurement has no equivalent there,
/// and the two coexist in one target. The measurements print under plain
/// `swift test`, so none of this needs Xcode — only baselines do, and those live
/// in a scheme or test plan that this package has no place to keep. Read the
/// numbers; nothing here fails on a regression.
///
/// Read instructions retired, not elapsed time, for anything uncontended: it
/// varies by a fraction of a percent between runs where the clock varies by
/// tens. Under contention the scheduler dominates both.
///
/// Every case is skipped in a debug build, where an unoptimized measurement says
/// nothing about anything, so an ordinary `swift test` is untouched and no
/// environment variable has to be remembered. Measure in release:
///
///     swift test -c release -Xswiftc -enable-testing \
///         --filter RWLockPerformanceTests
///
/// `-enable-testing` is what the rest of the target's `@testable` imports need
/// in release; it is not what ships. It makes internal symbols externally
/// visible, which costs the optimizer some of what it may assume, so read these
/// as a self-consistent series rather than as the cost of a release build.
///
/// Two ways to measure a lock badly, both of which this repository has already
/// been caught by, and what is done about each:
///
/// - Nothing forces one critical section to finish before the next begins, so
///   the processor overlaps them and the work inside stops costing anything.
///   Every section here follows a pointer chase — a single cycle through the
///   protected array, each load depending on the one before — which the
///   processor cannot run ahead of.
/// - Threads left to the scheduler land on efficiency cores and the spread
///   swallows the effect. Every thread here is pinned to `.userInteractive`.
///
/// A benchmark whose work gets optimized away reports excellent numbers, so each
/// case asserts that the work actually happened before it accepts a measurement.
final class RWLockPerformanceTests: XCTestCase {
    // MARK: - Fixtures

    /// What the lock protects: a permutation the readers chase, and a counter
    /// the writers move.
    struct Payload {
        var cycle: [Int]
        var writes = 0
    }

    /// A reference to hold the lock by.
    ///
    /// Capturing a noncopyable value in a measured block currently fails to
    /// compile — "copy of noncopyable typed value", reported by the compiler as
    /// its own bug — so the block captures this instead and reaches the lock
    /// through it.
    final class LockBox: @unchecked Sendable {
        let lock: RWLock<Payload>

        init(cycle: [Int]) {
            lock = RWLock(Payload(cycle: cycle))
        }
    }

    static let slots = 1024

    /// A single cycle visiting every slot, so a chase never short-circuits into
    /// a small loop that would sit in cache.
    static let cycle: [Int] = {
        var order = Array(1 ..< slots)
        var state = UInt64(0x2545_F491_4F6C_DD1D)
        for position in stride(from: order.count - 1, to: 0, by: -1) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            order.swapAt(position, Int(state % UInt64(position + 1)))
        }

        var cycle = [Int](repeating: 0, count: slots)
        var previous = 0
        for next in order {
            cycle[previous] = next
            previous = next
        }
        cycle[previous] = 0
        return cycle
    }()

    /// Where following the cycle `steps` times from `start` ends up.
    ///
    /// The cycle visits every slot once, so it repeats with period `slots` and
    /// the answer is reachable in at most that many steps however long the run
    /// was. Comparing against this is what makes the checks below say something:
    /// a chase that never moved lands on `start`, not here.
    static func chaseEnd(from start: Int, steps: Int) -> Int {
        var index = start
        for _ in 0 ..< (steps % slots) {
            index = cycle[index]
        }
        return index
    }

    /// Wall clock for the contention story, and the CPU counters because
    /// instructions retired barely varies where elapsed time does.
    ///
    /// Built fresh per call: `XCTMetric` is not `Sendable`, so one shared array
    /// could not be a static in the first place, and a metric is free to carry
    /// state from the run it just took part in.
    private var metrics: [any XCTMetric] {
        [XCTClockMetric(), XCTCPUMetric()]
    }

    override func setUpWithError() throws {
        #if DEBUG
        throw XCTSkip("Measurements only mean something optimized; build for release.")
        #else
        // XCTest's own measurement worker crashes in `objc_release` partway
        // through a sanitized run — the correctness suites pass on the same
        // run, and no race is reported before it. A measurement taken through
        // an instrumented build would say nothing anyway, so there is nothing
        // here worth chasing that crash for.
        try XCTSkipIf(
            threadSanitizerIsLoaded,
            """
            XCTest cannot measure under ThreadSanitizer, and a measurement \
            taken there would not mean anything.
            """
        )
        #endif
    }

    /// Skips a contended case on a machine too small for the result to say
    /// anything about contention.
    private func requireRoomToContend() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.activeProcessorCount >= 4,
            "Too few cores for a contention measurement to mean anything."
        )
    }

    // MARK: - Harness

    /// Runs one reader and writer mix over a fresh lock, timing only the part
    /// where the threads are actually contending.
    ///
    /// Threads are started and parked first, then released together, so thread
    /// creation stays outside the measured window.
    private func measureContention(
        readers: Int,
        writers: Int,
        iterations: Int
    ) {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]

        measure(metrics: metrics, options: options) {
            let box = LockBox(cycle: Self.cycle)
            let parked = DispatchSemaphore(value: 0)
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let chased = Tally()

            for worker in 0 ..< (readers + writers) {
                let isWriter = worker < writers
                let thread = Thread {
                    var index = worker
                    parked.signal()
                    start.wait()

                    if isWriter {
                        for _ in 0 ..< iterations {
                            box.lock.withWriteLock {
                                $0.writes &+= 1
                                index = $0.cycle[index]
                            }
                        }
                    } else {
                        for _ in 0 ..< iterations {
                            index = box.lock.withReadLock { $0.cycle[index] }
                        }
                    }

                    chased.add(index)
                    finished.signal()
                }
                thread.qualityOfService = .userInteractive
                thread.start()
            }

            for _ in 0 ..< (readers + writers) {
                parked.wait()
            }

            self.startMeasuring()
            for _ in 0 ..< (readers + writers) {
                start.signal()
            }
            for _ in 0 ..< (readers + writers) {
                finished.wait()
            }
            self.stopMeasuring()

            // Both halves have to have run, or the measurement is of nothing.
            XCTAssertEqual(
                box.lock.withReadLock { $0.writes },
                writers * iterations,
                "the write side did not run"
            )
            let expectedChase = (0 ..< (readers + writers))
                .reduce(0) { $0 + Self.chaseEnd(from: $1, steps: iterations) }
            XCTAssertEqual(chased.value, expectedChase, "the read side did not run")
        }
    }

    /// Runs one thread over a fresh lock. Nothing to park, so the whole block is
    /// measured.
    private func measureUncontended(writing: Bool, iterations: Int) {
        measure(metrics: metrics) {
            let box = LockBox(cycle: Self.cycle)
            var index = 0

            if writing {
                for _ in 0 ..< iterations {
                    box.lock.withWriteLock {
                        $0.writes &+= 1
                        index = $0.cycle[index]
                    }
                }
            } else {
                for _ in 0 ..< iterations {
                    index = box.lock.withReadLock { $0.cycle[index] }
                }
            }

            XCTAssertEqual(
                box.lock.withReadLock { $0.writes },
                writing ? iterations : 0,
                "the workload did not run"
            )
            XCTAssertEqual(
                index,
                Self.chaseEnd(from: 0, steps: iterations),
                "the chase did not advance"
            )
        }
    }

    private var contendedReaders: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    // MARK: - Uncontended

    func testUncontendedReads() {
        measureUncontended(writing: false, iterations: 500_000)
    }

    func testUncontendedWrites() {
        measureUncontended(writing: true, iterations: 500_000)
    }

    // MARK: - Readers against a trickle of writes

    func testReaderScaling() throws {
        try requireRoomToContend()
        measureContention(readers: contendedReaders, writers: 1, iterations: 50_000)
    }

    // MARK: - A writer releasing a crowd

    // Deliberately more readers than cores, so a departing writer has a queue to
    // hand the lock to. This is where releasing every one of them at once tells
    // against one system call each.

    func testWriterHandoff() throws {
        try requireRoomToContend()
        measureContention(
            readers: ProcessInfo.processInfo.activeProcessorCount * 2,
            writers: 1,
            iterations: 4_000
        )
    }

    // MARK: - Mixed

    func testMixedContention() throws {
        try requireRoomToContend()
        measureContention(readers: contendedReaders, writers: 4, iterations: 20_000)
    }
}

/// A counter the measured blocks can add to from several threads.
///
/// Lock-free on purpose. An `NSLock` here would put a second lock inside the
/// measured window, contended by every worker at the moment they all finish —
/// noise on the same scale as the handoff being measured. The class exists only
/// because `Atomic` is noncopyable and so cannot be captured by a measured
/// block, for the same reason `LockBox` cannot be.
private final class Tally: @unchecked Sendable {
    private let storage = Atomic<Int>(0)

    var value: Int {
        storage.load(ordering: .acquiring)
    }

    func add(_ operand: Int) {
        storage.wrappingAdd(operand, ordering: .acquiringAndReleasing)
    }
}
#endif
