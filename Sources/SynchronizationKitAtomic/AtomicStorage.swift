//
//  AtomicStorage.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
import CSynchronizationKitAtomic

/// The primitive atomic operations available on a storage representation.
///
/// The standard library spells the equivalent of this out once per width via
/// gyb, because `Builtin.atomicrmw_*` names the width and the ordering in the
/// operation itself. The shim takes both as ordinary arguments, so the widths
/// differ only in which entry point they call and one protocol collapses all
/// of them into a single generic implementation of `Atomic`.
///
/// - Note: This protocol is an implementation detail. It is `public` only so
///   that `Atomic`'s public members can be constrained by it, mirroring how
///   the standard library exposes its own underscored storage types.
public protocol _AtomicStorage: BitwiseCopyable, Sendable {
    /// The unsigned integer whose bit pattern this storage holds.
    associatedtype _RawValue: FixedWidthInteger & UnsignedInteger & BitwiseCopyable & Sendable

    init(_rawValue: _RawValue)

    var _rawValue: _RawValue { get }

    static func _load(
        _ address: UnsafeMutableRawPointer,
        _ ordering: Int32
    ) -> _RawValue

    static func _store(
        _ address: UnsafeMutableRawPointer,
        _ desired: _RawValue,
        _ ordering: Int32
    )

    static func _exchange(
        _ address: UnsafeMutableRawPointer,
        _ desired: _RawValue,
        _ ordering: Int32
    ) -> _RawValue

    static func _compareExchange(
        _ address: UnsafeMutableRawPointer,
        _ expected: _RawValue,
        _ desired: _RawValue,
        _ weak: Bool,
        _ successOrdering: Int32,
        _ failureOrdering: Int32
    ) -> (exchanged: Bool, original: _RawValue)

    static func _fetchAdd(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue

    static func _fetchSubtract(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue

    static func _fetchAnd(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue

    static func _fetchOr(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue

    static func _fetchXor(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue

    /// Minimum treating both operands as unsigned — lowers to `atomicrmw umin`.
    static func _fetchUnsignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue

    /// Maximum treating both operands as unsigned — lowers to `atomicrmw umax`.
    static func _fetchUnsignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue

    /// Minimum treating both operands' bit patterns as signed — lowers to
    /// `atomicrmw min`.
    static func _fetchSignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue

    /// Maximum treating both operands' bit patterns as signed — lowers to
    /// `atomicrmw max`.
    static func _fetchSignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: _RawValue, _ ordering: Int32
    ) -> _RawValue
}

// MARK: - 8-bit storage

/// The 8-bit atomic storage representation.
@frozen
public struct _Atomic8BitStorage: _AtomicStorage {
    public var _rawValue: UInt8

    @_transparent
    public init(_rawValue: UInt8) {
        self._rawValue = _rawValue
    }

    @_transparent
    public static func _load(
        _ address: UnsafeMutableRawPointer, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_load_u8(address, ordering)
    }

    @_transparent
    public static func _store(
        _ address: UnsafeMutableRawPointer, _ desired: UInt8, _ ordering: Int32
    ) {
        unsafe sk_atomic_store_u8(address, desired, ordering)
    }

    @_transparent
    public static func _exchange(
        _ address: UnsafeMutableRawPointer, _ desired: UInt8, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_exchange_u8(address, desired, ordering)
    }

    @_transparent
    public static func _compareExchange(
        _ address: UnsafeMutableRawPointer,
        _ expected: UInt8,
        _ desired: UInt8,
        _ weak: Bool,
        _ successOrdering: Int32,
        _ failureOrdering: Int32
    ) -> (exchanged: Bool, original: UInt8) {
        var expected = expected
        let exchanged = withUnsafeMutablePointer(to: &expected) { slot in
            unsafe sk_atomic_compare_exchange_u8(
                address, slot, desired, weak, successOrdering, failureOrdering
            )
        }
        return (exchanged, expected)
    }

    @_transparent
    public static func _fetchAdd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_fetch_add_u8(address, operand, ordering)
    }

    @_transparent
    public static func _fetchSubtract(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_fetch_sub_u8(address, operand, ordering)
    }

    @_transparent
    public static func _fetchAnd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_fetch_and_u8(address, operand, ordering)
    }

    @_transparent
    public static func _fetchOr(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_fetch_or_u8(address, operand, ordering)
    }

    @_transparent
    public static func _fetchXor(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_fetch_xor_u8(address, operand, ordering)
    }

    @_transparent
    public static func _fetchUnsignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_fetch_min_u8(address, operand, ordering)
    }

    @_transparent
    public static func _fetchUnsignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        unsafe sk_atomic_fetch_max_u8(address, operand, ordering)
    }

