//
//  AsyncSemaphoreBenchmarks.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

import Benchmark
import Dispatch
import SynchronizationKit

// What `AsyncSemaphore` costs: the uncontended take, and the handoff through
// the wait queue as the queue gets longer.
//
// The semaphore is used as a lock — a count of one, taken around the chase
// and a suspension — so the numbers sit beside `AsyncMutex`'s, which differs
// from this in holding a value and in escalating its holder.

/// The semaphore and what it guards, held by reference; `MutexBox` says why.
/// The payload is guarded by the semaphore, which is what makes the
/// unchecked conformance right.
private final class AsyncSemaphoreBox: MeasuredLock, @unchecked Sendable {
    let semaphore = AsyncSemaphore(value: 1)
    private var payload = ChasePayload()

    /// The blocking `wait()`, for the thread case.
    func step(from index: Int) -> Int {
        semaphore.wait()
        payload.writes &+= 1
        let end = payload.cycle[index]
        semaphore.signal()
        return end
    }

    /// One write and one step of the chase from `index`, with a suspension
    /// inside the semaphore.
    func stepAndYield(from index: Int) async throws -> Int {
        try await semaphore.wait()
        payload.writes &+= 1
        let end = payload.cycle[index]
        await Task.yield()
        semaphore.signal()
        return end
    }

    var writes: Int {
        semaphore.wait()
        let writes = payload.writes
        semaphore.signal()
        return writes
    }
}

private func registerHandoff(_ scenario: String, tasks: Int, iterations: Int) {
    Benchmark("AsyncSemaphore \(scenario)", configuration: .handoff) { benchmark in
        precondition(tasks * iterations == benchmark.turnsPerSample)
        benchmark.measureTaskContention(
            tasks: tasks,
            iterations: iterations,
            makeFixture: AsyncSemaphoreBox.init
        ) { box, task in
            var index = task
            for _ in 0 ..< iterations {
                index = try await box.stepAndYield(from: index)
            }
            return index
        } check: { box in
            precondition(box.writes == benchmark.turnsPerSample, "the workload did not run")
        }
    }
}

/// Every task but the first waits on a count that is never raised, so
/// nothing it waits for can arrive; the first cancels them once they are
/// all queued, in a random order so that each departure is from somewhere
/// in the middle, and the round repeats. Every `wait()` must throw, and a
/// waiter moves its chase only when its child's did, so a child that
/// returned instead fails the chase check.
///
/// A waiter announces its child just before the child waits, and no
/// cancellation goes out until every waiter has announced. The queue itself
/// is not visible from outside the package, so a child announced but not
/// yet queued when its cancellation lands — a window of a few instructions
/// on another thread — is cancelled on arrival rather than from the queue;
/// its `wait()` throws all the same, and the chase check holds.
///
/// The handles a round cancels are collected under a lock and taken out of
/// it before the cancellations go out. A waiter registers its next child
/// only after the previous one has been cancelled and awaited, so the
/// registry fills to the waiter count exactly once per round.
private func registerCancellation(waiters: Int, rounds: Int) {
    final class Fixture: Sendable {
        let semaphore = AsyncSemaphore(value: 0)
        let handles = Mutex<[Task<Void, any Error>]>([])
        let announced = Mutex<Int>(0)
    }
    // A turn is one cancellation, so the sample is `waiters × rounds` of
    // them: a thousand, over a queue long enough to be a long queue.
    var configuration = Benchmark.Configuration.handoff
    configuration.scalingFactor = .kilo
    Benchmark(
        "AsyncSemaphore cancellation in long queue",
        configuration: configuration
    ) { benchmark in
        precondition(waiters * rounds == benchmark.turnsPerSample)
        benchmark.measureTaskContention(
            tasks: waiters + 1,
            iterations: rounds,
            makeFixture: Fixture.init
        ) { fixture, task in
            var index = task
            if task == 0 {
                var generator = SplitMix64(seed: 0x5EED)
                for _ in 0 ..< rounds {
                    var handles: [Task<Void, any Error>] = []
                    while true {
                        if fixture.announced.withLock({ $0 == waiters }) {
                            handles = fixture.handles.withLock { $0.count == waiters ? $0 : [] }
                        }
                        if !handles.isEmpty {
                            break
                        }
                        await Task.yield()
                    }
                    fixture.handles.withLock { $0.removeAll(keepingCapacity: true) }
                    fixture.announced.withLock { $0 = 0 }
                    handles.shuffle(using: &generator)
                    for handle in handles {
                        handle.cancel()
                    }
                    index = Chase.cycle[index]
                }
            } else {
                for _ in 0 ..< rounds {
                    let child = Task { @Sendable in
                        fixture.announced.withLock { $0 += 1 }
                        try await fixture.semaphore.wait()
                    }
                    fixture.handles.withLock { $0.append(child) }
                    do {
                        try await child.value
                    } catch is CancellationError {
                        index = Chase.cycle[index]
                    }
                }
            }
            return index
        }
    }
}

