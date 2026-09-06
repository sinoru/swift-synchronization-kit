//
//  StressTests.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import SynchronizationKitAtomic
import SynchronizationKitTestUtils
import Testing

@testable import SynchronizationKitMutex

/// `Mutex` under as many interleavings as a run has time for.
///
/// `MutexTests` checks the result of one contended run — a total that adds
/// up. These check the property itself, that nobody is ever inside the lock
/// alongside anybody else, across a matrix of thread counts and with the
/// critical section held open for a random spell so an overlap has a window
/// to happen in. `stressScale` says how many times over.
///
/// Skipped under ThreadSanitizer where the lock is the standard library's
/// Linux mutex, for the reason `MutexTests` records.
@Suite(
    "Mutex stress",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct MutexStressTests {
    /// How long a critical section is held open, in relaxed loads: zero to
    /// this, drawn per iteration.
    static let maximumDwell = 64

    @Test("nobody is inside the lock alongside anybody else", arguments: stressWorkerCounts)
    func exclusion(threads: Int) {
        let iterations = 10_000 * stressScale
        let mutex = Mutex(0)
        let occupancy = Atomic<Int32>(0)
        let violations = Atomic<Int32>(0)
        let done = DispatchSemaphore(value: 0)

        for thread in 0 ..< threads {
            Thread.detachNewThread {
                var random = SplitMix64(seed: UInt64(thread))
                for _ in 0 ..< iterations {
                    let dwell = Int.random(in: 0 ... Self.maximumDwell, using: &random)
                    mutex.withLock { value in
                        if occupancy.wrappingAdd(1, ordering: .acquiringAndReleasing).oldValue != 0 {
                            violations.wrappingAdd(1, ordering: .relaxed)
                        }
                        value &+= 1
                        for _ in 0 ..< dwell {
                            _ = occupancy.load(ordering: .relaxed)
                        }
                        occupancy.wrappingSubtract(1, ordering: .acquiringAndReleasing)
                    }
                }
                done.signal()
            }
        }

        for _ in 0 ..< threads {
            expectSignal(done, within: 300)
        }

        #expect(violations.load(ordering: .relaxed) == 0, "two threads were inside the lock at once")
        #expect(occupancy.load(ordering: .relaxed) == 0)
        // A try rather than a take: a lock left held by a worker that never
        // finished would block this thread with it, past the bound the joins
        // above set.
        guard let value = mutex.withLockIfAvailable({ $0 }) else {
            Issue.record("the lock was left held")
            return
        }
        #expect(value == threads * iterations)
    }

    /// `withLockIfAvailable` mixed in with `withLock`: a try that succeeds
    /// has to exclude a blocking taker as fully as a blocking taker does,
    /// and one that fails has to leave the lock exactly as it found it.
    @Test("a try and a blocking take exclude each other", arguments: stressWorkerCounts)
    func triesAndTakes(threads: Int) {
        let iterations = 10_000 * stressScale
        let mutex = Mutex(0)
        let occupancy = Atomic<Int32>(0)
        let violations = Atomic<Int32>(0)
        let taken = Atomic<Int>(0)
        let done = DispatchSemaphore(value: 0)

        @Sendable func enter(_ value: inout Int) {
            if occupancy.wrappingAdd(1, ordering: .acquiringAndReleasing).oldValue != 0 {
                violations.wrappingAdd(1, ordering: .relaxed)
            }
            value &+= 1
            occupancy.wrappingSubtract(1, ordering: .acquiringAndReleasing)
        }

        for thread in 0 ..< threads {
            Thread.detachNewThread {
                var random = SplitMix64(seed: UInt64(thread))
                var count = 0
                for _ in 0 ..< iterations {
                    if Bool.random(using: &random) {
                        mutex.withLock { enter(&$0) }
                        count += 1
                    } else if mutex.withLockIfAvailable({ enter(&$0) }) != nil {
                        count += 1
                    }
                }
                taken.wrappingAdd(count, ordering: .relaxed)
                done.signal()
            }
        }

        for _ in 0 ..< threads {
            expectSignal(done, within: 300)
        }

        #expect(violations.load(ordering: .relaxed) == 0, "two threads were inside the lock at once")
        #expect(occupancy.load(ordering: .relaxed) == 0)
        guard let value = mutex.withLockIfAvailable({ $0 }) else {
            Issue.record("the lock was left held")
            return
        }
        #expect(value == taken.load(ordering: .relaxed))
    }
}