    @_transparent
    public static func _fetchSignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        UInt8(
            bitPattern: unsafe sk_atomic_fetch_min_i8(
                address, Int8(bitPattern: operand), ordering
            )
        )
    }

    @_transparent
    public static func _fetchSignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt8, _ ordering: Int32
    ) -> UInt8 {
        UInt8(
            bitPattern: unsafe sk_atomic_fetch_max_i8(
                address, Int8(bitPattern: operand), ordering
            )
        )
    }
}

// MARK: - 16-bit storage

/// The 16-bit atomic storage representation.
@frozen
public struct _Atomic16BitStorage: _AtomicStorage {
    public var _rawValue: UInt16

    @_transparent
    public init(_rawValue: UInt16) {
        self._rawValue = _rawValue
    }

    @_transparent
    public static func _load(
        _ address: UnsafeMutableRawPointer, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_load_u16(address, ordering)
    }

    @_transparent
    public static func _store(
        _ address: UnsafeMutableRawPointer, _ desired: UInt16, _ ordering: Int32
    ) {
        unsafe sk_atomic_store_u16(address, desired, ordering)
    }

    @_transparent
    public static func _exchange(
        _ address: UnsafeMutableRawPointer, _ desired: UInt16, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_exchange_u16(address, desired, ordering)
    }

    @_transparent
    public static func _compareExchange(
        _ address: UnsafeMutableRawPointer,
        _ expected: UInt16,
        _ desired: UInt16,
        _ weak: Bool,
        _ successOrdering: Int32,
        _ failureOrdering: Int32
    ) -> (exchanged: Bool, original: UInt16) {
        var expected = expected
        let exchanged = withUnsafeMutablePointer(to: &expected) { slot in
            unsafe sk_atomic_compare_exchange_u16(
                address, slot, desired, weak, successOrdering, failureOrdering
            )
        }
        return (exchanged, expected)
    }

    @_transparent
    public static func _fetchAdd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_fetch_add_u16(address, operand, ordering)
    }

    @_transparent
    public static func _fetchSubtract(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_fetch_sub_u16(address, operand, ordering)
    }

    @_transparent
    public static func _fetchAnd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_fetch_and_u16(address, operand, ordering)
    }

    @_transparent
    public static func _fetchOr(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_fetch_or_u16(address, operand, ordering)
    }

    @_transparent
    public static func _fetchXor(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_fetch_xor_u16(address, operand, ordering)
    }

    @_transparent
    public static func _fetchUnsignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_fetch_min_u16(address, operand, ordering)
    }

    @_transparent
    public static func _fetchUnsignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        unsafe sk_atomic_fetch_max_u16(address, operand, ordering)
    }

    @_transparent
    public static func _fetchSignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        UInt16(
            bitPattern: unsafe sk_atomic_fetch_min_i16(
                address, Int16(bitPattern: operand), ordering
            )
        )
    }

    @_transparent
    public static func _fetchSignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt16, _ ordering: Int32
    ) -> UInt16 {
        UInt16(
            bitPattern: unsafe sk_atomic_fetch_max_i16(
                address, Int16(bitPattern: operand), ordering
            )
        )
    }
}

// MARK: - 32-bit storage

/// The 32-bit atomic storage representation.
@frozen
public struct _Atomic32BitStorage: _AtomicStorage {
    public var _rawValue: UInt32

    @_transparent
    public init(_rawValue: UInt32) {
        self._rawValue = _rawValue
    }

    @_transparent
    public static func _load(
        _ address: UnsafeMutableRawPointer, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_load_u32(address, ordering)
    }

    @_transparent
    public static func _store(
        _ address: UnsafeMutableRawPointer, _ desired: UInt32, _ ordering: Int32
    ) {
        unsafe sk_atomic_store_u32(address, desired, ordering)
    }

    @_transparent
    public static func _exchange(
        _ address: UnsafeMutableRawPointer, _ desired: UInt32, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_exchange_u32(address, desired, ordering)
    }

