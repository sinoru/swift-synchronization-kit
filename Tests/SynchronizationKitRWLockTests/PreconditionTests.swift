//
//  PreconditionTests.swift
//  SynchronizationKit
//

// Exit tests, on the platforms the testing library documents them for; the
// macro is unavailable on the rest, which is a compile error rather than a
// skip. Narrowed further to the backend built here: glibc's
// `pthread_rwlock_unlock` does not check who holds the lock, so an unbalanced
// unlock there is undefined rather than a trap, and there is nothing to
// expect.
#if os(macOS)
import SynchronizationKitMutex
import Testing

@testable import SynchronizationKitRWLock

/// The two counter checks the handle makes on the way out of a lock. Both
/// are reachable only through the handle — the public API pairs every lock
/// with its unlock — and both guard a state the comment on `_writeUnlock`
/// calls the least diagnosable way for a lock to fail: parking every queued
/// reader forever.
@Suite("RWLock preconditions")
struct PreconditionTests {
    @Test("a read unlock without a read lock traps")
    func unbalancedReadUnlockTraps() async {
        await #expect(processExitsWith: .failure) {
            // A counted unlock; a published one has a slot to hand back.
            unsafe _RWLockHandle()._readUnlock(nil)
        }
    }

    /// The writer mutex is taken first, on purpose. Without that, the unlock
    /// would trap a few lines past the counter check regardless — an unfair
    /// lock objects to being unlocked by nobody — and an exit alone would not
    /// say which check fired. With the mutex held, only the counter can
    /// object, and a release build reports no message to tell them apart by.
    @Test("a write unlock without a write lock traps")
    func unbalancedWriteUnlockTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _RWLockHandle()
            handle.writerMutex._unsafeLock()
            handle._writeUnlock()
        }
    }
}
#endif
