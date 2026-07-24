//
//  RWLockTests.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import Testing

@testable import SynchronizationKitRWLock

@Suite("RWLock")
struct RWLockTests {
    @Test("withReadLock returns the closure's result")
    func withReadLockReturns() {
        let lock = RWLock(21)
        #expect(lock.withReadLock { $0 * 2 } == 42)
    }

    @Test("withWriteLock returns the closure's result and can mutate the value")
    func withWriteLockMutates() {
        let lock = RWLock(0)

        let returned = lock.withWriteLock { value -> String in
            value = 42
            return "done"
        }

        #expect(returned == "done")
        #expect(lock.withReadLock { $0 } == 42)
    }

    @Test("withReadLock propagates a thrown error and still unlocks")
    func withReadLockRethrows() {
        struct Boom: Error {}
        let lock = RWLock(1)

        #expect(throws: Boom.self) {
            try lock.withReadLock { _ throws(Boom) in throw Boom() }
        }

        // If the failing call had leaked the read lock, this would deadlock.
        lock.withWriteLock { $0 = 2 }
        #expect(lock.withReadLock { $0 } == 2)
    }

    @Test("withWriteLock propagates a thrown error and still unlocks")
    func withWriteLockRethrows() {
        struct Boom: Error {}
        let lock = RWLock(1)

        #expect(throws: Boom.self) {
            try lock.withWriteLock { _ throws(Boom) in throw Boom() }
        }

        // If the failing call had leaked the write lock, this would deadlock.
        #expect(lock.withWriteLock { $0 } == 1)
    }

    @Test("readers run concurrently")
    func concurrentReaders() {
        let lock = RWLock(7)
        let firstReaderIn = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let firstReaderOut = DispatchSemaphore(value: 0)

        // A dedicated thread, deliberately not a global-queue block: the test
        // runner schedules every test as a task on the cooperative pool, which
        // is as wide as the machine has cores and never grows. On a small CI
        // host the blocking tests in this suite can occupy that entire pool at
        // once, and a helper enqueued on a global queue then never gets a
        // thread to signal from — a deadlock the 3-core runners reproduced
        // reliably. A detached thread runs no matter what the pools are doing.
        Thread.detachNewThread {
            lock.withReadLock { _ in
                firstReaderIn.signal()
                release.wait()
            }
            firstReaderOut.signal()
        }

        firstReaderIn.wait()
        // A second reader must get in while the first still holds the lock; if
        // readers excluded each other this would return nil (or deadlock in
        // the blocking variant).
        #expect(lock.withReadLockIfAvailable { $0 } == 7)
        release.signal()
        firstReaderOut.wait()
    }

    @Test("a reader blocks writers but not readers")
    func readerBlocksWriters() {
        let lock = RWLock(0)
        let readerIn = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readerOut = DispatchSemaphore(value: 0)

        // A dedicated thread for the reason documented in `concurrentReaders`.
        Thread.detachNewThread {
            lock.withReadLock { _ in
                readerIn.signal()
                release.wait()
            }
            readerOut.signal()
        }

        readerIn.wait()
        #expect(lock.withWriteLockIfAvailable { _ in } == nil)
        #expect(lock.withReadLockIfAvailable { $0 } == 0)
        release.signal()
        readerOut.wait()
    }

    @Test("a writer blocks both readers and writers")
    func writerBlocksEveryone() {
        let lock = RWLock(0)
        let writerIn = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writerOut = DispatchSemaphore(value: 0)

        // A dedicated thread for the reason documented in `concurrentReaders`.
        Thread.detachNewThread {
            lock.withWriteLock { _ in
                writerIn.signal()
                release.wait()
            }
            writerOut.signal()
        }

        writerIn.wait()
        #expect(lock.withReadLockIfAvailable { $0 } == nil)
        #expect(lock.withWriteLockIfAvailable { _ in } == nil)
        release.signal()
        writerOut.wait()
    }

    @Test("holds a noncopyable value")
    func noncopyableValue() {
        struct Token: ~Copyable {
            var id: Int
        }

        let lock = RWLock(Token(id: 1))
        lock.withWriteLock { $0.id = 99 }
        #expect(lock.withReadLock { $0.id } == 99)
    }

    @Test("serializes concurrent mutation")
    func mutualExclusion() {
        let lock = RWLock(0)
        let iterations = 50_000
        let threads = 8

        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0 ..< iterations {
                lock.withWriteLock { $0 += 1 }
            }
        }

        #expect(lock.withReadLock { $0 } == iterations * threads)
    }

    @Test("readers never observe a torn write")
    func readersSeeConsistentState() {
        // Writers keep two counters in lockstep; a reader that ever sees them
        // disagree has read mid-write.
        struct Pair {
            var first = 0
            var second = 0
        }

        let lock = RWLock(Pair())
        let violations = RWLock(0)
        let iterations = 20_000
        let workers = 8

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            if worker.isMultiple(of: 2) {
                for _ in 0 ..< iterations {
                    lock.withWriteLock {
                        $0.first += 1
                        $0.second += 1
                    }
                }
            } else {
                for _ in 0 ..< iterations {
                    let torn = lock.withReadLock { $0.first != $0.second }
                    if torn {
                        violations.withWriteLock { $0 += 1 }
                    }
                }
            }
        }

        #expect(violations.withReadLock { $0 } == 0)
        let expected = (workers / 2) * iterations
        #expect(lock.withReadLock { $0.first } == expected)
        #expect(lock.withReadLock { $0.second } == expected)
    }

    @Test("readers see a consistent snapshot across many slots")
    func readersSeeConsistentSnapshot() {
        // Writers move value between two random slots without changing the
        // total; readers sum every slot. Any reader overlapping a writer —
        // or missing a write that happened before its lock — observes a
        // different total. The many-slot spread makes this sensitive to
        // memory-visibility bugs a single counter would miss.
        let slotCount = 256
        let initialTotal = slotCount * 1000
        let lock = RWLock([Int](repeating: 1000, count: slotCount))
        let violations = RWLock(0)
        let iterations = 10_000
        let workers = 8

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var state = UInt64(worker &+ 1)
            func nextRandom() -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int(truncatingIfNeeded: state >> 33)
            }

            if worker.isMultiple(of: 2) {
                for _ in 0 ..< iterations {
                    let source = nextRandom() % slotCount
                    let destination = nextRandom() % slotCount
                    let amount = nextRandom() % 100
                    lock.withWriteLock {
                        $0[source] -= amount
                        $0[destination] += amount
                    }
                }
            } else {
                for _ in 0 ..< iterations {
                    let total = lock.withReadLock { $0.reduce(0, +) }
                    if total != initialTotal {
                        violations.withWriteLock { $0 += 1 }
                    }
                }
            }
        }

        #expect(violations.withReadLock { $0 } == 0)
        #expect(lock.withReadLock { $0.reduce(0, +) } == initialTotal)
    }

    @Test("IfAvailable variants succeed on an uncontended lock")
    func ifAvailableUncontended() {
        let lock = RWLock(7)
        #expect(lock.withReadLockIfAvailable { $0 } == 7)
        #expect(lock.withWriteLockIfAvailable { value -> Int in
            value = 8
            return value
        } == 8)
        #expect(lock.withReadLock { $0 } == 8)
    }

    #if canImport(Darwin)
    @Test("stores its value inline rather than in a heap box")
    func inlineStorage() {
        // The Darwin handle is an unfair lock, two 32-bit atomics, and two
        // mach semaphore ports: 20 bytes, padding to 24 before an 8-aligned
        // Int. Only inline storage produces this layout; a boxed
        // implementation would be pointer sized.
        #expect(MemoryLayout<RWLock<Int>>.size == 32)
        #expect(MemoryLayout<RWLock<Int>>.alignment == 8)
    }
    #endif
}
