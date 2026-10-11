//
//  AsyncMutexBenchmarks.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

import Benchmark
import Dispatch
import SynchronizationKit

// What `AsyncMutex` costs: the uncontended take, and the handoff through
// the wait queue as the queue gets longer — and what an `actor` costs on
// the same turns, since the README says to prefer one wherever it fits.
// Each queue case runs once per implementation, so the two land in one
// report.
//
// The closure suspends once inside the lock, so every take under contention
// is a real handoff rather than a spin, and what grows with the task count
// is the queue a departing holder chooses the next holder from.
//
// An actor cannot hold anything across an `await`, so the suspension the
// mutex's closure makes inside the lock is made in the actor cases after
// the actor's method has returned: each turn is still one step and one
// suspension, and what the two differ in is the handoff — through the
// mutex's wait queue, or through the actor's mailbox — which is what the
// numbers say the choice between them costs.

/// A reference to hold the lock by; `MutexBox` says why.
private final class AsyncMutexBox: @unchecked Sendable {
    let lock = AsyncMutex(ChasePayload())
}

/// The same payload behind an actor.
private actor ActorBox {
    private var payload = ChasePayload()

    /// One write and one step of the chase from `index`.
    func step(from index: Int) -> Int {
        payload.writes &+= 1
        return payload.cycle[index]
    }

    var writes: Int {
        payload.writes
    }
}

/// The queue lengths the handoff is measured through, each with the turns
/// per task that make a sample up to the scaling factor. Past a few hundred
/// waiters, what shows is the queue's own bookkeeping: a handoff there
/// costs what one in a long queue does, and a regression that scales with
/// the queue costs several times it.
let queueLengths = [
    (scenario: "uncontended", tasks: 1, iterations: 1_000_000),
    (scenario: "short queue", tasks: 8, iterations: 125_000),
    (scenario: "long queue", tasks: 64, iterations: 15_625),
    (scenario: "very long queue", tasks: 500, iterations: 2_000),
]

private func registerHandoff(_ scenario: String, tasks: Int, iterations: Int) {
    Benchmark("AsyncMutex \(scenario)", configuration: .handoff) { benchmark in
        precondition(tasks * iterations == benchmark.turnsPerSample)
        benchmark.measureTaskContention(
            tasks: tasks,
            iterations: iterations,
            makeFixture: AsyncMutexBox.init
        ) { box, task in
            var index = task
            for _ in 0 ..< iterations {
                try await box.lock.withLock { payload in
                    payload.writes &+= 1
                    index = payload.cycle[index]
                    await Task.yield()
                }
            }
            return index
        } check: { box in
            // Nobody holds the lock any more, so the try cannot fail; and it
            // cannot throw, which keeps the task's result from needing a
            // reader.
            let expected = benchmark.turnsPerSample
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                let writes = await box.lock.withLockIfAvailable { $0.writes }
                precondition(writes == expected, "the workload did not run")
                finished.signal()
            }
            finished.wait()
        }
    }
}

private func registerActorHandoff(_ scenario: String, tasks: Int, iterations: Int) {
    Benchmark("AsyncMutex \(scenario), actor", configuration: .handoff) { benchmark in
        precondition(tasks * iterations == benchmark.turnsPerSample)
        benchmark.measureTaskContention(
            tasks: tasks,
            iterations: iterations,
            makeFixture: ActorBox.init
        ) { box, task in
            var index = task
            for _ in 0 ..< iterations {
                index = await box.step(from: index)
                await Task.yield()
            }
            return index
        } check: { box in
            let expected = benchmark.turnsPerSample
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                let writes = await box.writes
                precondition(writes == expected, "the workload did not run")
                finished.signal()
            }
            finished.wait()
        }
    }
}

/// Two tasks at the harness's priority hand the lock back and forth through
/// a queue of `lows` waiters at low priority; the semaphore cases'
/// `registerPriorityHandoff` says why the low waiters are detached tasks
/// the workers spawn and do not await, why each takes one turn and spawns
/// its successor, and how the sample ends only once they have all left. The
/// one thing particular to this primitive is what makes the successor
/// necessary: a filler that held the lock while a high task queued was
/// escalated to that task's priority, and stays there.
private func registerPriorityHandoff(lows: Int, iterations: Int) {
    final class Fixture: Sendable {
        let lock = AsyncMutex(0)
        let finished = Mutex<Int>(0)
        let fillers: Mutex<Int>
        let drained = Gate()

        init(lows: Int) {
            fillers = Mutex(lows)
        }
    }
    @Sendable func fill(_ fixture: Fixture) {
        // The task is deliberately neither awaited nor kept: awaiting it
        // would raise it to the awaiter's priority, and the fixture's
        // flags are how the fillers end.
        _ = Task.detached(priority: .low) {
            try await fixture.lock.withLock { _ in
                await Task.yield()
            }
            if fixture.finished.withLock({ $0 < 2 }) {
                fill(fixture)
            } else if fixture.fillers.withLock({ $0 -= 1; return $0 == 0 }) {
                fixture.drained.open()
            }
        }
    }
    Benchmark("AsyncMutex high priority among low waiters", configuration: .handoff) { benchmark in
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
                    try await fixture.lock.withLock { holds in
                        holds += 1
                        index = Chase.cycle[index]
                        await Task.yield()
                    }
                }
                fixture.finished.withLock { $0 += 1 }
                await fixture.drained.wait()
            } else {
                fill(fixture)
            }
            return index
        } check: { fixture in
            let expected = benchmark.turnsPerSample
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                let holds = await fixture.lock.withLockIfAvailable { $0 }
                precondition(holds == expected, "the workload did not run")
                finished.signal()
            }
            finished.wait()
        }
    }
}

func registerAsyncMutexBenchmarks() {
    for (scenario, tasks, iterations) in queueLengths {
        registerHandoff(scenario, tasks: tasks, iterations: iterations)
        registerActorHandoff(scenario, tasks: tasks, iterations: iterations)
    }
    registerPriorityHandoff(lows: 512, iterations: 500_000)
}
