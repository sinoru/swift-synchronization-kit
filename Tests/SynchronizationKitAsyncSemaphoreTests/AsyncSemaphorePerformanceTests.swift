//
//  AsyncSemaphorePerformanceTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncSemaphore
import SynchronizationKitMutex
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

    /// Every task but the first waits on a count that is never raised, so
    /// nothing it waits for can arrive; the first cancels them once they are
    /// all queued, in a random order so that each departure is from somewhere
    /// in the middle, and the round repeats. No cancellation is issued until
    /// the harness's count confirms every waiter has joined — each has one
    /// child at a time and none can be served, so the count says they all
    /// have — which is what makes each one a departure from the queue rather
    /// than a task that never reached it. Every `wait()` must throw, and a
    /// waiter moves its chase only when its child's did, so a child that
    /// returned instead fails the chase check.
    ///
    /// The handles a round cancels are collected under a lock and taken out
    /// of it before the cancellations go out. A waiter registers its next
    /// child only after the previous one has been cancelled and awaited, so
    /// the registry fills to the waiter count exactly once per round.
    private func measureCancellation(waiters: Int, rounds: Int) {
        final class Fixture: Sendable {
            let semaphore = AsyncSemaphore(value: 0)
            let handles = Mutex<[Task<Void, any Error>]>([])
        }
        measureTaskContention(tasks: waiters + 1, iterations: rounds, makeFixture: Fixture.init) { fixture, task in
            var index = task
            if task == 0 {
                var generator = SplitMix64(seed: 0x5EED)
                for _ in 0 ..< rounds {
                    var handles: [Task<Void, any Error>] = []
                    while true {
                        await fixture.semaphore.waitForWaiters(waiters)
                        handles = fixture.handles.withLock { $0.count == waiters ? $0 : [] }
                        if !handles.isEmpty {
                            break
                        }
                        await Task.yield()
                    }
                    fixture.handles.withLock { $0.removeAll(keepingCapacity: true) }
                    handles.shuffle(using: &generator)
                    for handle in handles {
                        handle.cancel()
                    }
                    index = Chase.cycle[index]
                }
            } else {
                for _ in 0 ..< rounds {
                    let child = Task { @Sendable in
                        try await fixture.semaphore.wait()
                    }
                    fixture.handles.withLock { $0.append(child) }
                    do {
                        try await child.value
                    } catch is CancellationError {
                        index = Chase.cycle[index]
                    }
                }
            }
            return index
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

    /// The other thing a queue of this length has to do in constant time.
    func testCancellationInLongQueue() {
        measureCancellation(waiters: 512, rounds: 250)
    }

    // MARK: - Threads

    // The blocking `wait()`, contended by threads the way `Semaphore` is in
    // its own suite. The two numbers are not the same measurement, and the
    // gap between them — several times over — is not overhead in the queue.
    // Measured, it is a context switch per handoff: this semaphore hands the
    // count to the waiter at the head of the queue, so every signal moves
    // the work to another thread, where `Semaphore` only raises the count,
    // and the thread that just signalled takes it back before the one it
    // woke has run. That barging is what its number is made of — a few
    // thousand switches across a million handoffs, against one or two for
    // each of them here — and giving it up is what the no-overtaking and
    // priority guarantees cost. Folding the slow path's two critical
    // sections into one was tried and moved nothing.

    func testContendedThreads() throws {
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
}
