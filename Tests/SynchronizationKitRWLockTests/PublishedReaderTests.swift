//
//  PublishedReaderTests.swift
//  SynchronizationKit
//

// Debug only: these tests reach internal declarations through `@testable`,
// which a release build does not leave open.
#if DEBUG

// Gated on Dispatch: the threads these tests drive are started and joined
// through it, and WASI has none. What runs there is the suite next door
// that needs no thread of its own.
#if canImport(Dispatch)
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

    /// The slot `slot` names, or zero where the reader it came from was
    /// counted rather than published.
    ///
    /// By address, and through a `switch`: a slot token is noncopyable, so
    /// there is no `==` to compare two of them with, and binding one out of a
    /// borrowed optional with `if let` would consume it.
    private func address(of slot: borrowing _ReaderSlot?) -> UInt {
        switch unsafe slot {
        case .some(let published):
            unsafe UInt(bitPattern: published._address)
        case .none:
            0
        }
    }

    /// Whether two reads nested on one thread landed in the same slot.
    ///
    /// Both reads, the comparison and both unlocks happen inside one borrow
    /// of the lock: a slot token lives no longer than the borrow of the
    /// handle that issued it, and reaching `handle` through a local would be
    /// a borrow that ends with the statement.
    private func nestedReadsShareASlot(on lock: borrowing RWLock<Int>) -> Bool {
        let outer = unsafe lock.handle._readLock()
        let inner = unsafe lock.handle._readLock()
        let shared = unsafe address(of: outer) != 0 && address(of: outer) == address(of: inner)
        unsafe lock.handle._readUnlock(inner)
        unsafe lock.handle._readUnlock(outer)
        return shared
    }

    #if !os(Windows)
    /// Thread structures sit a fixed distance apart — a stack mapping's
    /// length — and the slot a reader starts at is a Fibonacci hash of the
    /// lock's address plus the structure's, which spreads such a progression
    /// evenly whatever the lock. The distances are the ones measured for
    /// default stacks on Darwin, glibc and musl. Windows names threads by
    /// identifiers in no order, and makes no such promise.
    @Test(
        "threads reading one lock start at slots of their own",
        arguments: [0x8C000, 0x81_0000, 0x2_3000] as [UInt]
    )
    func threadsStartAtSlotsOfTheirOwn(stride: UInt) {
        let threads = (0 ..< 20).map { 0x0700_0B20 &+ stride &* UInt($0) }
        for lock in Swift.stride(from: UInt(0x1_0020), to: 0x2_0020, by: 16) {
            let slots = Set(threads.map { _ReaderBias._slotIndex(lock: lock, thread: $0) })
            #expect(slots.count == threads.count, "two threads share a first slot on the lock at \(lock)")
        }
    }
    #endif

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

    /// Taken through the handle. Nesting a read on one thread is what the
    /// locking methods forbid, and trap on where the caller is built with
    /// assertions enabled; a caller built without them still reaches the
    /// table twice, and the two reads must not share a slot.
    @Test("a read inside a read on one thread takes a slot of its own, and a writer waits for both")
    func nestedReadsPublishSeparately() {
        let lock = RWLock(3)
        let sharedASlot = nestedReadsShareASlot(on: lock)
        #expect(!sharedASlot)
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
#endif
#endif
