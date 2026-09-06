//
//  PreconditionTests.swift
//  SynchronizationKit
//

// Exit tests, on the platforms the testing library documents them for; the
// macro is unavailable on the rest, which is a compile error rather than a
// skip.
#if os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows)
import SynchronizationKitAsyncCore
import SynchronizationKitTestUtils
import Testing

@testable import SynchronizationKitAsyncMutex

/// The invariants the handoff rests on, each reachable only through the
/// handle: the public API pairs every acquire with its release.
@Suite("AsyncMutex preconditions")
struct PreconditionTests {
    @Test("releasing a lock nobody holds traps")
    func releaseWhileNotHeldTraps() async {
        await #expect(processExitsWith: .failure) {
            _AsyncMutexHandle()._release()
        }
    }

    /// What `_release` hands the lock to has to be suspended on a
    /// continuation, or there is nothing to resume.
    @Test("granting a waiter that is not waiting traps")
    func grantingANonWaiterTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = unsafe _AsyncWaiter(task: nil, priority: .medium).grant()
        }
    }
}
#endif