/// Two tasks at the harness's priority hand the count back and forth
/// through a queue of `lows` waiters at low priority, which are served only
/// at a signal that finds neither of the two queued. Each handoff to one of
/// the two is what the queue does to place a high-priority arrival among
/// the low ones and to let it go, which is what would grow with `lows` if
/// the queue walked to find either.
///
/// The low waiters are detached tasks of their own, since the harness runs
/// every worker at one priority. Each remaining worker spawns one and
/// returns without awaiting it — awaiting a task raises it to the awaiter's
/// priority, the runtime's doing — and a filler takes one turn and spawns
/// its successor rather than looping: a semaphore escalates nobody, but the
/// mutex's does, and the two measure alike. A filler holds nothing it could
/// chase over, so its worker takes no steps.
///
/// Once the two are done, each filler's next turn is its last, and the last
/// of them opens a gate the two wait at, so no filler outlives the sample
/// into the next. The drain — one turn per filler — is timed with the rest,
/// the same amount every sample.
private func registerPriorityHandoff(lows: Int, iterations: Int) {
    final class Fixture: Sendable {
        let semaphore = AsyncSemaphore(value: 1)
        let finished = Mutex<Int>(0)
        let fillers: Mutex<Int>
        let drained = Gate()
        let holds = Atomic<Int>(0)

        init(lows: Int) {
            fillers = Mutex(lows)
        }
    }
    /// One turn at low priority, then a fresh filler in its place, or one
    /// fewer once the two high tasks are done. A filler is never reused:
    /// where the OS escalates a holder, one that held while a high task
    /// queued was raised to that task's priority and stays there, so its
    /// next turn would be a high-priority arrival.
    @Sendable func fill(_ fixture: Fixture) {
        // The task is deliberately neither awaited nor kept: awaiting it
        // would raise it to the awaiter's priority, and the fixture's
        // flags are how the fillers end.
        _ = Task.detached(priority: .low) {
            try await fixture.semaphore.wait()
            await Task.yield()
            fixture.semaphore.signal()
            if fixture.finished.withLock({ $0 < 2 }) {
                fill(fixture)
            } else if fixture.fillers.withLock({ $0 -= 1; return $0 == 0 }) {
                fixture.drained.open()
            }
        }
    }
    Benchmark(
        "AsyncSemaphore high priority among low waiters",
        configuration: .handoff
    ) { benchmark in
        precondition(2 * iterations == benchmark.turnsPerSample)
        benchmark.measureTaskContention(
            tasks: lows + 2,
            iterations: iterations,
            makeFixture: { Fixture(lows: lows) },
            steps: { $0 < 2 ? nil : 0 }
        ) { fixture, task in
            var index = task
            if task < 2 {
                for _ in 0 ..< iterations {
                    try await fixture.semaphore.wait()
                    index = Chase.cycle[index]
                    fixture.holds.wrappingAdd(1, ordering: .relaxed)
                    await Task.yield()
                    fixture.semaphore.signal()
                }
                fixture.finished.withLock { $0 += 1 }
                await fixture.drained.wait()
            } else {
                fill(fixture)
            }
            return index
        } check: { fixture in
            precondition(
                fixture.holds.load(ordering: .relaxed) == benchmark.turnsPerSample,
                "the workload did not run"
            )
        }
    }
}

func registerAsyncSemaphoreBenchmarks() {
    for (scenario, tasks, iterations) in queueLengths {
        registerHandoff(scenario, tasks: tasks, iterations: iterations)
    }

    // The other thing a queue of this length has to do in constant time.
    registerCancellation(waiters: 500, rounds: 2)

    // And the third: a high-priority arrival placed, and served, ahead of a
    // long queue at low priority.
    registerPriorityHandoff(lows: 512, iterations: 500_000)

    // The blocking `wait()`, contended by threads the way `Semaphore` is in
    // its own cases. The two numbers are not the same measurement, and the
    // gap between them — several times over — is not overhead in the queue.
    // Measured, it is a context switch per handoff: this semaphore hands the
    // count to the waiter at the head of the queue, so every signal moves
    // the work to another thread, where `Semaphore` only raises the count,
    // and the thread that just signalled takes it back before the one it
    // woke has run. That barging is what its number is made of — a few
    // thousand switches across a million handoffs, against one or two for
    // each of them here — and giving it up is what the no-overtaking and
    // priority guarantees cost. Folding the slow path's two critical
    // sections into one was tried and moved nothing.
    Benchmark("AsyncSemaphore contended threads", configuration: .contended) { benchmark in
        benchmark.measureContention(
            workers: contendedWorkers,
            makeFixture: AsyncSemaphoreBox.init
        ) { box, worker, share in
            var index = worker
            share.eachTurn {
                index = box.step(from: index)
            }
            return index
        } check: { box in
            precondition(box.writes == benchmark.turnsPerSample, "the workload did not run")
        }
    }
}
