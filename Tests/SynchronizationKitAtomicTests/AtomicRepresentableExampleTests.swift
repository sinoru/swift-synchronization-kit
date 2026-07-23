//
//  AtomicRepresentableExampleTests.swift
//  SynchronizationKit
//

import Testing

import SynchronizationKitAtomic

// The `Cursor` conformance from `AtomicRepresentable`'s documentation,
// reproduced verbatim. Deliberately not gated on platform: on Apple targets it
// exercises this package's protocol and storage, elsewhere the standard
// library's that the package forwards to — a documented conformance has to
// compile against both.
private struct Cursor: Equatable {
    var line: Int32
    var column: Int32
}

extension Cursor: AtomicRepresentable {
    typealias AtomicRepresentation = UInt64.AtomicRepresentation

    static func encodeAtomicRepresentation(
        _ cursor: consuming Cursor
    ) -> AtomicRepresentation {
        let packed = UInt64(UInt32(bitPattern: cursor.line)) << 32
            | UInt64(UInt32(bitPattern: cursor.column))
        return UInt64.encodeAtomicRepresentation(packed)
    }

    static func decodeAtomicRepresentation(
        _ storage: consuming AtomicRepresentation
    ) -> Cursor {
        let packed = UInt64.decodeAtomicRepresentation(storage)
        return Cursor(
            line: Int32(bitPattern: UInt32(truncatingIfNeeded: packed >> 32)),
            column: Int32(bitPattern: UInt32(truncatingIfNeeded: packed))
        )
    }
}

@Suite("AtomicRepresentable documentation example")
struct AtomicRepresentableExampleTests {
    @Test("the Cursor conformance round-trips through an Atomic")
    func cursorRoundTrips() {
        let position = Atomic<Cursor>(Cursor(line: 1, column: 2))
        #expect(position.load(ordering: .acquiring) == Cursor(line: 1, column: 2))

        // Negative values exercise the sign bits of both packed halves.
        let previous = position.exchange(
            Cursor(line: -3, column: 40),
            ordering: .acquiringAndReleasing
        )
        #expect(previous == Cursor(line: 1, column: 2))
        #expect(position.load(ordering: .acquiring) == Cursor(line: -3, column: 40))

        position.store(Cursor(line: Int32.min, column: Int32.max), ordering: .releasing)
        #expect(
            position.load(ordering: .acquiring)
                == Cursor(line: Int32.min, column: Int32.max)
        )
    }
}
