//
//  BackendTests.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Dispatch
import Foundation
import SynchronizationKitAtomic
import SynchronizationKitTestUtils
import Testing

@testable import SynchronizationKitSemaphore

/// Which of Darwin's two backends is in play, and what only each has.
@Suite("Semaphore backend")
struct BackendTests {
    /// What a semaphore picks must be what the running OS can actually do.
    ///
    /// Two answers to the same question, from either side of the language
    /// boundary: Swift's `#available` here against the `__builtin_available` the
    /// C shim decides it by. They can only disagree if one of them is wrong.
    ///
    /// This says nothing on a runtime newer than the versions named — above
    /// them both a correct guard and a broken one pass. It is not what catches a
    /// platform missing from the shim's guard; the shim makes that a compile
    /// error on the platform in question.
    /// One word for the handle, and the initial count beside it: the size
    /// `RWLock`'s two gates are budgeted at, and what keeps that lock at the
    /// 32 bytes its own suite pins.
    ///
    /// Spelled with a module selector because `Foundation` is imported here,
    /// and with it the platform overlay's `Semaphore` — the pointer type
    /// `sem_open` returns — which makes the bare name ambiguous in type
    /// position. The type's documentation says so; this is the one place in
    /// the suites that has to live with it.
    @Test("a semaphore is one word, plus the count it started at")
    func layout() {
        #expect(MemoryLayout<_SemaphoreHandle>.size == 4)
        #expect(MemoryLayout<SynchronizationKitSemaphore::Semaphore>.size == 8)
    }

    @Test("the backend in use matches what the OS provides")
    func backendMatchesTheOS() {
        if #available(macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, visionOS 1.1, *) {
            #expect(_addressWaitIsAvailable)
        } else {
            #expect(!_addressWaitIsAvailable)
        }
    }
}

/// The address-based backend's word, which is the count itself.
@Suite(
    "Semaphore address-based backend",
    .enabled(if: _addressWaitIsAvailable)
)
struct AddressWaitTests {
    @Test("the word is the count")
    func wordIsTheCount() {
        let semaphore = Semaphore(value: 3)
        #expect(semaphore.handle.word.load(ordering: .relaxed) == 3)

        semaphore.wait()
        #expect(semaphore.handle.word.load(ordering: .relaxed) == 2)

        semaphore.signal()
        semaphore.signal()
        #expect(semaphore.handle.word.load(ordering: .relaxed) == 4)

        // Back to where it started, so that `deinit` has nothing to object to.
        semaphore.wait()
    }
}

/// The Mach semaphore backend's ports, and when they come to exist.
///
/// A port is an entry in the task's name space, and the kernel treats a
/// process that fills its name space as leaking rather than as busy. A
/// semaphore created at zero — every `RWLock` gate, and every one used as an
/// event — gets no port until a thread actually has to block or signal, which
/// is what keeps them cheap in bulk. A positive count has permits to hold from
/// the start, and gets its port with them.
///
/// Only a release predating the address-based calls runs this backend, so only
/// there is there anything here to observe. CI reaches this suite through its
/// pinned pre-17.4 simulator runtime.
@Suite(
    "Semaphore Mach backend ports",
    .enabled(if: !_addressWaitIsAvailable)
)
struct SemaphorePortTests {
    @Test("a zero count creates no port until a thread needs one")
    func zeroCountCreatesNoPort() {
        let semaphore = Semaphore(value: 0)
        #expect(semaphore.handle.word.load(ordering: .relaxed) == 0)

        semaphore.signal()
        #expect(semaphore.handle.word.load(ordering: .relaxed) != 0)

        // The permit signalled before the port existed has to have reached it.
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            semaphore.wait()
            done.signal()
        }
        expectSignal(done, "a permit signalled before the port existed was lost")
    }

    @Test("a positive count creates its port with the count")
    func positiveCountCreatesItsPort() {
        let semaphore = Semaphore(value: 2)
        #expect(semaphore.handle.word.load(ordering: .relaxed) != 0)

        // Both permits promised at creation are in the port.
        semaphore.wait()
        semaphore.wait()

        // Leave the count where it started.
        semaphore.signal()
        semaphore.signal()
    }
}
#endif
