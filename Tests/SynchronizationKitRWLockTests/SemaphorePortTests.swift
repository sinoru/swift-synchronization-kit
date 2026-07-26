//
//  SemaphorePortTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import SynchronizationKitAtomic
import Testing

@testable import SynchronizationKitRWLock

/// The Mach semaphore backend's ports, which exist mainly to be absent.
///
/// A port is an entry in the task's name space, and the kernel treats a process
/// that fills its name space as leaking rather than as busy. Creating one per
/// lock made locks in bulk expensive; creating one only when a lock actually
/// blocks somebody is what these check.
///
/// Only a release predating the address-based calls runs this backend, so only
/// there is there anything here to observe. Nothing forces it on a newer OS: a
/// lock that took the Mach path where the kernel offers the address-based one
/// would be a configuration that ships nowhere, and reading a permit count as a
/// port name is not a mistake worth arranging on purpose. CI reaches this suite
/// through its pinned pre-17.4 simulator runtime.
@Suite(
    "Semaphore backend ports",
    .enabled(if: !_addressWaitIsAvailable)
)
struct SemaphorePortTests {
    @Test("an uncontended lock creates no port")
    func uncontendedLockCreatesNoPort() {
        let lock = RWLock(0)

        #expect(lock.handle.writerWord.load(ordering: .relaxed) == 0)
        #expect(lock.handle.readerWord.load(ordering: .relaxed) == 0)

        // Locking and unlocking without ever blocking anybody must not change
        // that; nothing here reaches a gate.
        lock.withWriteLock { $0 = 1 }
        #expect(lock.withReadLock { $0 } == 1)
        #expect(lock.withReadLockIfAvailable { $0 } == 1)
        #expect(lock.withWriteLockIfAvailable { $0 = 2 } != nil)

        #expect(lock.handle.writerWord.load(ordering: .relaxed) == 0)
        #expect(lock.handle.readerWord.load(ordering: .relaxed) == 0)
    }

    @Test("a writer waiting on a reader creates the writer port")
    func blockedWriterCreatesItsPort() {
        let lock = RWLock(0)
        let readerHoldsLock = DispatchSemaphore(value: 0)
        let releaseReader = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            lock.withReadLock { _ in
                readerHoldsLock.signal()
                releaseReader.wait()
            }
        }
        expectSignal(readerHoldsLock, "the reader never took the lock")

        Thread.detachNewThread {
            lock.withWriteLock { $0 = 1 }
            writerDone.signal()
        }

        // The reader holds the lock until told otherwise, so the writer has no
        // way through and must reach the gate.
        #expect(
            spin(untilTrue: { lock.handle.writerWord.load(ordering: .relaxed) != 0 }),
            "a blocked writer never created its semaphore"
        )
        #expect(lock.handle.readerWord.load(ordering: .relaxed) == 0)

        releaseReader.signal()
        expectSignal(writerDone, within: 10)
    }

    @Test("a reader waiting on a writer creates the reader port")
    func blockedReaderCreatesItsPort() {
        let lock = RWLock(0)
        let writerHoldsLock = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            lock.withWriteLock { _ in
                writerHoldsLock.signal()
                releaseWriter.wait()
            }
        }
        expectSignal(writerHoldsLock, "the writer never took the lock")

        Thread.detachNewThread {
            _ = lock.withReadLock { $0 }
            readerDone.signal()
        }

        #expect(
            spin(untilTrue: { lock.handle.readerWord.load(ordering: .relaxed) != 0 }),
            "a blocked reader never created its semaphore"
        )

        releaseWriter.signal()
        expectSignal(readerDone, within: 10)
    }
}
#endif
