//
//  AtomicBool.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
extension Bool: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic8BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Bool
    ) -> _Atomic8BitStorage {
        _Atomic8BitStorage(_rawValue: value ? 1 : 0)
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic8BitStorage
    ) -> Bool {
        storage._rawValue != 0
    }
}

// MARK: - Logical operations

extension Atomic where Value == Bool {
    /// Replaces the value with its logical AND against `operand`.
    ///
    /// - Parameter operand: The value to combine in.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func logicalAnd(
        _ operand: Bool,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Bool, newValue: Bool) {
        // The encoded representation only ever holds 0 or 1, so the bitwise
        // operation on the byte and the logical operation agree.
        let original = unsafe Self._decode(
            _Atomic8BitStorage._fetchAnd(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
        )
        return (oldValue: original, newValue: original && operand)
    }

    /// Replaces the value with its logical OR against `operand`.
    ///
    /// Setting a flag this way reports whether it was already set, which is how
    /// several threads can race to claim a one-time action and have exactly one
    /// of them win.
    ///
    /// - Parameter operand: The value to combine in.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func logicalOr(
        _ operand: Bool,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Bool, newValue: Bool) {
        let original = unsafe Self._decode(
            _Atomic8BitStorage._fetchOr(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
        )
        return (oldValue: original, newValue: original || operand)
    }

    /// Replaces the value with its logical XOR against `operand`.
    ///
    /// - Parameter operand: The value to combine in.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func logicalXor(
        _ operand: Bool,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Bool, newValue: Bool) {
        let original = unsafe Self._decode(
            _Atomic8BitStorage._fetchXor(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
        )
        return (oldValue: original, newValue: original != operand)
    }
}
#endif
