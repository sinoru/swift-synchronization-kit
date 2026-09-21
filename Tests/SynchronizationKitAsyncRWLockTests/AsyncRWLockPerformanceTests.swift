//
//  AsyncRWLockPerformanceTests.swift
//  SynchronizationKit
//

// Gated on Dispatch: the threads these tests drive are started and joined
// through it, and WASI has none. What runs there is the suite next door
// that needs no thread of its own.
#if canImport(Dispatch)
import Dispatch
import SynchronizationKitAsyncRWLock
import SynchronizationKitTestUtils
import XCTest

/// What `AsyncRWLock` costs: the uncontended take of either side, the
/// handoff between writers as the queue gets longer, and a read-mostly mix
/// in which readers are admitted together and a writer waits them out.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`; `RWLockPerformanceTests` says how to run these. The
/// writer cases are `AsyncMutexPerformanceTests`' handoff on the other
/// primitive — the closure suspends once inside the lock, so every take
/// under contention is a real handoff — and the two share their counts, so
/// the numbers sit side by side. What the read side adds to the same wait
/// queue is in the mixed cases, where a writer's arrival ends a batch of
/// readers and its release admits the next.
final class AsyncRWLockPerformanceTests: XCTestCase {
    /// A reference to hold the lock by; `RWLockPerformanceTests.LockBox`
    /// says why.
    final class LockBox: @unchecked Sendable {
        let lock = AsyncRWLock(ChasePayload())
    }

    override func setUpWithError() throws {
        try skipUnlessMeasurable()
    }

    /// `tasks` tasks each take the lock `iterations` times, one turn in
    /// `writeEvery` for writing and the rest for reading, suspending once
    /// inside it either way. A `writeEvery` of one is all writers.
    private func measureHandoff(tasks: Int, iterations: Int, writeEvery: Int = 1) {
        measureTaskContention(tasks: tasks, iterations: iterations, makeFixture: LockBox.init) { box, task in
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
                XCTAssertEqual(writes, expected, "the workload did not run")
                finished.signal()
            }
            finished.wait()
        }
    }

    /// One task alone, reading: the take and release of the read side with
    /// nobody to wait for or to wake. `writeEvery` past the last turn, so
    /// the only write is the first.
    func testUncontendedReads() {
        measureHandoff(tasks: 1, iterations: 100_000, writeEvery: 100_000)
    }

    func testUncontendedWrites() {
        measureHandoff(tasks: 1, iterations: 100_000)
    }

    func testWriterShortQueue() {
        measureHandoff(tasks: 8, iterations: 10_000)
    }

    func testWriterLongQueue() {
        measureHandoff(tasks: 64, iterations: 2_000)
    }

    /// Past a few hundred waiters, what shows is the queue's own
    /// bookkeeping, as in `AsyncMutexPerformanceTests.testVeryLongQueue`.
    func testWriterVeryLongQueue() {
        measureHandoff(tasks: 512, iterations: 250)
    }

    /// One turn in eight a write: enough writers that the readers rarely run
    /// long unopposed, few enough that most admissions are of readers.
    func testReadMostlyShortQueue() {
        measureHandoff(tasks: 8, iterations: 10_000, writeEvery: 8)
    }

    func testReadMostlyLongQueue() {
        measureHandoff(tasks: 64, iterations: 2_000, writeEvery: 8)
    }
}
#endif
