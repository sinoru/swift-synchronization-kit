//
//  PreconditionTests.swift
//  SynchronizationKit
//

// Exit tests, on the platforms the testing library documents them for; the
// macro is unavailable on the rest, which is a compile error rather than a
// skip.
#if os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows)
import SynchronizationKitAsyncSemaphore
import Testing

/// The one precondition a caller can reach. The `deinit` check — no waiter
/// may be queued — cannot be provoked from outside, because a waiting task
/// holds the semaphore; `AsyncSemaphoreTests` shows that instead.
@Suite("AsyncSemaphore preconditions")
struct PreconditionTests {
    @Test("a negative initial value traps")
    func negativeValueTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = AsyncSemaphore(value: -1)
        }
    }
}
#endif
