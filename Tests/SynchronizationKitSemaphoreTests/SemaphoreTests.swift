//
//  SemaphoreTests.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import SynchronizationKitAtomic
import SynchronizationKitSemaphore
import SynchronizationKitTestUtils
import Testing

/// The count, and the permit contract every backend has to keep.
///
/// Whichever backend the running OS provides is the one under test. Nothing
/// here names one: a modern Apple release runs the address-based path, an
/// older one the Mach semaphores, Linux the POSIX ones, and each is the
/// configuration that platform actually ships. `BackendTests` covers what only
/// one of them has.
@Suite("Semaphore")
struct SemaphoreTests {
    /// Runs `body` on a dedicated thread and reports whether it returned in
    /// time.
    ///
    /// A wait that wrongly blocks would otherwise hang the run until the job
    /// timeout, which this repository has already paid for once.
    private static func completes(
        within seconds: Double = 5,
        _ body: @escaping @Sendable () -> Void
    ) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            body()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }

    @Test("wait takes a positive count without blocking")
    func waitTakesCount() {
        let permits = 4
        let semaphore = Semaphore(value: permits)

        for attempt in 1 ... permits {
            #expect(
                Self.completes { semaphore.wait() },
                "wait \(attempt) of \(permits) blocked with a permit outstanding"
            )
        }

        // The next one has nothing left to take.
        let parked = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            semaphore.wait()
            parked.signal()
        }
        #expect(
            parked.wait(timeout: .now() + 0.5) == .timedOut,
            "a permit was handed out that had never been given"
        )

        // Let the thread parked just above go, and see it out: the semaphore
        // is about to be destroyed, and a thread still inside `wait()` would
        // be parked on its former address.
        semaphore.signal()
        expectSignal(parked, "the parked thread never woke")

        // Every wait above took a permit that was never given back, and the
        // count may not end below where it started.
        for _ in 0 ..< permits {
            semaphore.signal()
        }
    }

    @Test("a signal with nobody waiting raises the count for the next wait")
    func signalOutlivesAnEarlyWait() {
        let semaphore = Semaphore(value: 0)

        // Nobody is waiting yet. The permit has to be kept rather than dropped.
        semaphore.signal()

        #expect(
            Self.completes { semaphore.wait() },
            "a permit signalled before the wait was lost"
        )
    }

    @Test("a signal wakes a blocked waiter")
    func signalWakesWaiter() {
        let semaphore = Semaphore(value: 0)
        let woken = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            semaphore.wait()
            woken.signal()
        }

        // Nothing announces that the thread has parked; give it a moment, and
        // check that the moment was not what let it through.
        #expect(woken.wait(timeout: .now() + 0.2) == .timedOut, "wait returned on a zero count")

        semaphore.signal()
        expectSignal(woken, "the signal never woke the waiter")
    }

    @Test("waiters beyond the count stay parked")
    func surplusWaitersStayParked() {
        let waiters = 8
        let permits = 3
        let semaphore = Semaphore(value: 0)
        let through = Atomic<Int32>(0)
        let finished = DispatchSemaphore(value: 0)

        for _ in 0 ..< waiters {
            Thread.detachNewThread {
                semaphore.wait()
                through.wrappingAdd(1, ordering: .acquiringAndReleasing)
                finished.signal()
            }
        }

        for _ in 0 ..< permits {
            semaphore.signal()
        }

        for _ in 0 ..< permits {
            expectSignal(finished, within: 5, "a permit went unclaimed")
        }

        // Give any wrongly-woken waiter a moment to show itself.
        #expect(finished.wait(timeout: .now() + 0.5) == .timedOut)
        #expect(through.load(ordering: .acquiring) == Int32(permits))

        // Release the rest so no thread outlives the test.
        for _ in 0 ..< (waiters - permits) {
            semaphore.signal()
        }
        for _ in 0 ..< (waiters - permits) {
            expectSignal(finished, within: 5)
        }
    }

    @Test("bounds how many threads run at once")
    func boundsConcurrency() {
        let limit = 3
        let threads = 12
        let semaphore = Semaphore(value: limit)
        let inside = Atomic<Int32>(0)
        let peak = Atomic<Int32>(0)
        let finished = DispatchSemaphore(value: 0)

        for _ in 0 ..< threads {
            Thread.detachNewThread {
                semaphore.wait()
                let now = inside.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
                // Record the high-water mark; a stale read only lowers it.
                var seen = peak.load(ordering: .relaxed)
                while now > seen {
                    let (exchanged, current) = peak.compareExchange(
                        expected: seen, desired: now, ordering: .acquiringAndReleasing
                    )
                    if exchanged {
                        break
                    }
                    seen = current
                }
                Thread.sleep(forTimeInterval: 0.005)
                inside.wrappingSubtract(1, ordering: .acquiringAndReleasing)
                semaphore.signal()
                finished.signal()
            }
        }

        for _ in 0 ..< threads {
            expectSignal(finished, within: 10)
        }

        #expect(peak.load(ordering: .acquiring) <= Int32(limit))
        #expect(peak.load(ordering: .acquiring) > 0)
    }

    @Test("the thread that signals need not be the one that waited")
    func handoffBetweenThreads() {
        let ready = Semaphore(value: 0)
        let consumed = Semaphore(value: 0)
        let produced = Atomic<Int32>(0)
        let done = DispatchSemaphore(value: 0)

        // A producer and a consumer taking turns on two semaphores, neither of
        // which either thread ever both waits on and signals.
        Thread.detachNewThread {
            for _ in 0 ..< 100 {
                produced.wrappingAdd(1, ordering: .acquiringAndReleasing)
                ready.signal()
                consumed.wait()
            }
            done.signal()
        }

        var seen: Int32 = 0
        for _ in 0 ..< 100 {
            ready.wait()
            seen = produced.load(ordering: .acquiring)
            consumed.signal()
        }

        expectSignal(done)
        #expect(seen == 100)
    }
}
