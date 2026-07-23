//
//  AtomicIntegers.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
// MARK: - Conformances

// Signed types reinterpret their bits as the matching unsigned storage rather
// than converting numerically, so the round trip is exact for negative values
// too.

extension Int8: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic8BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Int8
    ) -> _Atomic8BitStorage {
        _Atomic8BitStorage(_rawValue: UInt8(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic8BitStorage
    ) -> Int8 {
        Int8(bitPattern: storage._rawValue)
    }
}

extension Int16: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic16BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Int16
    ) -> _Atomic16BitStorage {
        _Atomic16BitStorage(_rawValue: UInt16(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic16BitStorage
    ) -> Int16 {
        Int16(bitPattern: storage._rawValue)
    }
}

extension Int32: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic32BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Int32
    ) -> _Atomic32BitStorage {
        _Atomic32BitStorage(_rawValue: UInt32(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic32BitStorage
    ) -> Int32 {
        Int32(bitPattern: storage._rawValue)
    }
}

extension Int64: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic64BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Int64
    ) -> _Atomic64BitStorage {
        _Atomic64BitStorage(_rawValue: UInt64(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic64BitStorage
    ) -> Int64 {
        Int64(bitPattern: storage._rawValue)
    }
}

extension Int: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Int
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> Int {
        Int(bitPattern: storage._rawValue)
    }
}

extension UInt8: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic8BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UInt8
    ) -> _Atomic8BitStorage {
        _Atomic8BitStorage(_rawValue: value)
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic8BitStorage
    ) -> UInt8 {
        storage._rawValue
    }
}

extension UInt16: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic16BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UInt16
    ) -> _Atomic16BitStorage {
        _Atomic16BitStorage(_rawValue: value)
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic16BitStorage
    ) -> UInt16 {
        storage._rawValue
    }
}

extension UInt32: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic32BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UInt32
    ) -> _Atomic32BitStorage {
        _Atomic32BitStorage(_rawValue: value)
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic32BitStorage
    ) -> UInt32 {
        storage._rawValue
    }
}

extension UInt64: AtomicRepresentable {
    public typealias AtomicRepresentation = _Atomic64BitStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UInt64
    ) -> _Atomic64BitStorage {
        _Atomic64BitStorage(_rawValue: value)
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _Atomic64BitStorage
    ) -> UInt64 {
        storage._rawValue
    }
}

extension UInt: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UInt
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: value)
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UInt {
        storage._rawValue
    }
}

// MARK: - Integer operations

