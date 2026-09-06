//
//  AsyncSemaphorePerformanceTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import SynchronizationKitAsyncSemaphore
import SynchronizationKitTestUtils
import XCTest

/// What `AsyncSemaphore` costs: the uncontended take, and the handoff
/// through the wait queue as the queue gets longer.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`; `RWLockPerformanceTests` says how to run these. The
/// semaphore is used as a lock — a count of one, taken around the chase and
/// a suspension — so the numbers sit beside `AsyncMutex`'s, which differs
/// from this in holding a value and in escalating its holder.
final class AsyncSemaphorePerformanceTests: XCTestCase {
    /// The semaphore and what it guards, held by reference;
    /// `RWLockPerformanceTests.LockBox` says why. The payload is guarded by
    /// the semaphore, which is what makes the unchecked conformance right.
    final class LockBox: @unchecked Sendable {
        let semaphore = AsyncSemaphore(value: 1)
        var payload = ChasePayload()
    }

    override func setUpWithError() throws {
        try skipUnlessMeasurable()
    }

    private func measureHandoff(tasks: Int, iterations: Int) {
        measureTaskContention(tasks: tasks, iterations: iterations, makeFixture: LockBox.init) { box, task in
            var index = task
            for _ in 0 ..< iterations {
                try await box.semaphore.wait()
                box.payload.writes &+= 1
                index = box.payload.cycle[index]
                await Task.yield()
                box.semaphore.signal()
            }
            return index
        } check: { box in
            XCTAssertEqual(box.payload.writes, tasks * iterations, "the workload did not run")
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
}
#endif
