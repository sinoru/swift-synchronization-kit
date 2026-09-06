//
//  SemaphorePerformanceTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Dispatch
import Foundation
import SynchronizationKitSemaphore
import SynchronizationKitTestUtils
import XCTest

/// What `Semaphore` costs against `DispatchSemaphore`, which is what a client
/// would otherwise reach for, on whichever Darwin backend the running OS
/// provides.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`; `RWLockPerformanceTests` says how to run these. The
/// semaphore is used as a lock — a count of one, taken around the chase — so
/// that the same harness applies and the numbers sit beside the locks'. Each
/// case runs twice, once per implementation.
final class SemaphorePerformanceTests: XCTestCase {
    /// The semaphore and what it guards, held by reference;
    /// `RWLockPerformanceTests.LockBox` says why.
    final class LockBox: @unchecked Sendable {
        let semaphore = Semaphore(value: 1)
        var payload = ChasePayload()
    }

    final class DispatchLockBox: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 1)
        var payload = ChasePayload()
    }

    override func setUpWithError() throws {
        try skipUnlessMeasurable()
    }

    // MARK: - Uncontended

    func testUncontended() {
        measureUncontended(iterations: 500_000, makeFixture: LockBox.init) { box in
            var index = 0
            for _ in 0 ..< 500_000 {
                box.semaphore.wait()
                box.payload.writes &+= 1
                index = box.payload.cycle[index]
                box.semaphore.signal()
            }
            return index
        } check: { box in
            XCTAssertEqual(box.payload.writes, 500_000, "the workload did not run")
        }
    }

    func testUncontendedDispatch() {
        measureUncontended(iterations: 500_000, makeFixture: DispatchLockBox.init) { box in
            var index = 0
            for _ in 0 ..< 500_000 {
                box.semaphore.wait()
                box.payload.writes &+= 1
                index = box.payload.cycle[index]
                box.semaphore.signal()
            }
            return index
        } check: { box in
            XCTAssertEqual(box.payload.writes, 500_000, "the workload did not run")
        }
    }

    // MARK: - Contended

    // A semaphore has no fast path past the kernel once anybody is waiting,
    // so this is the handoff itself: every release wakes somebody.

    func testContended() throws {
        try skipUnlessRoomToContend()
        measureContention(workers: contendedWorkers, iterations: 20_000, makeFixture: LockBox.init) { box, worker in
            var index = worker
            for _ in 0 ..< 20_000 {
                box.semaphore.wait()
                box.payload.writes &+= 1
                index = box.payload.cycle[index]
                box.semaphore.signal()
            }
            return index
        } check: { box in
            XCTAssertEqual(box.payload.writes, self.contendedWorkers * 20_000, "the workload did not run")
        }
    }

    func testContendedDispatch() throws {
        try skipUnlessRoomToContend()
        measureContention(
            workers: contendedWorkers,
            iterations: 20_000,
            makeFixture: DispatchLockBox.init
        ) { box, worker in
            var index = worker
            for _ in 0 ..< 20_000 {
                box.semaphore.wait()
                box.payload.writes &+= 1
                index = box.payload.cycle[index]
                box.semaphore.signal()
            }
            return index
        } check: { box in
            XCTAssertEqual(box.payload.writes, self.contendedWorkers * 20_000, "the workload did not run")
        }
    }
}
#endif
