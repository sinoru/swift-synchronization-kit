//
//  ReentrancyTests.swift
//  SynchronizationKit
//

// Debug only: these tests reach internal declarations through `@testable`,
// which a release build does not leave open.
#if DEBUG

// Exit tests, on the platforms the testing library documents them for; the
// macro is unavailable on the rest, which is a compile error rather than a
// skip.
#if os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows)
import Testing

@testable import SynchronizationKitAsyncMutex

/// A task asking for a lock it holds would wait for its own release, and
/// traps instead, however it asks.
@Suite("AsyncMutex reentrancy")
struct ReentrancyTests {
    @Test("locking from the task holding the lock traps")
    func lockInsideLockTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _AsyncMutexHandle()
            try await handle._lock()
            try await handle._lock()
        }
    }

    /// A synchronous caller inside the task holds and waits as that task.
    @Test("blocking on the lock from inside the task holding it traps")
    func blockingInsideLockTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _AsyncMutexHandle()
            try await handle._lock()
            let block = { handle._lockBlocking() }
            block()
        }
    }
}
#endif
#endif
