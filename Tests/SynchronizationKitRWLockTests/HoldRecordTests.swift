//
//  HoldRecordTests.swift
//  SynchronizationKit
//

import SynchronizationKitRWLock
import Testing

/// The record a build with assertions enabled keeps of the locks a thread
/// holds: that it traps on every nesting of one instance's locking that
/// waits, and that it reports nothing it should not.
@Suite("RWLock hold record")
struct HoldRecordTests {
    // Exit tests, on the platforms the testing library documents them for
    // and the record is kept on, and only where this file is built with
    // assertions enabled: without them the record is compiled away, and the
    // nestings below that no backend recognizes wait forever.
    #if DEBUG && (os(macOS) || os(Linux) || os(Windows))
    @Test("reading inside a read section traps, with no writer about")
    func readInsideReadTraps() async {
        await #expect(processExitsWith: .failure) {
            let lock = RWLock(0)
            lock.withReadLock { _ in
                lock.withReadLock { _ in }
            }
        }
    }

    @Test("writing inside a read section traps")
    func writeInsideReadTraps() async {
        await #expect(processExitsWith: .failure) {
            let lock = RWLock(0)
            lock.withReadLock { _ in
                lock.withWriteLock { _ in }
            }
        }
    }

    @Test("reading inside a write section traps")
    func readInsideWriteTraps() async {
        await #expect(processExitsWith: .failure) {
            let lock = RWLock(0)
            lock.withWriteLock { _ in
                lock.withReadLock { _ in }
            }
        }
    }

    @Test("writing inside a write section traps")
    func writeInsideWriteTraps() async {
        await #expect(processExitsWith: .failure) {
            let lock = RWLock(0)
            lock.withWriteLock { _ in
                lock.withWriteLock { _ in }
            }
        }
    }
    #endif

    /// A method that never waits cannot wait on itself, and reports as the
    /// lock does: a read alongside the thread's own read, and nothing
    /// alongside its own write.
    @Test("the IfAvailable methods are not trapped inside a section")
    func ifAvailableInsideSectionIsNotTrapped() {
        let lock = RWLock(7)
        let read = lock.withReadLock { outer in
            lock.withReadLockIfAvailable { $0 + outer }
        }
        #expect(read == 14)
        let refused = lock.withWriteLock { _ in
            lock.withReadLockIfAvailable { _ in true }
        }
        #expect(refused == nil)
    }

    /// Other locks nest freely, past the holds the record keeps; and every
    /// hold is forgotten on the way out, or a lock later built at an address
    /// a forgotten one had — the stack's — would find it and trap.
    @Test("nesting distinct locks, deeper than the record, reports nothing")
    func nestingDistinctLocksIsNotTrapped() {
        func nest(_ depth: Int) -> Int {
            let lock = RWLock(1)
            return lock.withReadLock { value in
                depth == 0 ? value : value + nest(depth - 1)
            }
        }
        #expect(nest(40) == 41)
        #expect(nest(40) == 41)
    }

    @Test("a section that throws forgets its hold")
    func throwingSectionForgetsHold() {
        struct Failure: Error {}
        let lock = RWLock(0)
        #expect(throws: Failure.self) {
            try lock.withWriteLock { _ throws(Failure) in throw Failure() }
        }
        #expect(lock.withReadLock { $0 } == 0)
        #expect(lock.withWriteLock { $0 += 1; return $0 } == 1)
    }
}
