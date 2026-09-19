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
import SynchronizationKitTestUtils
import Testing

@testable import SynchronizationKitAsyncRWLock

/// A task asking for a lock it holds, in a way that can only be served
/// after its own release, traps instead of waiting. The cases a recursive
/// read can still be served in are `AsyncRWLockTests`'.
@Suite("AsyncRWLock reentrancy")
struct ReentrancyTests {
    @Test("writing from the task holding the lock for writing traps")
    func writeInsideWriteTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _AsyncRWLockHandle()
            try await handle._writeLock()
            try await handle._writeLock()
        }
    }

    @Test("reading from the task holding the lock for writing traps")
    func readInsideWriteTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _AsyncRWLockHandle()
            try await handle._writeLock()
            try await handle._readLock()
        }
    }

    @Test("writing from a task holding the lock for reading traps")
    func writeInsideReadTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _AsyncRWLockHandle()
            try await handle._readLock()
            try await handle._writeLock()
        }
    }

    /// The writer arrived first at the reader's priority, so the reader
    /// queues behind it, and it waits for the reader.
    @Test("reading again behind a writer waiting for the reader traps")
    func readAgainBehindWriterTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _AsyncRWLockHandle()
            try await handle._readLock()
            _ = Task { try await handle._writeLock() }
            await handle.waitForWaiters(1)
            try await handle._readLock()
        }
    }
}
#endif
#endif