    @_transparent
    public static func _compareExchange(
        _ address: UnsafeMutableRawPointer,
        _ expected: UInt32,
        _ desired: UInt32,
        _ weak: Bool,
        _ successOrdering: Int32,
        _ failureOrdering: Int32
    ) -> (exchanged: Bool, original: UInt32) {
        var expected = expected
        let exchanged = withUnsafeMutablePointer(to: &expected) { slot in
            unsafe sk_atomic_compare_exchange_u32(
                address, slot, desired, weak, successOrdering, failureOrdering
            )
        }
        return (exchanged, expected)
    }

    @_transparent
    public static func _fetchAdd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_fetch_add_u32(address, operand, ordering)
    }

    @_transparent
    public static func _fetchSubtract(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_fetch_sub_u32(address, operand, ordering)
    }

    @_transparent
    public static func _fetchAnd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_fetch_and_u32(address, operand, ordering)
    }

    @_transparent
    public static func _fetchOr(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_fetch_or_u32(address, operand, ordering)
    }

    @_transparent
    public static func _fetchXor(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_fetch_xor_u32(address, operand, ordering)
    }

    @_transparent
    public static func _fetchUnsignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_fetch_min_u32(address, operand, ordering)
    }

    @_transparent
    public static func _fetchUnsignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        unsafe sk_atomic_fetch_max_u32(address, operand, ordering)
    }

    @_transparent
    public static func _fetchSignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        UInt32(
            bitPattern: unsafe sk_atomic_fetch_min_i32(
                address, Int32(bitPattern: operand), ordering
            )
        )
    }

    @_transparent
    public static func _fetchSignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt32, _ ordering: Int32
    ) -> UInt32 {
        UInt32(
            bitPattern: unsafe sk_atomic_fetch_max_i32(
                address, Int32(bitPattern: operand), ordering
            )
        )
    }
}

// MARK: - 64-bit storage

/// The 64-bit atomic storage representation.
@frozen
public struct _Atomic64BitStorage: _AtomicStorage {
    public var _rawValue: UInt64

    @_transparent
    public init(_rawValue: UInt64) {
        self._rawValue = _rawValue
    }

    @_transparent
    public static func _load(
        _ address: UnsafeMutableRawPointer, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_load_u64(address, ordering)
    }

    @_transparent
    public static func _store(
        _ address: UnsafeMutableRawPointer, _ desired: UInt64, _ ordering: Int32
    ) {
        unsafe sk_atomic_store_u64(address, desired, ordering)
    }

    @_transparent
    public static func _exchange(
        _ address: UnsafeMutableRawPointer, _ desired: UInt64, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_exchange_u64(address, desired, ordering)
    }

    @_transparent
    public static func _compareExchange(
        _ address: UnsafeMutableRawPointer,
        _ expected: UInt64,
        _ desired: UInt64,
        _ weak: Bool,
        _ successOrdering: Int32,
        _ failureOrdering: Int32
    ) -> (exchanged: Bool, original: UInt64) {
        var expected = expected
        let exchanged = withUnsafeMutablePointer(to: &expected) { slot in
            unsafe sk_atomic_compare_exchange_u64(
                address, slot, desired, weak, successOrdering, failureOrdering
            )
        }
        return (exchanged, expected)
    }

    @_transparent
    public static func _fetchAdd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_fetch_add_u64(address, operand, ordering)
    }

    @_transparent
    public static func _fetchSubtract(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_fetch_sub_u64(address, operand, ordering)
    }

    @_transparent
    public static func _fetchAnd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_fetch_and_u64(address, operand, ordering)
    }

    @_transparent
    public static func _fetchOr(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_fetch_or_u64(address, operand, ordering)
    }

    @_transparent
    public static func _fetchXor(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_fetch_xor_u64(address, operand, ordering)
    }

    @_transparent
    public static func _fetchUnsignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_fetch_min_u64(address, operand, ordering)
    }

    @_transparent
    public static func _fetchUnsignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        unsafe sk_atomic_fetch_max_u64(address, operand, ordering)
    }

    @_transparent
    public static func _fetchSignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        UInt64(
            bitPattern: unsafe sk_atomic_fetch_min_i64(
                address, Int64(bitPattern: operand), ordering
            )
        )
    }

    @_transparent
    public static func _fetchSignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt64, _ ordering: Int32
    ) -> UInt64 {
        UInt64(
            bitPattern: unsafe sk_atomic_fetch_max_i64(
                address, Int64(bitPattern: operand), ordering
            )
        )
    }
}

// MARK: - Word-width storage

