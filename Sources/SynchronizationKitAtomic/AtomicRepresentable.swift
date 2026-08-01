//
//  AtomicRepresentable.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
/// A type that can be stored in an `Atomic` by mapping it onto a fixed-width
/// storage type.
///
/// Hardware performs atomic operations on machine words, not on arbitrary Swift
/// types, so a conforming type declares which width it occupies and how to
/// convert in each direction. That conversion is the only thing this protocol
/// asks for; the atomic operations themselves come with it.
///
/// The width has to be one the hardware can address atomically, so
/// `AtomicRepresentation` must be one of `_Atomic8BitStorage`,
/// `_Atomic16BitStorage`, `_Atomic32BitStorage`, `_Atomic64BitStorage`, or
/// `_AtomicWordStorage`. A type that does not fit in a machine word cannot be
/// made atomic this way — guard it with a `Mutex` instead.
///
/// A `RawRepresentable` type whose `RawValue` already conforms needs no
/// implementation at all:
///
///     enum TrafficLight: UInt8, AtomicRepresentable {
///         case red, yellow, green
///     }
///
/// Otherwise, pick a width by borrowing the storage of the unsigned integer
/// that has it, and pack into that integer. Delegating to the integer's own
/// conformance this way, rather than constructing the storage directly, is
/// what keeps the conformance portable: on platforms where this package
/// forwards to the standard library's `Synchronization`, the storage types are
/// the standard library's, whose members are `Builtin`-typed and so cannot be
/// named from outside it. Two `Int32` fields fit in 64 bits:
///
///     struct Cursor {
///         var line: Int32
///         var column: Int32
///     }
///
///     extension Cursor: AtomicRepresentable {
///         typealias AtomicRepresentation = UInt64.AtomicRepresentation
///
///         static func encodeAtomicRepresentation(
///             _ cursor: consuming Cursor
///         ) -> AtomicRepresentation {
///             let packed = UInt64(UInt32(bitPattern: cursor.line)) << 32
///                 | UInt64(UInt32(bitPattern: cursor.column))
///             return UInt64.encodeAtomicRepresentation(packed)
///         }
///
///         static func decodeAtomicRepresentation(
///             _ storage: consuming AtomicRepresentation
///         ) -> Cursor {
///             let packed = UInt64.decodeAtomicRepresentation(storage)
///             return Cursor(
///                 line: Int32(bitPattern: UInt32(truncatingIfNeeded: packed >> 32)),
///                 column: Int32(bitPattern: UInt32(truncatingIfNeeded: packed))
///             )
///         }
///     }
///
/// Packing both fields into one word is the point: it is what makes them move
/// as a unit. Two separate atomics would let a reader catch a freshly updated
/// line beside a stale column.
public protocol AtomicRepresentable {
    /// The fixed-width storage this type is encoded into.
    associatedtype AtomicRepresentation: BitwiseCopyable

    /// Packs a value into its storage form.
    ///
    /// Not itself atomic — this only converts, and runs outside whatever atomic
    /// operation consumes the result. It consumes `value`, since ownership
    /// moves into the storage.
    static func encodeAtomicRepresentation(
        _ value: consuming Self
    ) -> AtomicRepresentation

    /// Unpacks a value from its storage form.
    ///
    /// Not itself atomic; the read that produced `storage` was. Must invert
    /// `encodeAtomicRepresentation` exactly — the two run at different times on
    /// different threads, so anything lossy shows up as corruption rather than
    /// as a compile error.
    static func decodeAtomicRepresentation(
        _ storage: consuming AtomicRepresentation
    ) -> Self
}

// MARK: - RawRepresentable

extension RawRepresentable
where
    Self: AtomicRepresentable,
    RawValue: AtomicRepresentable
{
    /// Borrowed from the raw value, which already has a storage form.
    public typealias AtomicRepresentation = RawValue.AtomicRepresentation

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Self
    ) -> RawValue.AtomicRepresentation {
        RawValue.encodeAtomicRepresentation(value.rawValue)
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ representation: consuming RawValue.AtomicRepresentation
    ) -> Self {
        // Only `encodeAtomicRepresentation` can have put this bit pattern in
        // storage, and it only ever encodes the raw value of a real case, so
        // the reverse lookup cannot fail.
        Self(rawValue: RawValue.decodeAtomicRepresentation(representation))!
    }
}

// MARK: - Optional

/// A type that can also be stored in an `Atomic` after being wrapped in an
/// `Optional`.
///
/// Conforming means reserving one bit pattern to stand for `nil`. Every
/// conformance here is a pointer of some kind, and no valid pointer is null, so
/// the null pattern is already spare and costs nothing to give up. The width
/// does not change: `Atomic<UnsafeMutablePointer<T>?>` is the same single word
/// as `Atomic<UnsafeMutablePointer<T>>`.
///
/// This is what makes the ordinary lock-free shapes expressible — a slot that
/// starts out empty, or a list whose last node points nowhere:
///
///     let head = Atomic<UnsafeMutablePointer<Node>?>(nil)
public protocol AtomicOptionalRepresentable: AtomicRepresentable {
    /// The fixed-width storage `Self?` is encoded into.
    ///
    /// Separate from `AtomicRepresentation` because the two encodings differ:
    /// this one has to reserve a pattern for `nil`.
    associatedtype AtomicOptionalRepresentation: BitwiseCopyable

    /// Packs an optional value into its storage form.
    ///
    /// Not itself atomic, for the same reason `encodeAtomicRepresentation` is
    /// not — it only converts.
    static func encodeAtomicOptionalRepresentation(
        _ value: consuming Self?
    ) -> AtomicOptionalRepresentation

    /// Unpacks an optional value from its storage form.
    ///
    /// Must invert `encodeAtomicOptionalRepresentation` exactly, `nil`
    /// included — a round trip that loses the distinction between `nil` and a
    /// real value corrupts silently.
    static func decodeAtomicOptionalRepresentation(
        _ representation: consuming AtomicOptionalRepresentation
    ) -> Self?
}

extension Optional: AtomicRepresentable
where Wrapped: AtomicOptionalRepresentable {
    /// Taken from the wrapped type, which is the one that knows which bit
    /// pattern it can spare for `nil`.
    public typealias AtomicRepresentation = Wrapped.AtomicOptionalRepresentation

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Optional<Wrapped>
    ) -> Wrapped.AtomicOptionalRepresentation {
        Wrapped.encodeAtomicOptionalRepresentation(value)
    }

    @_transparent
    public static func decodeAtomicRepresentation(
        _ representation: consuming Wrapped.AtomicOptionalRepresentation
    ) -> Optional<Wrapped> {
        Wrapped.decodeAtomicOptionalRepresentation(representation)
    }
}

// MARK: - Never

extension Never: AtomicRepresentable {
    /// `Never` has no values to store, so it stands in as its own storage.
    public typealias AtomicRepresentation = Never

    @_transparent
    public static func encodeAtomicRepresentation(
        _ value: consuming Never
    ) -> Never {}

    @_transparent
    public static func decodeAtomicRepresentation(
        _ representation: consuming Never
    ) -> Never {}
}
#else
// Re-exported, and scoped to these two, for the reasons given in
// `Atomic.swift`'s branch of the same shape.
@_exported public import protocol Synchronization.AtomicRepresentable
@_exported public import protocol Synchronization.AtomicOptionalRepresentable
#endif
