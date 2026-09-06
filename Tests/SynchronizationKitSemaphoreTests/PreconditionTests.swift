//
//  PreconditionTests.swift
//  SynchronizationKit
//

// Exit tests: each body runs in a child process, and the test passes when
// that process dies the way a failed precondition kills it. The platforms
// are the ones the testing library documents exit tests for — macOS, Linux,
// FreeBSD, OpenBSD, and Windows — and the macro is declared unavailable on
// the rest, which is a compile error rather than a skip.
#if os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows)
import Testing

@testable import SynchronizationKitSemaphore

/// Whether the backend in use can read its count, and so check it in `deinit`.
///
/// Darwin's address-based path and the POSIX semaphores can; a Mach semaphore
/// and a Windows kernel object keep the count where nothing here can see it.
#if canImport(Darwin)
private let countIsReadable = _addressWaitIsAvailable
#elseif os(Windows)
private let countIsReadable = false
#else
private let countIsReadable = true
#endif

@Suite("Semaphore preconditions")
struct PreconditionTests {
    @Test("a negative initial value traps")
    func negativeValueTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = Semaphore(value: -1)
        }
    }

    /// The count is 32 bits wide on every backend, and `Int` is not.
    @Test("an initial value past Int32.max traps")
    func oversizedValueTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = Semaphore(value: Int(Int32.max) + 1)
        }
    }

    /// Only `RWLock` signals more than one permit at a time, and it never
    /// signals none; the handle refuses to be asked.
    @Test("signalling no permits traps")
    func signallingNothingTraps() async {
        await #expect(processExitsWith: .failure) {
            _SemaphoreHandle(value: 0)._signal(0)
        }
    }

    /// Synchronous on purpose: `wait()` is `noasync`, and an exit test's body
    /// is `async`, so the call has to sit in a function of its own.
    private static func takeAPermitAndLeave() {
        let semaphore = Semaphore(value: 1)
        semaphore.wait()
    }

    /// The `DispatchSemaphore` rule: a count that ends below where it started
    /// means a permit is still held, and the holder would be left with a
    /// semaphore that no longer exists.
    @Test(
        "deallocation with a permit still taken traps",
        .enabled(if: countIsReadable)
    )
    func deallocationWhileInUseTraps() async {
        await #expect(processExitsWith: .failure) {
            PreconditionTests.takeAPermitAndLeave()
        }
    }

    #if canImport(Darwin)
    /// Only the address-based backend can be driven past its limit in a test:
    /// its count is a 32-bit word and the handle takes a whole count per
    /// signal. `sem_post` refuses the same overflow with `EOVERFLOW`, but at
    /// `SEM_VALUE_MAX` calls in, which no test waits for.
    @Test(
        "a count past UInt32.max traps rather than wrapping",
        .enabled(if: _addressWaitIsAvailable)
    )
    func overflowTraps() async {
        await #expect(processExitsWith: .failure) {
            let handle = _SemaphoreHandle(value: 2)
            handle._signal(Int32.max)
            handle._signal(Int32.max)
        }
    }
    #endif
}
#endif
