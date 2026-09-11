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
// Apple's XCTest measures wall clock and CPU counters, and reports. corelibs
// XCTest, on Linux and Windows, measures wall clock alone — and passes a
// verdict: a spread of more than ten percent across the runs, once it is
// more than a tenth of a second, fails the test, with no baseline involved
// and no way to turn it off. A contended measurement on a shared runner
// exceeds that whenever the runner's other tenants do, which is what turned
// a reading into a red build. So off Apple platforms the harness keeps its
// own clock, ten runs like corelibs', and prints what corelibs would have
// printed, minus the verdict. The two are told apart once, in
// `_measureLock`, and the harness reads the same everywhere else. Nothing
// here on a platform without XCTest at all — the static Linux SDK — since
// nothing runs tests there.
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
#if canImport(XCTest)
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

/// Where each worker of a contended case leaves its result: one slot per
/// worker, written by that worker's thread alone and read once every thread
/// has finished, so that nothing is checked or counted inside the measured
/// window.
///
/// `@unchecked Sendable` on that discipline: no slot is written by two
/// threads, and the semaphore the harness joins the threads on orders every
/// write before the reads.
///
/// `@safe`, with the buffer marked `@unsafe`: every access to it is spelled
/// out below, and nothing hands the pointer out.
@safe
private final class _WorkerResults: @unchecked Sendable {
    @unsafe private let slots: UnsafeMutablePointer<(end: Int, steps: Int, turns: Int)>
    private let count: Int

    init(count: Int) {
        self.count = count
        unsafe slots = UnsafeMutablePointer<(end: Int, steps: Int, turns: Int)>
            .allocate(capacity: count)
        unsafe slots.initialize(repeating: (end: 0, steps: 0, turns: 0), count: count)
    }

    deinit {
        unsafe slots.deinitialize(count: count)
        unsafe slots.deallocate()
    }

    func record(end: Int, steps: Int, turns: Int, for worker: Int) {
        unsafe slots[worker] = (end: end, steps: steps, turns: turns)
    }

    func result(of worker: Int) -> (end: Int, steps: Int, turns: Int) {
        unsafe slots[worker]
    }
}

/// The turns a group of workers has left between them.
///
/// One atomic counter, drawn down a batch at a time. Lock-free for the
/// reason `Tally` is: every worker touches it, and a lock here would be a
/// second contended primitive inside the measured window. The batch keeps
/// the counter itself from becoming that — a worker comes back to it once
/// every `WorkShare.batch` turns, not every turn.
package final class _WorkBudget: @unchecked Sendable {
    private let remaining: Atomic<Int>

    package init(total: Int) {
        remaining = Atomic(total)
    }

    /// Claims up to `count` turns, and returns how many were left to claim:
    /// `count`, fewer at the end, or zero once the budget is spent.
    package func claim(upTo count: Int) -> Int {
        var left = remaining.load(ordering: .relaxed)
        while left > 0 {
            let claiming = min(count, left)
            let (exchanged, observed) = remaining.compareExchange(
                expected: left,
                desired: left - claiming,
                ordering: .relaxed
            )
            if exchanged {
                return claiming
            }
            left = observed
        }
        return 0
    }
}

/// One worker's share of a group's budget: `eachTurn` runs the worker's
/// body once per turn until the budget is spent.
///
/// A method taking the body rather than a sequence to iterate, and
/// inlinable, so that the loop runs on locals in the test's own module: a
/// turn of the cheapest primitive here is a few nanoseconds, and an
/// iterator's call and the exclusivity checks on its stored properties
/// cost as much again — measured, they tripled the contended `Mutex`
/// number. A class, so that the harness can read how many turns the worker
/// took once its body has returned; it is created on the worker's thread
/// and used only there.
package final class WorkShare {
    /// How many turns are claimed from the budget at once: often enough
    /// that a slow worker does not hold much back, seldom enough that the
    /// budget's counter is not contended. Claiming every turn was measured
    /// at ten times the cost of the turns themselves.
    @usableFromInline
    package static let batch = 64

    @usableFromInline
    internal let budget: _WorkBudget

    /// How many turns the worker has taken, and how many chase steps they
    /// came to.
    package private(set) var turns = 0
    package private(set) var steps = 0

    package init(of budget: _WorkBudget) {
        self.budget = budget
    }

    /// Runs `turn` once per turn claimed from the budget, until it is spent,
    /// counting `steps` chase steps for each: one, unless the body chases
    /// further and says so.
    @inlinable
    package func eachTurn(steps: Int = 1, _ turn: () -> Void) {
        var taken = 0
        while true {
            let claimed = budget.claim(upTo: Self.batch)
            if claimed == 0 {
                break
            }
            for _ in 0 ..< claimed {
                turn()
            }
            taken += claimed
        }
        _record(turns: taken, steps: taken * steps)
    }

    @usableFromInline
    internal func _record(turns: Int, steps: Int) {
        self.turns += turns
        self.steps += steps
    }
}

