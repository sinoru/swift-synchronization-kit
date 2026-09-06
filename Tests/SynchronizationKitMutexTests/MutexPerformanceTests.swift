//
//  MutexPerformanceTests.swift
//  SynchronizationKit
//

import Foundation
import SynchronizationKitTestUtils
import XCTest

@testable import SynchronizationKitMutex

#if canImport(Darwin)
import Synchronization
#endif

/// What `Mutex` costs — and on Apple platforms, where it is this package's
/// own, what it costs against the standard library's, which is what a client
/// on a new enough OS would otherwise use.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`; `RWLockPerformanceTests` says how to run these. On
/// Apple platforms each case runs twice, once per implementation, so the two
/// land in one report: the package's is an `os_unfair_lock` reached through a
/// raw-layout struct, the standard library's the same lock reached through
/// its own, and the numbers say what the reaching costs. Elsewhere the
/// package's `Mutex` is the standard library's, re-exported, so the
/// comparison would be of a thing with itself and only the first half runs —
/// as the cost of the lock every asynchronous primitive here keeps its
/// state under.
final class MutexPerformanceTests: XCTestCase {
    /// A reference to hold the lock by; `RWLockPerformanceTests.LockBox`
    /// says why.
    final class LockBox: @unchecked Sendable {
        let lock = SynchronizationKitMutex.Mutex(ChasePayload())
    }

    #if canImport(Darwin)
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    final class StandardLockBox: @unchecked Sendable {
        let lock = Synchronization.Mutex(ChasePayload())
    }
    #endif

    override func setUpWithError() throws {
        try skipUnlessMeasurable()
    }

    #if canImport(Darwin)
    static let standardLibraryNeedsNewerOS = "The standard library's Mutex needs a newer OS."
    #endif

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

    #if canImport(Darwin)
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
    #endif

    // MARK: - Contended

    // Every core but two, so the handoff is between threads that each have
    // somewhere to run; and twice the cores, so most of the time the lock is
    // handed to a thread that has to be woken for it.

    func testContended() throws {
        try skipUnlessRoomToContend()
        measureContended(workers: contendedWorkers, iterations: 50_000)
    }

    #if canImport(Darwin)
    func testContendedStandardLibrary() throws {
        try skipUnlessRoomToContend()
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            throw XCTSkip(Self.standardLibraryNeedsNewerOS)
        }
        measureContendedStandardLibrary(workers: contendedWorkers, iterations: 50_000)
    }

    #endif

    func testOversubscribed() throws {
        try skipUnlessRoomToContend()
        measureContended(workers: ProcessInfo.processInfo.activeProcessorCount * 2, iterations: 10_000)
    }

    #if canImport(Darwin)
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
    #endif

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

    #if canImport(Darwin)
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
    #endif
}
