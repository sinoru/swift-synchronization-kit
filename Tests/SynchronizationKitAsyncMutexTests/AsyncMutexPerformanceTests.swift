//
//  AsyncMutexPerformanceTests.swift
//  SynchronizationKit
//

import Dispatch
import SynchronizationKitAsyncMutex
import SynchronizationKitTestUtils
import XCTest

/// What `AsyncMutex` costs: the uncontended take, and the handoff through
/// the wait queue as the queue gets longer.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`; `RWLockPerformanceTests` says how to run these. The
/// closure suspends once inside the lock, so every take under contention is
/// a real handoff rather than a spin, and what grows with the task count is
/// the queue a departing holder chooses the next holder from.
final class AsyncMutexPerformanceTests: XCTestCase {
    /// A reference to hold the lock by; `RWLockPerformanceTests.LockBox`
    /// says why.
    final class LockBox: @unchecked Sendable {
        let lock = AsyncMutex(ChasePayload())
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

    func testUncontended() {
        measureHandoff(tasks: 1, iterations: 100_000)
    }

    func testShortQueue() {
        measureHandoff(tasks: 8, iterations: 10_000)
    }

    func testLongQueue() {
        measureHandoff(tasks: 64, iterations: 2_000)
    }

    /// Past a few hundred waiters, what shows is the queue's own
    /// bookkeeping: a handoff here costs what one in `testLongQueue` does,
    /// and a regression that scales with the queue costs several times it.
    func testVeryLongQueue() {
        measureHandoff(tasks: 512, iterations: 250)
    }
}
