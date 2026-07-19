//
//  MutexTests.swift
//  SynchronizationKit
//

import Dispatch
import Testing

@testable import SynchronizationKitMutex

@Suite("Mutex")
struct MutexTests {
    @Test("withLock returns the closure's result and can mutate the value")
    func withLockMutates() {
        let mutex = Mutex(0)

        let returned = mutex.withLock { value -> String in
            value = 42
            return "done"
        }

        #expect(returned == "done")
        #expect(mutex.withLock { $0 } == 42)
    }

    @Test("withLock propagates a thrown error and still unlocks")
    func withLockRethrows() {
        struct Boom: Error {}
        let mutex = Mutex(1)

        #expect(throws: Boom.self) {
            try mutex.withLock { _ throws(Boom) in throw Boom() }
        }

        // If the failing call had leaked the lock, this would deadlock.
        #expect(mutex.withLock { $0 } == 1)
    }

    @Test("withLockIfAvailable succeeds on an uncontended lock")
    func withLockIfAvailableUncontended() {
        let mutex = Mutex(7)
        #expect(mutex.withLockIfAvailable { $0 } == 7)
    }

    @Test("withLockIfAvailable returns nil while another thread holds the lock")
    func withLockIfAvailableContended() {
        let mutex = Mutex(0)
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            mutex.withLock { _ in
                acquired.signal()
                release.wait()
            }
        }

        acquired.wait()
        let result = mutex.withLockIfAvailable { $0 }
        release.signal()

        #expect(result == nil)
    }

    @Test("holds a noncopyable value")
    func noncopyableValue() {
        struct Token: ~Copyable {
            var id: Int
        }

        let mutex = Mutex(Token(id: 1))
        mutex.withLock { $0.id = 99 }
        #expect(mutex.withLock { $0.id } == 99)
    }

    @Test("serializes concurrent mutation")
    func mutualExclusion() {
        let mutex = Mutex(0)
        let iterations = 50_000
        let threads = 8

        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0 ..< iterations {
                mutex.withLock { $0 += 1 }
            }
        }

        #expect(mutex.withLock { $0 } == iterations * threads)
    }

    @Test("stores its value inline rather than in a heap box")
    func inlineStorage() {
        // An `os_unfair_lock` is 4 bytes and pads to 8 alongside an Int, which
        // is only true if both the lock and the value live inside the `Mutex`
        // itself. A boxed implementation would be pointer sized.
        #expect(MemoryLayout<Mutex<Int>>.size == 16)
        #expect(MemoryLayout<Mutex<Int>>.alignment == 8)
        #expect(MemoryLayout<Mutex<Void>>.size == 4)
    }
}