#if _pointerBitWidth(_64)
@usableFromInline internal typealias _Word = _Atomic64BitStorage
#elseif _pointerBitWidth(_32)
@usableFromInline internal typealias _Word = _Atomic32BitStorage
#else
#error("Unsupported pointer bit width")
#endif

/// The atomic storage representation that is the width of a pointer, used by
/// `Int`, `UInt`, and the pointer types.
///
/// This forwards to whichever fixed-width storage matches the platform rather
/// than being a type alias for it, so that its `_RawValue` is `UInt` — the
/// `Magnitude` of `Int` and `UInt`. The generic integer operations rely on that
/// relationship, and `UInt` is a distinct type from both `UInt64` and `UInt32`
/// even where it has the same width.
@frozen
public struct _AtomicWordStorage: _AtomicStorage {
    public var _rawValue: UInt

    @_transparent
    public init(_rawValue: UInt) {
        self._rawValue = _rawValue
    }

    /// Widening `UInt` to the platform's word type and back is a no-op; these
    /// exist only to satisfy the type checker.
    @_transparent
    @usableFromInline
    internal static func _widen(_ value: UInt) -> _Word._RawValue {
        _Word._RawValue(value)
    }

    @_transparent
    @usableFromInline
    internal static func _narrow(_ value: _Word._RawValue) -> UInt {
        UInt(value)
    }

    @_transparent
    public static func _load(
        _ address: UnsafeMutableRawPointer, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._load(address, ordering))
    }

    @_transparent
    public static func _store(
        _ address: UnsafeMutableRawPointer, _ desired: UInt, _ ordering: Int32
    ) {
        unsafe _Word._store(address, _widen(desired), ordering)
    }

    @_transparent
    public static func _exchange(
        _ address: UnsafeMutableRawPointer, _ desired: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._exchange(address, _widen(desired), ordering))
    }

    @_transparent
    public static func _compareExchange(
        _ address: UnsafeMutableRawPointer,
        _ expected: UInt,
        _ desired: UInt,
        _ weak: Bool,
        _ successOrdering: Int32,
        _ failureOrdering: Int32
    ) -> (exchanged: Bool, original: UInt) {
        let (exchanged, original) = unsafe _Word._compareExchange(
            address,
            _widen(expected),
            _widen(desired),
            weak,
            successOrdering,
            failureOrdering
        )
        return (exchanged, _narrow(original))
    }

    @_transparent
    public static func _fetchAdd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchAdd(address, _widen(operand), ordering))
    }

    @_transparent
    public static func _fetchSubtract(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchSubtract(address, _widen(operand), ordering))
    }

    @_transparent
    public static func _fetchAnd(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchAnd(address, _widen(operand), ordering))
    }

    @_transparent
    public static func _fetchOr(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchOr(address, _widen(operand), ordering))
    }

    @_transparent
    public static func _fetchXor(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchXor(address, _widen(operand), ordering))
    }

    @_transparent
    public static func _fetchUnsignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchUnsignedMin(address, _widen(operand), ordering))
    }

    @_transparent
    public static func _fetchUnsignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchUnsignedMax(address, _widen(operand), ordering))
    }

    @_transparent
    public static func _fetchSignedMin(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchSignedMin(address, _widen(operand), ordering))
    }

    @_transparent
    public static func _fetchSignedMax(
        _ address: UnsafeMutableRawPointer, _ operand: UInt, _ ordering: Int32
    ) -> UInt {
        _narrow(unsafe _Word._fetchSignedMax(address, _widen(operand), ordering))
    }
}
#else
import Synchronization

// `_AtomicStorage` has no counterpart to forward to — it is this package's own
// way of parameterizing `Atomic` over the storage width, which the standard
// library instead does by generating one copy of the operations per width. The
// concrete storage types do have counterparts, and custom `AtomicRepresentable`
// conformances name them, so those carry over.
public typealias _Atomic8BitStorage = Synchronization._Atomic8BitStorage
public typealias _Atomic16BitStorage = Synchronization._Atomic16BitStorage
public typealias _Atomic32BitStorage = Synchronization._Atomic32BitStorage
public typealias _Atomic64BitStorage = Synchronization._Atomic64BitStorage

#if _pointerBitWidth(_64)
public typealias _AtomicWordStorage = Synchronization._Atomic64BitStorage
#elseif _pointerBitWidth(_32)
public typealias _AtomicWordStorage = Synchronization._Atomic32BitStorage
#else
#error("Unsupported pointer bit width")
#endif
#endif
