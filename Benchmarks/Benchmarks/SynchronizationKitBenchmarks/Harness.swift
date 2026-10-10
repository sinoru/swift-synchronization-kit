//
//  Harness.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

// The harness every benchmark here measures through, kept in one place so
// that a Mutex measurement and an RWLock measurement differ only in the lock.
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
// each measurement checks that the chase actually happened before it accepts
// a result, and traps if it did not: no number is better than one that means
// nothing.
//
// Every sample takes exactly as many turns as the benchmark's scaling factor
// says — a million, for the most part — so that what the harness prints,
// scaled, is the cost of one turn. The contended measurements share those
// turns out between their workers from a budget; the uncontended ones loop
// over `scaledIterations`.

import Benchmark
import Dispatch
import Foundation
import SynchronizationKit

// MARK: - The chase

/// What a measured lock protects: a permutation the readers chase, and a
/// counter the writers move.
struct ChasePayload: Sendable {
    var cycle: [Int]
    var writes = 0

    init() {
        cycle = Chase.cycle
    }

    /// `steps` steps of the chase from `index`, and where it ended.
    func chase(from index: Int, steps: Int) -> Int {
        var index = index
        for _ in 0 ..< steps {
            index = cycle[index]
        }
        return index
    }
}

/// The pointer chase every measurement runs, and where it ends.
enum Chase {
    static let slots = 1024

    /// A single cycle visiting every slot, so a chase never short-circuits
    /// into a small loop that would sit in cache.
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
    /// The cycle visits every slot once, so it repeats with period `slots`
    /// and the answer is reachable in at most that many steps however long
    /// the run was. Comparing against this is what makes the checks below
    /// say something: a chase that never moved lands on `start`, not here.
    static func end(from start: Int, steps: Int) -> Int {
        var index = start
        for _ in 0 ..< (steps % slots) {
            index = cycle[index]
        }
        return index
    }
}

// MARK: - The machine

/// How many workers a contended case runs: every core but two, so the odd
/// one out — a writer, a signaller — and the harness each have one.
let contendedWorkers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

/// Twice the cores, so most of the time the lock is handed to a thread that
/// has to be woken for it.
let oversubscribedWorkers = ProcessInfo.processInfo.activeProcessorCount * 2

/// Whether the machine is big enough for a contended result to say anything
/// about contention. A case that needs it is skipped on a smaller one.
let hasRoomToContend = ProcessInfo.processInfo.activeProcessorCount >= 4

// MARK: - Sharing the work out

/// A counter the measured blocks can add to from several threads.
///
/// Lock-free on purpose. A lock here would be a second lock inside the
/// measured window, contended by every worker at the moment they all finish —
/// noise on the same scale as the handoff being measured. A class because
/// `Atomic` is noncopyable and so cannot be captured by a measured block.
final class Tally: @unchecked Sendable {
    private let storage = Atomic<Int>(0)

    var value: Int {
        storage.load(ordering: .acquiring)
    }

    func add(_ operand: Int) {
        storage.wrappingAdd(operand, ordering: .acquiringAndReleasing)
    }
}

/// Where each worker of a contended case leaves its result: one slot per
/// worker, written by that worker alone and read once every worker has
/// finished, so that nothing is checked or counted inside the measured
/// window.
///
/// `@unchecked Sendable` on that discipline: no slot is written by two
/// workers, and the semaphore the harness joins the workers on orders every
/// write before the reads.
///
/// `@safe`, with the buffer marked `@unsafe`: every access to it is spelled
/// out below, and nothing hands the pointer out.
@safe
private final class WorkerResults: @unchecked Sendable {
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
final class WorkBudget: @unchecked Sendable {
    private let remaining: Atomic<Int>

    init(total: Int) {
        remaining = Atomic(total)
    }

