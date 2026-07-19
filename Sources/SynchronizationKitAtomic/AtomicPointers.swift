//
//  AtomicPointers.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
// Pointers are word sized, and a valid pointer is never null, so its bit
// pattern round-trips through `_AtomicWordStorage` unchanged.
//
// That spare null pattern is also what pays for the `AtomicOptionalRepresentable`
// conformances at the bottom of this file: `nil` encodes as zero, so an optional
// pointer occupies the same single word as a non-optional one.

extension UnsafeRawPointer: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UnsafeRawPointer
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UnsafeRawPointer {
        // The bit pattern came from a non-optional pointer, so it is non-null.
        unsafe UnsafeRawPointer(bitPattern: storage._rawValue)!
    }
}

extension UnsafeMutableRawPointer: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UnsafeMutableRawPointer
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UnsafeMutableRawPointer {
        // The bit pattern came from a non-optional pointer, so it is non-null.
        unsafe UnsafeMutableRawPointer(bitPattern: storage._rawValue)!
    }
}

extension UnsafePointer: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UnsafePointer<Pointee>
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UnsafePointer<Pointee> {
        // The bit pattern came from a non-optional pointer, so it is non-null.
        unsafe UnsafePointer<Pointee>(bitPattern: storage._rawValue)!
    }
}

extension UnsafeMutablePointer: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming UnsafeMutablePointer<Pointee>
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UnsafeMutablePointer<Pointee> {
        // The bit pattern came from a non-optional pointer, so it is non-null.
        unsafe UnsafeMutablePointer<Pointee>(bitPattern: storage._rawValue)!
    }
}

extension OpaquePointer: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming OpaquePointer
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> OpaquePointer {
        // The bit pattern came from a non-optional pointer, so it is non-null.
        unsafe OpaquePointer(bitPattern: storage._rawValue)!
    }
}

extension ObjectIdentifier: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming ObjectIdentifier
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> ObjectIdentifier {
        // The bit pattern came from a non-optional object identifier, so it is
        // non-null.
        unsafe unsafeBitCast(storage._rawValue, to: ObjectIdentifier.self)
    }
}

extension Unmanaged: AtomicRepresentable {
    public typealias AtomicRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Unmanaged<Instance>
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(
            _rawValue: unsafe UInt(bitPattern: value.toOpaque())
        )
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> Unmanaged<Instance> {
        // The bit pattern came from `toOpaque()` on a non-optional value, so it
        // is a valid non-null object reference.
        unsafe Unmanaged<Instance>.fromOpaque(
            UnsafeRawPointer(bitPattern: storage._rawValue)!
        )
    }
}

// MARK: - Optional

// `nil` encodes as zero throughout. Decoding leans on the failable
// `init?(bitPattern:)` of each pointer type, which already maps zero to `nil` —
// so the round trip is the same one the non-optional conformances above make,
// minus the force unwrap that was standing in for "this cannot be null."

extension UnsafeRawPointer: AtomicOptionalRepresentable {
    public typealias AtomicOptionalRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicOptionalRepresentation(
        _ value: consuming UnsafeRawPointer?
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicOptionalRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UnsafeRawPointer? {
        unsafe UnsafeRawPointer(bitPattern: storage._rawValue)
    }
}

extension UnsafeMutableRawPointer: AtomicOptionalRepresentable {
    public typealias AtomicOptionalRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicOptionalRepresentation(
        _ value: consuming UnsafeMutableRawPointer?
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicOptionalRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UnsafeMutableRawPointer? {
        unsafe UnsafeMutableRawPointer(bitPattern: storage._rawValue)
    }
}

extension UnsafePointer: AtomicOptionalRepresentable {
    public typealias AtomicOptionalRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicOptionalRepresentation(
        _ value: consuming UnsafePointer<Pointee>?
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicOptionalRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UnsafePointer<Pointee>? {
        unsafe UnsafePointer<Pointee>(bitPattern: storage._rawValue)
    }
}

extension UnsafeMutablePointer: AtomicOptionalRepresentable {
    public typealias AtomicOptionalRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicOptionalRepresentation(
        _ value: consuming UnsafeMutablePointer<Pointee>?
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicOptionalRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> UnsafeMutablePointer<Pointee>? {
        unsafe UnsafeMutablePointer<Pointee>(bitPattern: storage._rawValue)
    }
}

extension OpaquePointer: AtomicOptionalRepresentable {
    public typealias AtomicOptionalRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicOptionalRepresentation(
        _ value: consuming OpaquePointer?
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(_rawValue: UInt(bitPattern: value))
    }

    @_transparent
    public static func decodeAtomicOptionalRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> OpaquePointer? {
        unsafe OpaquePointer(bitPattern: storage._rawValue)
    }
}

extension ObjectIdentifier: AtomicOptionalRepresentable {
    public typealias AtomicOptionalRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicOptionalRepresentation(
        _ value: consuming ObjectIdentifier?
    ) -> _AtomicWordStorage {
        // `UInt(bitPattern:)` has no optional overload for `ObjectIdentifier`,
        // so `nil` is spelled out as zero here rather than falling out of it.
        _AtomicWordStorage(
            _rawValue: value.map { UInt(bitPattern: $0) } ?? 0
        )
    }

    @_transparent
    public static func decodeAtomicOptionalRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> ObjectIdentifier? {
        guard storage._rawValue != 0 else { return nil }
        return unsafe unsafeBitCast(
            storage._rawValue, to: ObjectIdentifier.self
        )
    }
}

extension Unmanaged: AtomicOptionalRepresentable {
    public typealias AtomicOptionalRepresentation = _AtomicWordStorage

    @_transparent
    public static func encodeAtomicOptionalRepresentation(
        _ value: consuming Unmanaged<Instance>?
    ) -> _AtomicWordStorage {
        _AtomicWordStorage(
            _rawValue: unsafe UInt(bitPattern: value?.toOpaque())
        )
    }

    @_transparent
    public static func decodeAtomicOptionalRepresentation(
        _ storage: consuming _AtomicWordStorage
    ) -> Unmanaged<Instance>? {
        guard
            let pointer = unsafe UnsafeRawPointer(bitPattern: storage._rawValue)
        else {
            return nil
        }
        return unsafe Unmanaged<Instance>.fromOpaque(pointer)
    }
}
#endif
