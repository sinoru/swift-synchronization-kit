//
//  PreconditionTests.swift
//  SynchronizationKit
//

// Exit tests, on the platforms the testing library documents them for; the
// macro is unavailable on the rest, which is a compile error rather than a
// skip.
#if os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows)
import SynchronizationKitTestUtils
import Testing

@testable import SynchronizationKitAsyncRWLock

/// The invariants the handoff rests on, each reachable only through the
/// handle: the public API pairs every acquire with its release.
@Suite("AsyncRWLock preconditions")
struct PreconditionTests {
    @Test("write-unlocking a lock nobody holds for writing traps")
    func writeUnlockWhileNotHeldTraps() async {
        await #expect(processExitsWith: .failure) {
            _AsyncRWLockHandle()._writeUnlock()
        }
    }

    @Test("read-unlocking from a task that does not hold the lock traps")
    func readUnlockWhileNotHeldTraps() async {
        await #expect(processExitsWith: .failure) {
            _AsyncRWLockHandle()._readUnlock()
        }
    }
}
#endif
