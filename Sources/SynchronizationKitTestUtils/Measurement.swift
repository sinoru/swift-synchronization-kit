//
//  Measurement.swift
//  SynchronizationKit
//

// The harness the performance suites measure through, kept in one place so
// that a Mutex measurement and an RWLock measurement differ only in the lock.
//
// XCTest rather than the testing library: measurement has no equivalent
// there, and the two coexist in one target. The measurements print under
// plain `swift test`, so none of this needs Xcode — only baselines do, and
// those live in a scheme or test plan that this package has no place to
// keep. Read the numbers; nothing here fails on a regression.
//
// Darwin only: the metrics are Apple's XCTest's, and corelibs XCTest has
// `measure` without them.
//
// Two ways to measure a lock badly, both of which this repository has already
// been caught by, and what is done about each:
//
// - Nothing forces one critical section to finish before the next begins, so
//   the processor overlaps them and the work inside stops costing anything.
//   Every section measured through this follows a pointer chase — a single
//   cycle through a protected array, each load depending on the one before —
//   which the processor cannot run ahead of.
// - Threads left to the scheduler land on efficiency cores and the spread
//   swallows the effect. Every thread here is pinned to `.userInteractive`.
//
// A benchmark whose work gets optimized away reports excellent numbers, so
// each measurement asserts that the chase actually happened before it accepts
// a result.
#if canImport(Darwin) && canImport(XCTest)
import Dispatch
import Foundation
import SynchronizationKitAtomic
package import XCTest

/// What a measured lock protects: a permutation the readers chase, and a
/// counter the writers move.
package struct ChasePayload: Sendable {
    package var cycle: [Int]
    package var writes = 0

    package init() {
        cycle = Chase.cycle
    }
}

