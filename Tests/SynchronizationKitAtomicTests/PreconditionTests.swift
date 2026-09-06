//
//  PreconditionTests.swift
//  SynchronizationKit
//

// Exit tests, on the platforms the testing library documents them for; the
// macro is unavailable on the rest, which is a compile error rather than a
// skip. Not gated on which implementation is under test: the checked
// operations trap on overflow in both, and a package whose claim is that the
// two read the same has to hold them to the same failure.
#if os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows)
import Testing

@testable import SynchronizationKitAtomic

@Suite("Atomic preconditions")
struct PreconditionTests {
    /// `add` is the checked form; `wrappingAdd` is the one that would not
    /// trap here, and the suite for it says so.
    @Test("a checked add that overflows traps")
    func overflowingAddTraps() async {
        await #expect(processExitsWith: .failure) {
            Atomic<Int8>(.max).add(1, ordering: .relaxed)
        }
    }

    @Test("a checked subtract that overflows traps")
    func overflowingSubtractTraps() async {
        await #expect(processExitsWith: .failure) {
            Atomic<Int8>(.min).subtract(1, ordering: .relaxed)
        }
    }
}
#endif