    /// Claims up to `count` turns, and returns how many were left to claim:
    /// `count`, fewer at the end, or zero once the budget is spent.
    func claim(upTo count: Int) -> Int {
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
/// A method taking the body rather than a sequence to iterate, so that the
/// loop runs on locals: a turn of the cheapest primitive here is a few
/// nanoseconds, and an iterator's call and the exclusivity checks on its
/// stored properties cost as much again — measured, they tripled the
/// contended `Mutex` number. A class, so that the harness can read how many
/// turns the worker took once its body has returned; it is created on the
/// worker's thread and used only there.
final class WorkShare {
    /// How many turns are claimed from the budget at once: often enough
    /// that a slow worker does not hold much back, seldom enough that the
    /// budget's counter is not contended. Claiming every turn was measured
    /// at ten times the cost of the turns themselves.
    static let batch = 64

    /// How many batches pass between looks at the clock: a look costs tens
    /// of nanoseconds, and this spreads one over a thousand turns.
    private static let batchesBetweenLooks = 16

    private let budget: WorkBudget
    private let deadline: ContinuousClock.Instant

    /// How many turns the worker has taken, and how many chase steps they
    /// came to.
    private(set) var turns = 0
    private(set) var steps = 0

    init(of budget: WorkBudget, until deadline: ContinuousClock.Instant) {
        self.budget = budget
        self.deadline = deadline
    }

    /// Runs `turn` once per turn claimed from the budget, until it is spent
    /// or the deadline has passed, counting `steps` chase steps for each:
    /// one, unless the body chases further and says so.
    func eachTurn(steps: Int = 1, _ turn: () -> Void) {
        var taken = 0
        var batches = 0
        while true {
            let claimed = budget.claim(upTo: Self.batch)
            if claimed == 0 {
                break
            }
            for _ in 0 ..< claimed {
                turn()
            }
            taken += claimed
            batches += 1
            if batches == Self.batchesBetweenLooks {
                batches = 0
                if ContinuousClock.now >= deadline {
                    break
                }
            }
        }
        turns += taken
        self.steps += taken * steps
    }
}

// MARK: - The threads

/// The threads the contended cases run their workers on, started once and
/// kept for the whole run.
///
/// Kept rather than made afresh for every sample because of what happens
/// when one ends. The harness counts allocations through an interposer that
/// keeps a record per thread, set up the first time the thread frees; a
/// thread exiting frees its thread-specific data from inside the threading
/// library's own teardown, and a thread whose first free that is sets the
/// record up there, where the allocator traps. A pool never exits a thread.
/// It also keeps thread creation out of a sample altogether, parked or not.
final class WorkerPool: @unchecked Sendable {
    /// One thread and the job it is waiting for. The job is written before
    /// the semaphore is signalled and read after it is waited on, which is
    /// what makes the unchecked conformance right. The thread takes the job
    /// out of the slot before running it, not after: the harness hands the
    /// next job over as soon as the running one has signalled that it is
    /// done, which is before it has returned, and a slot cleared after the
    /// return would lose it.
    private final class Worker: @unchecked Sendable {
        private let wake = DispatchSemaphore(value: 0)
        private var job: (@Sendable () -> Void)?

        init() {
            let thread = Thread { [self] in
                while true {
                    wake.wait()
                    let job = self.job
                    self.job = nil
                    job?()
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func run(_ job: @escaping @Sendable () -> Void) {
            self.job = job
            wake.signal()
        }
    }

    /// Enough for the widest case: the oversubscribed readers with a
    /// writer, or the contended workers with four.
    static let shared = WorkerPool(size: oversubscribedWorkers + 4)

    private let workers: [Worker]

    private init(size: Int) {
        workers = (0 ..< size).map { _ in Worker() }
    }

    /// Runs `job` on the thread numbered `worker`.
    func run(on worker: Int, _ job: @escaping @Sendable () -> Void) {
        precondition(worker < workers.count, "more workers than the pool has threads")
        workers[worker].run(job)
    }
}

// MARK: - Measuring

extension Benchmark {
    /// How many turns one sample takes, which is the scaling factor so that
    /// the scaled output reads per turn.
    var turnsPerSample: Int {
        configuration.scalingFactor.rawValue
    }

    /// Runs one thread over a fresh fixture, timing only the work.
    ///
    /// `work` is handed the fixture and the turns to take; it chases the
    /// cycle once per turn from index zero and returns where it ended, which
    /// the harness checks against where that many steps should have ended.
    /// `check` sees the fixture afterwards for whatever else the body has to
    /// have done.
    func measureUncontended<Fixture: Sendable>(
        makeFixture: () -> Fixture,
        work: (Fixture, _ turns: Range<Int>) -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        let fixture = makeFixture()
        startMeasurement()
        let end = work(fixture, scaledIterations)
        stopMeasurement()
        precondition(end == Chase.end(from: 0, steps: turnsPerSample), "the chase did not advance")
        check(fixture)
    }

    /// Runs threads over a fresh fixture, timing only the part where they are
    /// actually contending.
    ///
    /// The workers are parked on the pool's threads first, then released
    /// together, so nothing but the work is inside the measured window.
    ///
    /// The sample's turns are shared out between the groups in `groups` —
    /// readers, say, and writers — in proportion to their worker counts, and
    /// the work is not divided up front within a group: its workers draw
    /// from the group's budget as they go, a batch at a time, so a worker
    /// that happens to land on a slower core takes fewer turns and the group
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
    /// optimized away traps rather than measuring nothing. `check` sees the
    /// fixture afterwards, with each group's budget, for whatever else the
    /// body has to have done.
    ///
    /// The sample is run in stretches of at most `stretch`, every worker
    /// parked between one and the next, and `work` is called once per
    /// stretch. The budgets carry over, the measurement runs through, and
    /// a sample that finishes inside one stretch — most of them — never
    /// pauses at all.
    func measureContention<Fixture: Sendable>(
        groups: [Int],
        makeFixture: () -> Fixture,
        work: @escaping @Sendable (Fixture, _ worker: Int, _ share: WorkShare) -> Int,
        check: (Fixture, _ budgets: [Int]) -> Void = { _, _ in }
    ) {
        let fixture = makeFixture()
        let parked = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let workers = groups.reduce(0, +)
        let totals = budgetTotals(for: groups)
        let budgets = totals.map(WorkBudget.init)
        var stretches: [WorkerResults] = []
        var turnsTaken = 0

        startMeasurement()
        repeat {
            let results = WorkerResults(count: workers)
            let deadline = ContinuousClock.now + Self.stretch

            var worker = 0
            for (count, budget) in zip(groups, budgets) {
                for _ in 0 ..< count {
                    let number = worker
                    WorkerPool.shared.run(on: number) {
                        let share = WorkShare(of: budget, until: deadline)
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
                    worker += 1
                }
            }

            for _ in 0 ..< workers {
                parked.wait()
            }
            for _ in 0 ..< workers {
                start.signal()
            }
            for _ in 0 ..< workers {
                finished.wait()
            }

            for worker in 0 ..< workers {
                turnsTaken += results.result(of: worker).turns
            }
            stretches.append(results)
        } while turnsTaken < turnsPerSample
        stopMeasurement()

        for results in stretches {
            for worker in 0 ..< workers {
                let (end, steps, _) = results.result(of: worker)
                precondition(
                    end == Chase.end(from: worker, steps: steps),
                    "worker \(worker)'s chase did not end where its steps say"
                )
            }
        }
        precondition(turnsTaken == turnsPerSample, "the budgets were not spent")
        check(fixture, totals)
    }

    /// The longest the workers run between pauses.
    private static let stretch: Duration = .milliseconds(100)

    /// `measureContention(groups:)` for the common case of one group.
    func measureContention<Fixture: Sendable>(
        workers: Int,
        makeFixture: () -> Fixture,
        work: @escaping @Sendable (Fixture, _ worker: Int, _ share: WorkShare) -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        measureContention(groups: [workers], makeFixture: makeFixture, work: work) { fixture, _ in
            check(fixture)
        }
    }

    /// The sample's turns shared out between `groups` in proportion to their
    /// worker counts, the remainder going to the last.
    private func budgetTotals(for groups: [Int]) -> [Int] {
        let workers = groups.reduce(0, +)
        var budgets = groups.map { turnsPerSample * $0 / workers }
        budgets[budgets.count - 1] += turnsPerSample - budgets.reduce(0, +)
        return budgets
    }

    /// Runs `tasks` tasks over a fresh fixture, for the asynchronous
    /// primitives.
    ///
    /// Task creation is measured with the rest: there is no cheap way to
    /// park a crowd of tasks and release them together, and a task costs
    /// microseconds against the thousands of handoffs each one then makes.
    /// Detached at `.userInitiated` for the same reason the threads are
    /// pinned.
    ///
    /// `work` chases the cycle once per iteration from its task's number
    /// and returns where it ended, and the harness checks each task against
    /// where `iterations` steps should have ended — or where `steps` says,
    /// for a case in which some tasks chase less. `check` sees the fixture
    /// afterwards.
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
    func measureTaskContention<Fixture: Sendable>(
        tasks: Int,
        iterations: Int,
        makeFixture: () -> Fixture,
        steps: (_ task: Int) -> Int? = { _ in nil },
        work: @escaping @Sendable (Fixture, _ task: Int) async throws -> Int,
        check: (Fixture) -> Void = { _ in }
    ) {
        let fixture = makeFixture()
        let finished = DispatchSemaphore(value: 0)
        let results = WorkerResults(count: tasks)
        let failed = Tally()

        startMeasurement()
        for task in 0 ..< tasks {
            Task.detached(priority: .userInitiated) {
                do {
                    let end = try await work(fixture, task)
                    results.record(end: end, steps: 0, turns: 0, for: task)
                } catch {
                    failed.add(1)
                }
                finished.signal()
            }
        }
        for _ in 0 ..< tasks {
            finished.wait()
        }
        stopMeasurement()

        precondition(failed.value == 0, "a task threw")
        for task in 0 ..< tasks {
            let expected = Chase.end(from: task, steps: steps(task) ?? iterations)
            precondition(
                results.result(of: task).end == expected,
                "task \(task)'s chase did not advance"
            )
        }
        check(fixture)
    }
}

// MARK: - A lock taken around one step

/// A lock the harness can measure as a plain lock: one write and one step of
/// the chase under it. One protocol so that one set of cases serves every
/// implementation — this package's `Mutex` and the standard library's, a
/// semaphore with a count of one, `DispatchSemaphore` — and every adopter is
/// final, so the cases are specialized for each and no measured turn is
/// dispatched through it.
protocol MeasuredLock: Sendable {
    init()

    /// One write and one step of the chase from `index`, under the lock.
    func step(from index: Int) -> Int

    /// How many writes have happened, read under the lock.
    var writes: Int { get }
}

/// Registers the uncontended case for `Lock`, and the contended ones if
/// `oversubscribed` lists any, under `name` — "Mutex contended", say — with
/// `implementation` appended where the lock is a comparison rather than the
/// primitive itself.
func registerLockCases<Lock: MeasuredLock>(
    _: Lock.Type,
    named name: String,
    implementation: String? = nil,
    contended: [(scenario: String, workers: Int)]
) {
    let suffix = implementation.map { ", \($0)" } ?? ""

    Benchmark("\(name) uncontended\(suffix)", configuration: .uncontended) { benchmark in
        benchmark.measureUncontended(makeFixture: Lock.init) { lock, turns in
            var index = 0
            for _ in turns {
                index = lock.step(from: index)
            }
            return index
        } check: { lock in
            precondition(lock.writes == benchmark.turnsPerSample, "the workload did not run")
        }
    }

    for (scenario, workers) in contended {
        Benchmark("\(name) \(scenario)\(suffix)", configuration: .contended) { benchmark in
            benchmark.measureContention(
                workers: workers,
                makeFixture: Lock.init
            ) { lock, worker, share in
                var index = worker
                share.eachTurn {
                    index = lock.step(from: index)
                }
                return index
            } check: { lock in
                precondition(lock.writes == benchmark.turnsPerSample, "the workload did not run")
            }
        }
    }
}

// MARK: - Helpers the asynchronous cases share

/// A one-shot signal: `wait()` suspends until `open()` has been called, and
/// every task waiting at that moment resumes.
///
/// Built on the package's own `Mutex` and a list of continuations rather
/// than an `AsyncStream`, which is single-consumer by contract and shares
/// only by accident on older runtimes.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init() {}

    /// Opens the gate and resumes every waiter. Idempotent: a second call
    /// finds nobody waiting and changes nothing.
    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends until the gate is open. Returns at once if it already is.
    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen {
                    state.waiters.append(continuation)
                }
                return state.isOpen
            }
            if isOpen {
                continuation.resume()
            }
        }
    }
}

/// A seeded generator, so that a sample shuffles the same way every time.
///
/// SplitMix64: a 64-bit state, one addition, three xor-shift-multiply
/// rounds. Not a quality the benchmarks depend on, only a sequence they can
/// repeat.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
