//
//  WaitingTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import SynchronizationKitTestUtils
import Testing

@testable import SynchronizationKitRWLock

/// The one handoff that hands out more than one permit at a time.
///
/// The permit contract itself — a signal that lands before its counterpart
/// blocks is kept, waiters beyond the count stay parked — is the semaphore's,
/// and its own suite checks it. What is the lock's is the batch: a departing
/// writer releases every reader queued behind it in one call, which on the
/// address-based backend is a single add and a single wake covering all of
/// them, so one dropped there would never be woken again.
@Suite("Waiting")
struct WaitingTests {
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
