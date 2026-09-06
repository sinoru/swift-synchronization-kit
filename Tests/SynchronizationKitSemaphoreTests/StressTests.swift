//
//  StressTests.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import SynchronizationKitAtomic
import SynchronizationKitSemaphore
import SynchronizationKitTestUtils
import Testing

/// `Semaphore` under as many handoffs as a run has time for.
///
/// What a semaphore can get wrong is a wake: one lost, and a waiter sleeps
/// forever; one too many, and a waiter passes on a count it was never given.
/// Neither shows up in a single handoff, so these run thousands and bound
/// every join, which is what turns a lost wake into a failure rather than a
/// hang. `stressScale` says how many thousands.
///
/// Whichever backend the running OS provides is the one under test, as in
/// `SemaphoreTests`.
@Suite("Semaphore stress")
struct SemaphoreStressTests {
    /// Two threads passing one turn back and forth, each handoff a wait on
    /// one semaphore and a signal on the other. Strict alternation is the
    /// invariant: if either side ever ran twice in a row, a wake was
    /// delivered that no signal had earned.
    ///
    /// Both sides are worker threads. The test thread only joins them, with
    /// a bound, so that a wake lost on either side is reported rather than
    /// waited out on the thread that would have reported it.
    @Test("a turn passed back and forth never doubles up")
    func pingPong() {
        let rounds = 20_000 * stressScale
        let ping = Semaphore(value: 0)
        let pong = Semaphore(value: 0)
        let turn = Atomic<Int>(0)
        let outOfTurn = Atomic<Int32>(0)
        let done = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            for round in 0 ..< rounds {
                ping.wait()
                if turn.load(ordering: .acquiring) != round * 2 + 1 {
                    outOfTurn.wrappingAdd(1, ordering: .relaxed)
                }
                turn.store(round * 2 + 2, ordering: .releasing)
                pong.signal()
            }
            done.signal()
        }

        Thread.detachNewThread {
            for round in 0 ..< rounds {
                if turn.load(ordering: .acquiring) != round * 2 {
                    outOfTurn.wrappingAdd(1, ordering: .relaxed)
                }
                turn.store(round * 2 + 1, ordering: .releasing)
                ping.signal()
                pong.wait()
            }
            done.signal()
        }

        expectSignal(done, within: 300, "a side never finished its turns")
        expectSignal(done, within: 300, "a side never finished its turns")
        #expect(outOfTurn.load(ordering: .relaxed) == 0, "a side ran out of turn")
        #expect(turn.load(ordering: .acquiring) == rounds * 2)
    }

    /// One thread signalling into a crowd of waiters, each of which takes a
    /// fixed share and then leaves. Every signal has a waiter to wake and
    /// every waiter a signal to wait for, so if all of them return, no wake
    /// was lost; and if the count is zero afterwards, none was invented.
    @Test("every signal into a crowd wakes exactly one waiter", arguments: stressWorkerCounts)
    func fanOut(waiters: Int) {
        let share = 2_000 * stressScale
        let semaphore = Semaphore(value: 0)
        let consumed = Atomic<Int>(0)
        let done = DispatchSemaphore(value: 0)

        for _ in 0 ..< waiters {
            Thread.detachNewThread {
                for _ in 0 ..< share {
                    semaphore.wait()
                    consumed.wrappingAdd(1, ordering: .relaxed)
                }
                done.signal()
            }
        }

        for _ in 0 ..< (waiters * share) {
            semaphore.signal()
        }

        for _ in 0 ..< waiters {
            expectSignal(done, within: 300, "a waiter never woke")
        }
        #expect(consumed.load(ordering: .relaxed) == waiters * share)

        // Nothing is left over: one more wait has to block.
        let extra = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            semaphore.wait()
            extra.signal()
        }
        #expect(extra.wait(timeout: .now() + 0.2) == .timedOut, "a count was left over")
        semaphore.signal()
        expectSignal(extra)
    }

    /// The bound, held across a matrix of thread counts with a random spell
    /// inside: at no point are more threads through than there are permits,
    /// and every permit comes back.
    @Test("the bound holds however many threads press on it", arguments: stressWorkerCounts)
    func bound(threads: Int) {
        let limit = 3
        let iterations = 2_000 * stressScale
        let semaphore = Semaphore(value: limit)
        let inside = Atomic<Int32>(0)
        let overLimit = Atomic<Int32>(0)
        let done = DispatchSemaphore(value: 0)

        for thread in 0 ..< threads {
            Thread.detachNewThread {
                var random = SplitMix64(seed: UInt64(thread))
                for _ in 0 ..< iterations {
                    let dwell = Int.random(in: 0 ... 64, using: &random)
                    semaphore.wait()
                    if inside.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue > Int32(limit) {
                        overLimit.wrappingAdd(1, ordering: .relaxed)
                    }
                    for _ in 0 ..< dwell {
                        _ = inside.load(ordering: .relaxed)
                    }
                    inside.wrappingSubtract(1, ordering: .acquiringAndReleasing)
                    semaphore.signal()
                }
                done.signal()
            }
        }

        for _ in 0 ..< threads {
            expectSignal(done, within: 300)
        }

        #expect(overLimit.load(ordering: .relaxed) == 0, "more threads were through than permits")
        #expect(inside.load(ordering: .relaxed) == 0)

        // Every permit is back: `limit` waits go through, the next blocks.
        // The waits are on a worker thread, joined with a bound, so a permit
        // that did not come back is reported rather than waited out.
        let reclaimed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            for _ in 0 ..< limit {
                semaphore.wait()
            }
            reclaimed.signal()
        }
        expectSignal(reclaimed, "a permit did not come back")

        let extra = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            semaphore.wait()
            extra.signal()
        }
        #expect(extra.wait(timeout: .now() + 0.2) == .timedOut, "a permit was invented")
        semaphore.signal()
        expectSignal(extra)

        // The count may not end below where it started.
        for _ in 0 ..< limit {
            semaphore.signal()
        }
    }
}
