//
//  MutexPerformanceTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Foundation
import Synchronization
import SynchronizationKitTestUtils
import XCTest

@testable import SynchronizationKitMutex

/// What this package's `Mutex` costs against the standard library's, which is
/// what a client on a new enough OS would otherwise use.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`; `RWLockPerformanceTests` says how to run these. Each
/// case runs twice, once per implementation, so the two land in one report:
/// the package's is an `os_unfair_lock` reached through a raw-layout struct,
/// the standard library's the same lock reached through its own, and the
/// numbers say what the reaching costs.
final class MutexPerformanceTests: XCTestCase {
    /// A reference to hold the lock by; `RWLockPerformanceTests.LockBox`
    /// says why.
    final class LockBox: @unchecked Sendable {
        let lock = SynchronizationKitMutex.Mutex(ChasePayload())
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    final class StandardLockBox: @unchecked Sendable {
        let lock = Synchronization.Mutex(ChasePayload())
    }

    override func setUpWithError() throws {
        try skipUnlessMeasurable()
    }

    static let standardLibraryNeedsNewerOS = "The standard library's Mutex needs a newer OS."

    // MARK: - Uncontended

    func testUncontended() {
        measureUncontended(iterations: 500_000, makeFixture: LockBox.init) { box in
            var index = 0
            for _ in 0 ..< 500_000 {
                box.lock.withLock {
                    $0.writes &+= 1
                    index = $0.cycle[index]
                }
            }
            return index
        } check: { box in
            XCTAssertEqual(box.lock.withLock { $0.writes }, 500_000, "the workload did not run")
        }
    }

    func testUncontendedStandardLibrary() throws {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            throw XCTSkip(Self.standardLibraryNeedsNewerOS)
        }

        measureUncontended(iterations: 500_000, makeFixture: StandardLockBox.init) { box in
            var index = 0
            for _ in 0 ..< 500_000 {
                box.lock.withLock {
                    $0.writes &+= 1
                    index = $0.cycle[index]
                }
            }
            return index
        } check: { box in
            XCTAssertEqual(box.lock.withLock { $0.writes }, 500_000, "the workload did not run")
        }
    }

    // MARK: - Contended

    // Every core but two, so the handoff is between threads that each have
    // somewhere to run; and twice the cores, so most of the time the lock is
    // handed to a thread that has to be woken for it.

    func testContended() throws {
        try skipUnlessRoomToContend()
        measureContended(workers: contendedWorkers, iterations: 50_000)
    }

    func testContendedStandardLibrary() throws {
        try skipUnlessRoomToContend()
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            throw XCTSkip(Self.standardLibraryNeedsNewerOS)
        }
        measureContendedStandardLibrary(workers: contendedWorkers, iterations: 50_000)
    }

    func testOversubscribed() throws {
        try skipUnlessRoomToContend()
        measureContended(workers: ProcessInfo.processInfo.activeProcessorCount * 2, iterations: 10_000)
    }

    func testOversubscribedStandardLibrary() throws {
        try skipUnlessRoomToContend()
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            throw XCTSkip(Self.standardLibraryNeedsNewerOS)
        }
        measureContendedStandardLibrary(
            workers: ProcessInfo.processInfo.activeProcessorCount * 2,
            iterations: 10_000
        )
    }

    private func measureContended(workers: Int, iterations: Int) {
        measureContention(workers: workers, iterations: iterations, makeFixture: LockBox.init) { box, worker in
            var index = worker
            for _ in 0 ..< iterations {
                box.lock.withLock {
                    $0.writes &+= 1
                    index = $0.cycle[index]
                }
            }
            return index
        } check: { box in
            XCTAssertEqual(box.lock.withLock { $0.writes }, workers * iterations, "the workload did not run")
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private func measureContendedStandardLibrary(workers: Int, iterations: Int) {
        measureContention(
            workers: workers,
            iterations: iterations,
            makeFixture: StandardLockBox.init
        ) { box, worker in
            var index = worker
            for _ in 0 ..< iterations {
                box.lock.withLock {
                    $0.writes &+= 1
                    index = $0.cycle[index]
                }
            }
            return index
        } check: { box in
            XCTAssertEqual(box.lock.withLock { $0.writes }, workers * iterations, "the workload did not run")
        }
    }
}
#endif