// Each operation below is a single instruction, not a read followed by a write,
// so concurrent callers cannot lose each other's updates the way `value =
// value + 1` would.
//
// One extension covers every width: `_AtomicStorage` supplies the operations
// for whatever width the type encodes into, and `Magnitude` is what ties a
// signed integer to the unsigned storage holding its bits.
// Repeats the type's deprecation so the package does not warn about itself;
// see the note above the `Sendable` conformance in Atomic.swift.
@available(macOS, deprecated: 15.0, message: "Use Synchronization.Atomic instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(iOS, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(tvOS, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(watchOS, deprecated: 11.0, message: "Use Synchronization.Atomic instead")
@available(visionOS, deprecated: 2.0, message: "Use Synchronization.Atomic instead")
extension Atomic
where
    Value: FixedWidthInteger,
    Value.AtomicRepresentation: _AtomicStorage,
    Value.AtomicRepresentation._RawValue == Value.Magnitude
{
    /// Adds `operand`, wrapping on overflow.
    ///
    /// Wrapping is what the hardware does, and trapping would mean checking the
    /// result after the fact — by which point another thread may already have
    /// changed it. Use `add(_:ordering:)` when overflow should be caught.
    ///
    /// - Parameter operand: The amount to add.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func wrappingAdd(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        let original = unsafe Self._decode(
            Value.AtomicRepresentation._fetchAdd(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
        )
        return (oldValue: original, newValue: original &+ operand)
    }

    /// Subtracts `operand`, wrapping on underflow.
    ///
    /// - Parameter operand: The amount to subtract.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func wrappingSubtract(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        let original = unsafe Self._decode(
            Value.AtomicRepresentation._fetchSubtract(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
        )
        return (oldValue: original, newValue: original &- operand)
    }

    /// Replaces the value with its bitwise AND against `operand`.
    ///
    /// - Parameter operand: The mask to apply.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func bitwiseAnd(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        let original = unsafe Self._decode(
            Value.AtomicRepresentation._fetchAnd(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
        )
        return (oldValue: original, newValue: original & operand)
    }

    /// Replaces the value with its bitwise OR against `operand`.
    ///
    /// Setting a bit this way is how several threads can each contribute flags
    /// to one word without a lock.
    ///
    /// - Parameter operand: The bits to set.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func bitwiseOr(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        let original = unsafe Self._decode(
            Value.AtomicRepresentation._fetchOr(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
        )
        return (oldValue: original, newValue: original | operand)
    }

    /// Replaces the value with its bitwise XOR against `operand`.
    ///
    /// - Parameter operand: The bits to flip.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func bitwiseXor(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        let original = unsafe Self._decode(
            Value.AtomicRepresentation._fetchXor(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
        )
        return (oldValue: original, newValue: original ^ operand)
    }

    /// Lowers the value to `operand` if `operand` is smaller, leaving it alone
    /// otherwise.
    ///
    /// The comparison follows `Value`'s own signedness, so a negative stored
    /// value really is the smaller one.
    ///
    /// - Parameter operand: The candidate minimum.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func min(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        // `isSigned` is a static property of a concrete type, so this selects a
        // branch at compile time rather than at run time.
        let raw = Value.isSigned
            ? unsafe Value.AtomicRepresentation._fetchSignedMin(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
            : unsafe Value.AtomicRepresentation._fetchUnsignedMin(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )

        let original = Self._decode(raw)
        return (oldValue: original, newValue: Swift.min(original, operand))
    }

    /// Raises the value to `operand` if `operand` is larger, leaving it alone
    /// otherwise.
    ///
    /// Useful for a high-water mark that several threads report into.
    ///
    /// - Parameter operand: The candidate maximum.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func max(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        let raw = Value.isSigned
            ? unsafe Value.AtomicRepresentation._fetchSignedMax(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )
            : unsafe Value.AtomicRepresentation._fetchUnsignedMax(
                _rawAddress, Self._encode(operand), ordering._rawValue
            )

        let original = Self._decode(raw)
        return (oldValue: original, newValue: Swift.max(original, operand))
    }

    /// Adds `operand`, trapping on overflow.
    ///
    /// No instruction both adds and traps, so this is a compare-exchange retry
    /// loop with an ordinary `+` inside it. That costs more than
    /// `wrappingAdd(_:ordering:)` and can spin under contention; prefer the
    /// wrapping form when the value cannot overflow. Overflow checking is
    /// omitted in `-Ounchecked` builds, as it is everywhere else.
    ///
    /// - Parameter operand: The amount to add.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func add(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        var result = (exchanged: false, original: load(ordering: .relaxed))
        var new: Value

        repeat {
            new = result.original + operand

            result = weakCompareExchange(
                expected: result.original,
                desired: new,
                ordering: ordering
            )
        } while !result.exchanged

        return (oldValue: result.original, newValue: new)
    }

    /// Subtracts `operand`, trapping on underflow.
    ///
    /// Like `add(_:ordering:)`, this is a compare-exchange retry loop rather
    /// than a single instruction.
    ///
    /// - Parameter operand: The amount to subtract.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value before and after this operation.
    @discardableResult
    @_transparent
    public borrowing func subtract(
        _ operand: Value,
        ordering: AtomicUpdateOrdering
    ) -> (oldValue: Value, newValue: Value) {
        var result = (exchanged: false, original: load(ordering: .relaxed))
        var new: Value

        repeat {
            new = result.original - operand

            result = weakCompareExchange(
                expected: result.original,
                desired: new,
                ordering: ordering
            )
        } while !result.exchanged

        return (oldValue: result.original, newValue: new)
    }
}
#endif