/// What a measured block starts and stops: XCTest's meter on Apple
/// platforms, the harness's own clock elsewhere.
package struct MeasurementClock {
    fileprivate let _start: () -> Void
    fileprivate let _stop: () -> Void

    package func start() {
        _start()
    }

    package func stop() {
        _stop()
    }
}

#if !canImport(Darwin)
/// Ten wall-clock samples and the line corelibs XCTest would print for them.
private final class _WallClock {
    private var began: DispatchTime?
    private(set) var samples: [Double] = []

    func start() {
        began = .now()
    }

    func stop() {
        guard let began else {
            return
        }
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e9)
        self.began = nil
    }

    var report: String {
        let average = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(samples.count)
        let deviation = variance.squareRoot()
        let relative = average > 0 ? deviation / average * 100 : 0
        let values = samples.map { String(format: "%.6f", $0) }.joined(separator: ", ")
        return String(
            format: "measured [Time, seconds] average: %.3f, relative standard deviation: %.3f%%, values: [%@]",
            average, relative, values
        )
    }
}
#endif

extension XCTestCase {
    /// Measures `block` with the metrics the platform has, starting and
    /// stopping on the block's say-so through the clock it is handed if
    /// `manually` is set, and around the whole block otherwise.
    ///
    /// On Apple platforms: wall clock for the contention story, and the CPU
    /// counters because instructions retired barely varies where elapsed
    /// time does. Read instructions retired, not elapsed time, for anything
    /// uncontended: it varies by a fraction of a percent between runs where
    /// the clock varies by tens. Under contention the scheduler dominates
    /// both. The metrics are built fresh per call: `XCTMetric` is not
    /// `Sendable`, so one shared array could not be a static in the first
    /// place, and a metric is free to carry state from the run it just took
    /// part in.
    ///
    /// Elsewhere: the harness's own wall clock, for the reason the file
    /// header gives; ten runs, printed in corelibs' own shape so a log reads
    /// the same either way.
    private func _measureLock(manually: Bool, _ block: (MeasurementClock) -> Void) {
        #if canImport(Darwin)
        let options = XCTMeasureOptions()
        if manually {
            options.invocationOptions = [.manuallyStart, .manuallyStop]
        }
        let clock = MeasurementClock(_start: { self.startMeasuring() }, _stop: { self.stopMeasuring() })
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            block(clock)
        }
        #else
        let wallClock = _WallClock()
        let clock = MeasurementClock(_start: { wallClock.start() }, _stop: { wallClock.stop() })
        for _ in 0 ..< 10 {
            if manually {
                block(clock)
            } else {
                wallClock.start()
                block(clock)
                wallClock.stop()
            }
        }
        print("Test Case '\(name)' \(wallClock.report)")
        #endif
    }

    /// Skips the measurement in a debug build, where an unoptimized one says
    /// nothing about anything, and under ThreadSanitizer, where Apple's
    /// XCTest measurement worker crashes in `objc_release` partway through —
    /// the correctness suites pass on the same run, and no race is reported
    /// before it. A measurement taken through an instrumented build would say
    /// nothing anyway, on any platform, so there is nothing there worth
    /// chasing that crash for.
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

    /// Runs threads over a fresh fixture, timing only the part where they are
    /// actually contending.
    ///
    /// Threads are started and parked first, then released together, so
    /// thread creation stays outside the measured window.
    ///
    /// The work is not divided up front. Each group in `groups` — readers,
    /// say, or writers — has a budget of `workers × iterations` turns that
    /// its workers draw from as they go, a batch at a time, so a worker that
    /// happens to land on a slower core takes fewer turns and the group
    /// finishes together rather than waiting on its slowest member. On a
    /// chip with more than one kind of core that is the difference between
    /// measuring the primitive and measuring which cores the scheduler
    /// picked. Workers are numbered across the groups in order, so the first
    /// group's workers come first.
    ///
    /// `work` is handed the fixture, its worker's number, and its share of
    /// the group's budget, whose `eachTurn` runs its turns; it chases the
    /// cycle once per turn, or the `steps` it tells `eachTurn`, from an
    /// index that starts at its number and returns where it ended. The
    /// harness checks each against where that many steps should have
    /// ended, and that every budget was spent, so a body whose work was
    /// optimized away fails rather than measuring nothing. `check` sees the
    /// fixture afterwards for whatever else the body has to have done.
    package func measureContention<Fixture: Sendable>(
        groups: [(workers: Int, iterations: Int)],
        makeFixture: () -> Fixture,
        work: @escaping @Sendable (Fixture, _ worker: Int, _ share: WorkShare) -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        _measureLock(manually: true) { clock in
            let fixture = makeFixture()
            let parked = DispatchSemaphore(value: 0)
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let budgets = groups.map { _WorkBudget(total: $0.workers * $0.iterations) }
            let workers = groups.reduce(0) { $0 + $1.workers }

            let results = _WorkerResults(count: workers)

            var worker = 0
            for (group, budget) in zip(groups, budgets) {
                for _ in 0 ..< group.workers {
                    let number = worker
                    let thread = Thread {
                        let share = WorkShare(of: budget)
                        parked.signal()
                        start.wait()
                        let end = work(fixture, number, share)
                        results.record(
                            end: end,
                            steps: share.steps,
                            turns: share.turns,
                            for: number
                        )
                        finished.signal()
                    }
                    thread.qualityOfService = .userInteractive
                    thread.start()
                    worker += 1
                }
            }

            for _ in 0 ..< workers {
                parked.wait()
            }

            clock.start()
            for _ in 0 ..< workers {
                start.signal()
            }
            for _ in 0 ..< workers {
                finished.wait()
            }
            clock.stop()

            var turnsTaken = 0
            for worker in 0 ..< workers {
                let (end, steps, turns) = results.result(of: worker)
                XCTAssertEqual(
                    end,
                    Chase.end(from: worker, steps: steps),
                    "worker \(worker)'s chase did not end where its steps say"
                )
                turnsTaken += turns
            }
            XCTAssertEqual(
                turnsTaken,
                groups.reduce(0) { $0 + $1.workers * $1.iterations },
                "the budgets were not spent"
            )
            check(fixture)
        }
    }

    /// `measureContention(groups:)` for the common case of one group.
    package func measureContention<Fixture: Sendable>(
        workers: Int,
        iterations: Int,
        makeFixture: () -> Fixture,
        work: @escaping @Sendable (Fixture, _ worker: Int, _ share: WorkShare) -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        measureContention(
            groups: [(workers: workers, iterations: iterations)],
            makeFixture: makeFixture,
            work: work,
            check: check
        )
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
    ///
    /// Read the single-task numbers with the executor in mind. A turn here
    /// is a take, a yield, and a release, and on Linux the yield costs
    /// according to how much the task did before it: a few hundred
    /// nanoseconds after almost nothing, several microseconds after half a
    /// microsecond of work, as the pool hands the resumed task to another
    /// thread. Measured directly, with nothing but an atomic spin before
    /// the yield, so it is the executor's and not a lock's; on macOS the
    /// cost stays flat until the work runs to microseconds. A primitive
    /// whose take and release together cross that line therefore reads as
    /// several times another's there while differing by a fraction, so
    /// compare Linux numbers between primitives only at like per-turn
    /// work, and against macOS not at all.
    package func measureTaskContention<Fixture: Sendable>(
        tasks: Int,
        iterations: Int,
        makeFixture: () -> Fixture,
        work: @escaping @Sendable (Fixture, _ task: Int) async throws -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        _measureLock(manually: false) { _ in
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
        _measureLock(manually: false) { _ in
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
