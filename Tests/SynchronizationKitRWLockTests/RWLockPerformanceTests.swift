//
//  RWLockPerformanceTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Foundation
import SynchronizationKitTestUtils
import XCTest

@testable import SynchronizationKitRWLock

/// What `RWLock` costs, on whichever Darwin backend the running OS provides.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`. Every case is skipped in a debug build, so an
/// ordinary `swift test` is untouched and no environment variable has to be
/// remembered. Measure in release:
///
///     swift test -c release -Xswiftc -enable-testing \
///         --filter RWLockPerformanceTests
///
/// `-enable-testing` is what the rest of the target's `@testable` imports need
/// in release; it is not what ships. It makes internal symbols externally
/// visible, which costs the optimizer some of what it may assume, so read these
/// as a self-consistent series rather than as the cost of a release build.
final class RWLockPerformanceTests: XCTestCase {
    /// A reference to hold the lock by.
    ///
    /// Capturing a noncopyable value in a measured block currently fails to
    /// compile — "copy of noncopyable typed value", reported by the compiler as
    /// its own bug — so the block captures this instead and reaches the lock
    /// through it.
    final class LockBox: @unchecked Sendable {
        let lock = RWLock(ChasePayload())
    }

    override func setUpWithError() throws {
        try skipUnlessMeasurable()
    }

    // MARK: - Harness

    /// Runs one reader and writer mix over a fresh lock. Writers come first
    /// in the worker numbering.
    private func measureContention(readers: Int, writers: Int, iterations: Int) {
        measureContention(
            workers: readers + writers,
            iterations: iterations,
            makeFixture: LockBox.init
        ) { box, worker in
            var index = worker
            if worker < writers {
                for _ in 0 ..< iterations {
                    box.lock.withWriteLock {
                        $0.writes &+= 1
                        index = $0.cycle[index]
                    }
                }
            } else {
                for _ in 0 ..< iterations {
                    index = box.lock.withReadLock { $0.cycle[index] }
                }
            }
            return index
        } check: { box in
            XCTAssertEqual(
                box.lock.withReadLock { $0.writes },
                writers * iterations,
                "the write side did not run"
            )
        }
    }

    private func measureUncontended(writing: Bool, iterations: Int) {
        measureUncontended(iterations: iterations, makeFixture: LockBox.init) { box in
            var index = 0
            if writing {
                for _ in 0 ..< iterations {
                    box.lock.withWriteLock {
                        $0.writes &+= 1
                        index = $0.cycle[index]
                    }
                }
            } else {
                for _ in 0 ..< iterations {
                    index = box.lock.withReadLock { $0.cycle[index] }
                }
            }
            return index
        } check: { box in
            XCTAssertEqual(
                box.lock.withReadLock { $0.writes },
                writing ? iterations : 0,
                "the workload did not run"
            )
        }
    }

    // MARK: - Uncontended

    func testUncontendedReads() {
        measureUncontended(writing: false, iterations: 500_000)
    }

    func testUncontendedWrites() {
        measureUncontended(writing: true, iterations: 500_000)
    }

    // MARK: - Readers against a trickle of writes

    func testReaderScaling() throws {
        try skipUnlessRoomToContend()
        measureContention(readers: contendedWorkers, writers: 1, iterations: 50_000)
    }

    // MARK: - A writer releasing a crowd

    // Deliberately more readers than cores, so a departing writer has a queue to
    // hand the lock to. This is where releasing every one of them at once tells
    // against one system call each.

    func testWriterHandoff() throws {
        try skipUnlessRoomToContend()
        measureContention(
            readers: ProcessInfo.processInfo.activeProcessorCount * 2,
            writers: 1,
            iterations: 4_000
        )
    }

    // MARK: - Mixed

    func testMixedContention() throws {
        try skipUnlessRoomToContend()
        measureContention(readers: contendedWorkers, writers: 4, iterations: 20_000)
    }
}
#endif
