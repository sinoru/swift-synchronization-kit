//
//  AsyncMutexPerformanceTests.swift
//  SynchronizationKit
//

import Dispatch
import SynchronizationKitAsyncMutex
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import XCTest

/// What `AsyncMutex` costs: the uncontended take, and the handoff through
/// the wait queue as the queue gets longer — and what an `actor` costs on
/// the same turns, since the README says to prefer one wherever it fits.
/// Each queue case runs once per implementation, so the two land in one
/// report.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`; `RWLockPerformanceTests` says how to run these. The
/// closure suspends once inside the lock, so every take under contention is
/// a real handoff rather than a spin, and what grows with the task count is
/// the queue a departing holder chooses the next holder from.
///
/// An actor cannot hold anything across an `await`, so the suspension the
/// mutex's closure makes inside the lock is made in the actor cases after
/// the actor's method has returned: each turn is still one step and one
/// suspension, and what the two differ in is the handoff — through the
/// mutex's wait queue, or through the actor's mailbox — which is what the
/// numbers say the choice between them costs.
final class AsyncMutexPerformanceTests: XCTestCase {
    /// A reference to hold the lock by; `RWLockPerformanceTests.LockBox`
    /// says why.
    final class LockBox: @unchecked Sendable {
        let lock = AsyncMutex(ChasePayload())
    }

    /// The same payload behind an actor.
    actor ActorBox {
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

    override func setUpWithError() throws {
        try skipUnlessMeasurable()
    }

    private func measureHandoff(tasks: Int, iterations: Int) {
        measureTaskContention(tasks: tasks, iterations: iterations, makeFixture: LockBox.init) { box, task in
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
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                let writes = await box.lock.withLockIfAvailable { $0.writes }
                XCTAssertEqual(writes, tasks * iterations, "the workload did not run")
                finished.signal()
            }
            finished.wait()
        }
    }

    private func measureActorHandoff(tasks: Int, iterations: Int) {
        measureTaskContention(
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
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                let writes = await box.writes
                XCTAssertEqual(writes, tasks * iterations, "the workload did not run")
                finished.signal()
            }
            finished.wait()
        }
    }

    /// Two tasks at the harness's priority hand the lock back and forth
    /// through a queue of `lows` waiters at low priority; the semaphore
    /// suite's `measurePriorityHandoff` says why the low waiters are
    /// detached tasks the workers spawn and do not await, why each takes
    /// one turn and spawns its successor, and how the sample ends only
    /// once they have all left. The one thing particular to this suite is
    /// what makes the successor necessary: a filler that held the lock
    /// while a high task queued was escalated to that task's priority, and
    /// stays there.
    private func measurePriorityHandoff(lows: Int, iterations: Int) {
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
            Task.detached(priority: .low) {
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
        measureTaskContention(tasks: lows + 2, iterations: iterations, makeFixture: { Fixture(lows: lows) }) { fixture, task in
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
                for _ in 0 ..< iterations {
                    index = Chase.cycle[index]
                }
                fill(fixture)
            }
            return index
        }
    }

    func testUncontended() {
        measureHandoff(tasks: 1, iterations: 100_000)
    }

    func testUncontendedActor() {
        measureActorHandoff(tasks: 1, iterations: 100_000)
    }

    func testShortQueue() {
        measureHandoff(tasks: 8, iterations: 10_000)
    }

    func testShortQueueActor() {
        measureActorHandoff(tasks: 8, iterations: 10_000)
    }

    func testLongQueue() {
        measureHandoff(tasks: 64, iterations: 2_000)
    }

    func testLongQueueActor() {
        measureActorHandoff(tasks: 64, iterations: 2_000)
    }

    /// Past a few hundred waiters, what shows is the queue's own
    /// bookkeeping: a handoff here costs what one in `testLongQueue` does,
    /// and a regression that scales with the queue costs several times it.
    func testVeryLongQueue() {
        measureHandoff(tasks: 512, iterations: 250)
    }

    func testVeryLongQueueActor() {
        measureActorHandoff(tasks: 512, iterations: 250)
    }

    /// A high-priority arrival placed, and served, ahead of a long queue at
    /// low priority.
    func testHighPriorityAmongLowWaiters() {
        measurePriorityHandoff(lows: 512, iterations: 10_000)
    }
}
