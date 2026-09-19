//
//  ReentrancyTests.swift
//  SynchronizationKit
//

// Exit tests, on the platforms the testing library documents them for and
// this package has a backend that recognizes the wait: its own on macOS and
// Windows, and on Linux either its own, over musl, or glibc's, which reports
// the wait as `EDEADLK`. FreeBSD and OpenBSD take the pthread backend too,
// and whether theirs reports it is not established here.
#if os(macOS) || os(Linux) || os(Windows)
import Testing

import SynchronizationKitRWLock

/// A thread asking for a lock it holds for writing would wait for its own
/// unlock, and traps instead. Taken through the handle, as the other
/// preconditions are, so that the child process has nothing to set up past
/// the two calls.
@Suite("RWLock reentrancy")
struct ReentrancyTests {
    @Test("reading inside a write section traps")
    func readInsideWriteTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _RWLockHandle()
            handle._writeLock()
            _ = unsafe handle._readLock()
        }
    }

    @Test("writing inside a write section traps")
    func writeInsideWriteTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _RWLockHandle()
            handle._writeLock()
            handle._writeLock()
        }
    }
}
#endif
