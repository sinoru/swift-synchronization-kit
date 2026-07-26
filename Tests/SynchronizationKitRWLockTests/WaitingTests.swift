//
//  WaitingTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import SynchronizationKitAtomic
import Testing

@testable import SynchronizationKitRWLock

/// The permit contract the lock's handoffs rest on.
///
/// `_RWLockHandle`'s four wait sites are as short as they are because they hand
/// out permits rather than reporting a condition: a release that lands before
/// its counterpart blocks is kept, not lost, so neither side re-checks anything
/// on waking. The algorithm leans on that everywhere and asserts it nowhere.
///
/// Whichever backend the running OS provides is the one under test. Nothing here
/// names one: a modern release runs the address-based path, an older one runs
/// the Mach semaphores, and each is the configuration that release actually
/// ships. `SemaphorePortTests` covers what only the older path has.
@Suite("Waiting")
struct WaitingTests {
    /// A reference to reach a handle by.
    ///
    /// `_RWLockHandle` is neither copyable nor `Sendable`, so the threads below
    /// cannot capture one directly. Nothing here tears anything down: the
    /// handle's own `deinit` releases whatever its waiting acquired, which is
    /// the point of it living there.
    final class HandleBox: @unchecked Sendable {
        let handle = _RWLockHandle()

        func acquire() {
            handle._acquireReaderGate()
        }

        func release(_ count: Int32) {
            handle._releaseReaderGate(count)
        }
    }

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

    // MARK: - Which backend is in play

    /// What a handle picks must be what the running OS can actually do.
    ///
    /// Two answers to the same question, from either side of the language
    /// boundary: Swift's `#available` here against the `__builtin_available` the
    /// C shim decides it by. They can only disagree if one of them is wrong.
    ///
    /// This says nothing on a runtime newer than the versions named — above
    /// them both a correct guard and a broken one pass. It is not what catches a
    /// platform missing from the shim's guard; the shim makes that a compile
    /// error on the platform in question.
    @Test("the backend in use matches what the OS provides")
    func backendMatchesTheOS() {
        if #available(macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, visionOS 1.1, *) {
            #expect(_addressWaitIsAvailable)
        } else {
            #expect(!_addressWaitIsAvailable)
        }
    }

    // MARK: - Permits

    @Test("a permit released before anyone waits is still there")
    func permitOutlivesAnEarlyRelease() {
        let box = HandleBox()

        // Nobody is waiting yet. The permit has to be kept rather than dropped.
        box.release(1)

        #expect(
            Self.completes { box.acquire() },
            "a permit released before the wait was lost"
        )
    }

    @Test("releasing n permits lets exactly n through")
    func releaseHandsOutExactlyAsManyPermits() {
        let permits = 4
        let box = HandleBox()

        box.release(Int32(permits))

        for attempt in 1 ... permits {
            #expect(
                Self.completes { box.acquire() },
                "acquisition \(attempt) of \(permits) blocked with a permit outstanding"
            )
        }

        // The next one has nothing left to take.
        #expect(
            !Self.completes(within: 0.5) { box.acquire() },
            "a permit was handed out that had never been given"
        )

        // Let the thread parked just above go, so it does not outlive the test.
        box.release(1)
    }

    @Test("waiters beyond the permit count stay parked")
    func surplusWaitersStayParked() {
        let waiters = 8
        let permits = 3
        let box = HandleBox()
        let through = Atomic<Int32>(0)
        let finished = DispatchSemaphore(value: 0)

        for _ in 0 ..< waiters {
            Thread.detachNewThread {
                box.acquire()
                through.wrappingAdd(1, ordering: .acquiringAndReleasing)
                finished.signal()
            }
        }

        box.release(Int32(permits))

        for _ in 0 ..< permits {
            #expect(finished.wait(timeout: .now() + 5) == .success, "a permit went unclaimed")
        }

        // Give any wrongly-woken waiter a moment to show itself.
        #expect(finished.wait(timeout: .now() + 0.5) == .timedOut)
        #expect(through.load(ordering: .acquiring) == Int32(permits))

        // Release the rest so no thread outlives the test.
        box.release(Int32(waiters - permits))
        for _ in 0 ..< (waiters - permits) {
            #expect(finished.wait(timeout: .now() + 5) == .success)
        }
    }

    // MARK: - Releasing a batch through the whole lock

    /// The one test that pins down a release handing out more than one permit at
    /// a time.
    ///
    /// On the address-based backend that is a single add and a single wake
    /// covering every queued reader, so one dropped there would never be woken
    /// again.
    @Test("a departing writer releases every reader queued behind it")
    func writerReleasesEveryQueuedReader() {
        let readers = 16
        let lock = RWLock(0)
        let writerHoldsLock = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        let readersDone = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            lock.withWriteLock { _ in
                writerHoldsLock.signal()
                releaseWriter.wait()
            }
            writerDone.signal()
        }
        expectSignal(writerHoldsLock, "the writer never took the lock")

        for _ in 0 ..< readers {
            Thread.detachNewThread {
                lock.withReadLock { _ in }
                readersDone.signal()
            }
        }

        // Every reader has to have registered before the writer leaves, or the
        // test would be measuring an uncontended acquisition instead.
        #expect(
            spin(untilTrue: { registeredReaders(of: lock.handle) == Int32(readers) }),
            "readers never queued behind the writer"
        )

        releaseWriter.signal()
        expectSignal(writerDone, "the writer never left the lock")
        for index in 0 ..< readers {
            expectSignal(
                readersDone,
                within: 10,
                "the departing writer dropped reader \(index)"
            )
        }
    }
}
#endif
