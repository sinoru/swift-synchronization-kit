//
//  MutexTests.swift
//  SynchronizationKit
//

// Deliberately not gated on platform, unlike the module it tests. On Apple
// targets these run against this package's `Mutex`; everywhere else against
// the standard library's, which the module re-exports — and a package whose
// whole claim is that the two read the same has to say so somewhere that
// compiles on both. It is also the first thing to cover the Mutex side of a
// failure the Atomic side caught by luck: a forwarding type alias carries the
// name but not `withLock`, which was true here once with nothing to notice.
import Dispatch
import Foundation
import SynchronizationKitTestSupport
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

        // A dedicated thread, deliberately not a global-queue block: the test
        // runner schedules every test as a task on the cooperative pool, which
        // is as wide as the machine has cores and never grows. On a small CI
        // host the blocking tests across these suites can occupy that entire
        // pool at once, and a helper enqueued on a global queue then never
        // gets a thread to signal from — a deadlock. A detached thread runs no
        // matter what the pools are doing.
        Thread.detachNewThread {
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

    // ThreadSanitizer does not model the standard library's Linux mutex: its
    // contended lock and unlock happen in a futex the instrumentation does not
    // intercept, so all eight threads' writes inside `withLock` read as
    // unsynchronized and every run reports a race. The count still comes out
    // exact, which is what says the race is the sanitizer's and not the lock's
    // — the same conclusion `MutualExclusionTests` records for the Mach
    // semaphore backend, except that one is this package's own code and could
    // be annotated. This one cannot be.
    //
    // Where the lock is this package's it is `os_unfair_lock`, which the
    // sanitizer does model, so the test stays live there and that is where the
    // sanitized coverage of this property lives.
    @Test(
        "serializes concurrent mutation",
        .disabled(
            if: !implementationIsThisPackage && threadSanitizerIsLoaded,
            "ThreadSanitizer does not model the standard library's Linux mutex."
        )
    )
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

    // Conditional for a different reason than the test above, which turns on
    // the sanitizer: these numbers are this package's own. They follow from
    // `os_unfair_lock` being 4 bytes on a 64-bit Apple target; the standard
    // library's handle is a futex word of the same size on Linux, which is why
    // this would happen to pass there too, but an 8-byte `SRWLOCK` on Windows
    // and a 4-byte pointer on wasm32 make it fail. Nothing in
    // `Synchronization`'s contract fixes the size either way, so off Apple this
    // would assert something the package cannot regress.
    @Test(
        "stores its value inline rather than in a heap box",
        .enabled(
            if: implementationIsThisPackage,
            "The layout asserted here is this package's own."
        )
    )
    func inlineStorage() {
        // An `os_unfair_lock` is 4 bytes and pads to 8 alongside an Int, which
        // is only true if both the lock and the value live inside the `Mutex`
        // itself. A boxed implementation would be pointer sized.
        #expect(MemoryLayout<Mutex<Int>>.size == 16)
        #expect(MemoryLayout<Mutex<Int>>.alignment == 8)
        #expect(MemoryLayout<Mutex<Void>>.size == 4)
    }
}
