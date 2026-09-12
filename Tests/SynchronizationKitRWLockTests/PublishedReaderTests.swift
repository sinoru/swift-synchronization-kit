//
//  PublishedReaderTests.swift
//  SynchronizationKit
//

#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows)
import Dispatch
import Foundation
import SynchronizationKitAtomic
import SynchronizationKitTestUtils
import Testing

@testable import SynchronizationKitRWLock

/// The reader path that touches no shared word, and the writer path that
/// turns it off and back on.
///
/// The suites elsewhere check that the lock excludes what it should whatever
/// path a reader took. These check which path it took, through the word
/// `_ReaderBias` keeps: non-negative while readers publish themselves in the
/// shared table, negative while a writer has turned that off.
@Suite("Published readers")
struct PublishedReaderTests {
    /// Whether readers of `lock` may publish themselves at this moment.
    ///
    /// Read into a local before an `#expect`: the macro captures the
    /// arguments of a call it is handed, and a lock is not copyable.
    private func readersPublish(on lock: borrowing RWLock<Int>) -> Bool {
        lock.handle.bias.word.load(ordering: .relaxed) >= 0
    }

    /// Whether a reader holding `lock` right now was counted rather than
    /// published. Only the built backend exposes the count that tells; on
    /// the others every reader is taken as published.
    private func aReaderIsCounted(on lock: borrowing RWLock<Int>) -> Bool {
        #if canImport(Darwin)
        return lock.handle.readerCount.load(ordering: .relaxed) != 0
        #else
        return false
        #endif
    }

    @Test("a reader publishes itself rather than being counted")
    func readerPublishes() {
        let lock = RWLock(0)
        let release = DispatchSemaphore(value: 0)

        // The table is shared by every lock in the process and the suites run
        // concurrently, so a reader can find both slots it tries taken by
        // another test's readers and be counted instead — correct, and not
        // what this checks. A fresh thread hashes to fresh slots, so a reader
        // found counted is let go and another tried, within reason.
        var published = false
        for _ in 0 ..< 100 where !published {
            let readerIn = DispatchSemaphore(value: 0)
            let readerOut = DispatchSemaphore(value: 0)
            // A dedicated thread for the reason `RWLockTests` documents.
            Thread.detachNewThread {
                lock.withReadLock { _ in
                    readerIn.signal()
                    release.wait()
                }
                readerOut.signal()
            }
            readerIn.wait()
            published = !aReaderIsCounted(on: lock)
            if !published {
                release.signal()
                expectSignal(readerOut)
                continue
            }

            let publishing = readersPublish(on: lock)
            #expect(publishing, "a reader on a fresh lock should publish")
            // A writer's scan has to find the published reader in the way —
            // and having found it, leave the table as it was.
            #expect(lock.withWriteLockIfAvailable { _ in } == nil)
            let publishingAfterTry = readersPublish(on: lock)
            #expect(publishingAfterTry, "a writer turned away should not leave the table off")
            release.signal()
            expectSignal(readerOut)
        }
        #expect(published, "no reader published itself in a hundred tries")
        // With the reader gone, the same scan finds nothing.
        #expect(lock.withWriteLockIfAvailable { $0 = 1 } != nil)
    }

    @Test("a writer turns the table off while it holds the lock, and a reader turns it back on")
    func writerTurnsTableOffThenOn() {
        let lock = RWLock(0)
        let writerIn = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writerOut = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            lock.withWriteLock { _ in
                writerIn.signal()
                release.wait()
            }
            writerOut.signal()
        }

        writerIn.wait()
        let publishing = readersPublish(on: lock)
        #expect(!publishing, "the table should be off while a writer holds the lock")
        #expect(lock.withReadLockIfAvailable { $0 } == nil)
        release.signal()
        expectSignal(writerOut)
        // The write leaves the table off for a spell; a reader arriving once
        // it has passed turns the table back on, and the ones after it
        // publish again.
        let turnedOn = spin(untilTrue: {
            lock.withReadLock { _ in }
            return readersPublish(on: lock)
        })
        #expect(turnedOn, "no reader turned the table back on after the write")
        #expect(lock.withReadLock { $0 } == 0)
    }

    @Test("writes leave the table off, and only a reader after the spell turns it back on")
    func writesLeaveTableOff() {
        let lock = RWLock(0)
        lock.withWriteLock { $0 += 1 }
        let publishingAfterWrite = readersPublish(on: lock)
        #expect(!publishingAfterWrite, "a write should leave the table off")

        // A reader arriving within the spell is counted and leaves the
        // table as it found it; that the spell is still running is the one
        // thing here the clock decides, so the read follows the write as
        // closely as a call can.
        lock.withWriteLock { $0 += 1 }
        lock.withReadLock { _ in }
        // Once the spell has passed, a reader turns the table back on. How
        // long that is depends on what the scan cost, which a loaded machine
        // — the sanitizer, the other suites — can stretch by orders of
        // magnitude, so readers keep coming until one does it.
        let publishingAfterSpell = spin(untilTrue: {
            lock.withReadLock { _ in }
            return readersPublish(on: lock)
        })
        #expect(publishingAfterSpell, "no reader turned the table back on after the spell")
        // And a write turns it off again, scanning for the readers that
        // published meanwhile.
        lock.withWriteLock { $0 += 1 }
        let publishingAfterNextWrite = readersPublish(on: lock)
        #expect(!publishingAfterNextWrite, "a write should turn the table off again")
    }

    @Test("a read inside a read on one thread takes a slot of its own, and a writer waits for both")
    func nestedReadsPublishSeparately() {
        let lock = RWLock(3)
        let total = lock.withReadLock { outer in
            lock.withReadLock { inner in outer + inner }
        }
        #expect(total == 6)
        let publishing = readersPublish(on: lock)
        #expect(publishing)
        // Both slots have to be clear by now, or the writer's scan would spin
        // forever on the one still naming the lock.
        lock.withWriteLock { $0 = 4 }
        #expect(lock.withReadLock { $0 } == 4)
    }

    @Test("a crowd of readers, published or counted, hold the lock and let a writer through")
    func crowdOfReaders() {
        // Enough readers at once that some are likely to find their slots
        // taken and be counted instead, so the writer has both kinds to wait
        // for; which readers those are is the hash's business.
        let readers = 32
        let lock = RWLock(0)
        let readersIn = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readersOut = DispatchSemaphore(value: 0)

        for _ in 0 ..< readers {
            Thread.detachNewThread {
                lock.withReadLock { _ in
                    readersIn.signal()
                    release.wait()
                }
                readersOut.signal()
            }
        }
        for _ in 0 ..< readers {
            readersIn.wait()
        }
        #expect(lock.withWriteLockIfAvailable { _ in } == nil)
        for _ in 0 ..< readers {
            release.signal()
        }
        for index in 0 ..< readers {
            expectSignal(readersOut, "reader \(index) never left the lock")
        }
        lock.withWriteLock { $0 = 1 }
        #expect(lock.withReadLock { $0 } == 1)
    }
}
#endif
