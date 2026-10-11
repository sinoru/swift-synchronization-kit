//
//  AsyncRWLockBenchmarks.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

import Benchmark
import Dispatch
import SynchronizationKit

// What `AsyncRWLock` costs: the uncontended take of either side, the handoff
// between writers as the queue gets longer, and a read-mostly mix in which
// readers are admitted together and a writer waits them out.
//
// The writer cases are `AsyncMutex`'s handoff on the other primitive — the
// closure suspends once inside the lock, so every take under contention is
// a real handoff — and the two share their counts, so the numbers sit side
// by side. What the read side adds to the same wait queue is in the mixed
// cases, where a writer's arrival ends a batch of readers and its release
// admits the next.

/// A reference to hold the lock by; `MutexBox` says why.
private final class AsyncRWLockBox: @unchecked Sendable {
    let lock = AsyncRWLock(ChasePayload())
}

/// `tasks` tasks each take the lock `iterations` times, one turn in
/// `writeEvery` for writing and the rest for reading, suspending once inside
/// it either way. A `writeEvery` of one is all writers.
private func registerHandoff(_ scenario: String, tasks: Int, iterations: Int, writeEvery: Int = 1) {
    Benchmark("AsyncRWLock \(scenario)", configuration: .handoff) { benchmark in
        precondition(tasks * iterations == benchmark.turnsPerSample)
        benchmark.measureTaskContention(
            tasks: tasks,
            iterations: iterations,
            makeFixture: AsyncRWLockBox.init
        ) { box, task in
            var index = task
            for turn in 0 ..< iterations {
                if turn % writeEvery == 0 {
                    try await box.lock.withWriteLock { payload in
                        payload.writes &+= 1
                        index = payload.cycle[index]
                        await Task.yield()
                    }
                } else {
                    try await box.lock.withReadLock { payload in
                        index = payload.cycle[index]
                        await Task.yield()
                    }
                }
            }
            return index
        } check: { box in
            // Nobody holds the lock any more, so the try cannot fail; and it
            // cannot throw, which keeps the task's result from needing a
            // reader.
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                let writes = await box.lock.withReadLockIfAvailable { $0.writes }
                let expected = tasks * ((iterations + writeEvery - 1) / writeEvery)
                precondition(writes == expected, "the workload did not run")
                finished.signal()
            }
            finished.wait()
        }
    }
}

func registerAsyncRWLockBenchmarks() {
    // One task alone, reading: the take and release of the read side with
    // nobody to wait for or to wake. `writeEvery` past the last turn, so
    // the only write is the first.
    registerHandoff("uncontended reads", tasks: 1, iterations: 1_000_000, writeEvery: 1_000_000)
    registerHandoff("uncontended writes", tasks: 1, iterations: 1_000_000)

    for (scenario, tasks, iterations) in queueLengths.dropFirst() {
        registerHandoff("writer \(scenario)", tasks: tasks, iterations: iterations)
    }

    // One turn in eight a write: enough writers that the readers rarely run
    // long unopposed, few enough that most admissions are of readers.
    for (scenario, tasks, iterations) in queueLengths[1 ... 2] {
        registerHandoff(
            "read-mostly \(scenario)",
            tasks: tasks,
            iterations: iterations,
            writeEvery: 8
        )
    }
}