/// The pointer chase every measurement runs, and where it ends.
package enum Chase {
    package static let slots = 1024

    /// A single cycle visiting every slot, so a chase never short-circuits
    /// into a small loop that would sit in cache.
    package static let cycle: [Int] = {
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
    /// The cycle visits every slot once, so it repeats with period `slots`
    /// and the answer is reachable in at most that many steps however long
    /// the run was. Comparing against this is what makes the checks below
    /// say something: a chase that never moved lands on `start`, not here.
    package static func end(from start: Int, steps: Int) -> Int {
        var index = start
        for _ in 0 ..< (steps % slots) {
            index = cycle[index]
        }
        return index
    }
}

/// A counter the measured blocks can add to from several threads.
///
/// Lock-free on purpose. An `NSLock` here would put a second lock inside the
/// measured window, contended by every worker at the moment they all finish —
/// noise on the same scale as the handoff being measured. A class because
/// `Atomic` is noncopyable and so cannot be captured by a measured block.
private final class Tally: @unchecked Sendable {
    private let storage = Atomic<Int>(0)

    var value: Int {
        storage.load(ordering: .acquiring)
    }

    func add(_ operand: Int) {
        storage.wrappingAdd(operand, ordering: .acquiringAndReleasing)
    }
}

extension XCTestCase {
    /// Wall clock for the contention story, and the CPU counters because
    /// instructions retired barely varies where elapsed time does.
    ///
    /// Read instructions retired, not elapsed time, for anything
    /// uncontended: it varies by a fraction of a percent between runs where
    /// the clock varies by tens. Under contention the scheduler dominates
    /// both.
    ///
    /// Built fresh per call: `XCTMetric` is not `Sendable`, so one shared
    /// array could not be a static in the first place, and a metric is free
    /// to carry state from the run it just took part in.
    package var lockMetrics: [any XCTMetric] {
        [XCTClockMetric(), XCTCPUMetric()]
    }

    /// Skips the measurement in a debug build, where an unoptimized one says
    /// nothing about anything, and under ThreadSanitizer, where XCTest's own
    /// measurement worker crashes in `objc_release` partway through — the
    /// correctness suites pass on the same run, and no race is reported
    /// before it. A measurement taken through an instrumented build would say
    /// nothing anyway, so there is nothing there worth chasing that crash for.
    package func skipUnlessMeasurable() throws {
        #if DEBUG
        throw XCTSkip("Measurements only mean something optimized; build for release.")
        #else
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
    package func skipUnlessRoomToContend() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.activeProcessorCount >= 4,
            "Too few cores for a contention measurement to mean anything."
        )
    }

    /// Runs `workers` threads over a fresh fixture, timing only the part
    /// where they are actually contending.
    ///
    /// Threads are started and parked first, then released together, so
    /// thread creation stays outside the measured window.
    ///
    /// `work` is handed the fixture and its worker's number, chases the
    /// cycle once per iteration from an index that starts at that number,
    /// and returns where it ended; the harness checks the sum of those
    /// against where the chase should have ended, so a body whose work was
    /// optimized away fails rather than measuring nothing. `check` sees the
    /// fixture afterwards for whatever else the body has to have done.
    package func measureContention<Fixture: Sendable>(
        workers: Int,
        iterations: Int,
        makeFixture: () -> Fixture,
        work: @escaping @Sendable (Fixture, _ worker: Int) -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]

        measure(metrics: lockMetrics, options: options) {
            let fixture = makeFixture()
            let parked = DispatchSemaphore(value: 0)
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let chased = Tally()

            for worker in 0 ..< workers {
                let thread = Thread {
                    parked.signal()
                    start.wait()
                    chased.add(work(fixture, worker))
                    finished.signal()
                }
                thread.qualityOfService = .userInteractive
                thread.start()
            }

            for _ in 0 ..< workers {
                parked.wait()
            }

            self.startMeasuring()
            for _ in 0 ..< workers {
                start.signal()
            }
            for _ in 0 ..< workers {
                finished.wait()
            }
            self.stopMeasuring()

            let expectedChase = (0 ..< workers)
                .reduce(0) { $0 + Chase.end(from: $1, steps: iterations) }
            XCTAssertEqual(chased.value, expectedChase, "the chase did not advance")
            check(fixture)
        }
    }

    /// Runs `tasks` tasks over a fresh fixture, for the asynchronous
    /// primitives.
    ///
    /// The whole block is measured, task creation included: there is no
    /// cheap way to park a crowd of tasks and release them together, and a
    /// task costs microseconds against the tens of thousands of handoffs
    /// each one then makes. Detached at `.userInitiated` for the same reason
    /// the threads are pinned.
    ///
    /// `work` is checked as for `measureContention`: it chases the cycle
    /// once per iteration from its task's number, and the sum of where the
    /// chases ended has to be what the cycle says.
    package func measureTaskContention<Fixture: Sendable>(
        tasks: Int,
        iterations: Int,
        makeFixture: () -> Fixture,
        work: @escaping @Sendable (Fixture, _ task: Int) async throws -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        measure(metrics: lockMetrics) {
            let fixture = makeFixture()
            let finished = DispatchSemaphore(value: 0)
            let chased = Tally()
            let failed = Tally()

            for task in 0 ..< tasks {
                Task.detached(priority: .userInitiated) {
                    do {
                        chased.add(try await work(fixture, task))
                    } catch {
                        failed.add(1)
                    }
                    finished.signal()
                }
            }
            for _ in 0 ..< tasks {
                finished.wait()
            }

            let expectedChase = (0 ..< tasks)
                .reduce(0) { $0 + Chase.end(from: $1, steps: iterations) }
            XCTAssertEqual(failed.value, 0, "a task threw")
            XCTAssertEqual(chased.value, expectedChase, "the chase did not advance")
            check(fixture)
        }
    }

    /// Runs one thread over a fresh fixture. Nothing to park, so the whole
    /// block is measured.
    ///
    /// `work` chases the cycle once per iteration from index zero and
    /// returns where it ended, as for `measureContention`.
    package func measureUncontended<Fixture: Sendable>(
        iterations: Int,
        makeFixture: () -> Fixture,
        work: (Fixture) -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        measure(metrics: lockMetrics) {
            let fixture = makeFixture()
            XCTAssertEqual(
                work(fixture),
                Chase.end(from: 0, steps: iterations),
                "the chase did not advance"
            )
            check(fixture)
        }
    }

    /// How many workers a contended case runs: every core but two, so the
    /// odd one out — a writer, a signaller — and the harness each have one.
    package var contendedWorkers: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    }
}
#endif
