//
//  AtomicMemoryOrderings.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
// The raw value of every ordering below is deliberately the matching
// `__ATOMIC_*` constant from Clang's atomic builtins:
//
//     __ATOMIC_RELAXED  0      __ATOMIC_RELEASE  3
//     __ATOMIC_CONSUME  1      __ATOMIC_ACQ_REL  4
//     __ATOMIC_ACQUIRE  2      __ATOMIC_SEQ_CST  5
//
// That lets every atomic operation forward its ordering straight to the shim
// with no dispatch of any kind. The standard library has to switch over the
// ordering instead, because `Builtin.atomicrmw_*` bakes the ordering into the
// operation name and so only accepts a compile-time constant. Clang's builtins
// take the ordering as an ordinary argument and constant-fold it when it is
// known, which it is at any ordinary call site.

/// - Note: Like the storage types, this is an implementation detail that is
///   `public` only for the sibling lock targets, which drive the storage
///   primitives directly where the deprecated `Atomic` wrapper cannot be used.
public enum _MemoryOrder {
    @_transparent public static var relaxed: Int32 { 0 }
    @_transparent public static var acquiring: Int32 { 2 }
    @_transparent public static var releasing: Int32 { 3 }
    @_transparent public static var acquiringAndReleasing: Int32 { 4 }
    @_transparent public static var sequentiallyConsistent: Int32 { 5 }
}

// MARK: - Load orderings

/// How an atomic read orders itself against the memory accesses around it.
@frozen
public struct AtomicLoadOrdering {
    @usableFromInline
    internal var _rawValue: Int32

    @_transparent
    @usableFromInline
    internal init(_rawValue: Int32) {
        self._rawValue = _rawValue
    }
}

extension AtomicLoadOrdering {
    /// Orders nothing beyond this operation itself.
    ///
    /// The operation stays indivisible, but neighbouring reads and writes may be
    /// reordered freely around it. Correct when the value answers for itself — a
    /// statistics counter, an identifier generator — and wrong whenever another
    /// thread is meant to conclude something about *other* memory from what it
    /// reads here.
    @_transparent
    public static var relaxed: Self {
        Self(_rawValue: _MemoryOrder.relaxed)
    }

    /// Pairs with a releasing write to make that writer's earlier work visible.
    ///
    /// Once this read observes a value published by a releasing store, every
    /// write the storing thread performed beforehand is visible to this thread
    /// as well, and nothing written after this read can be hoisted above it.
    /// This is the read half of publishing data through a flag or a pointer.
    @_transparent
    public static var acquiring: Self {
        Self(_rawValue: _MemoryOrder.acquiring)
    }

    /// An acquiring read that also joins one global order shared by every
    /// sequentially consistent operation.
    ///
    /// The strongest and slowest option. Needed when threads must agree on the
    /// relative order of operations on *separate* atomics; acquiring alone only
    /// relates each reader to the writer it read from.
    @_transparent
    public static var sequentiallyConsistent: Self {
        Self(_rawValue: _MemoryOrder.sequentiallyConsistent)
    }
}

extension AtomicLoadOrdering: Equatable {
    @_transparent
    public static func ==(left: Self, right: Self) -> Bool {
        left._rawValue == right._rawValue
    }
}

extension AtomicLoadOrdering: Hashable {
    @_transparent
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_rawValue)
    }
}

extension AtomicLoadOrdering: CustomStringConvertible {
    public var description: String {
        switch self {
        case .relaxed: "relaxed"
        case .acquiring: "acquiring"
        case .sequentiallyConsistent: "sequentiallyConsistent"
        default: "invalid"
        }
    }
}

extension AtomicLoadOrdering: Sendable {}

// MARK: - Store orderings

/// How an atomic write orders itself against the memory accesses around it.
@frozen
public struct AtomicStoreOrdering {
    @usableFromInline
    internal var _rawValue: Int32

    @_transparent
    @usableFromInline
    internal init(_rawValue: Int32) {
        self._rawValue = _rawValue
    }
}

extension AtomicStoreOrdering {
    /// Orders nothing beyond this operation itself.
    ///
    /// The operation stays indivisible, but neighbouring reads and writes may be
    /// reordered freely around it. Correct when the value answers for itself — a
    /// statistics counter, an identifier generator — and wrong whenever another
    /// thread is meant to conclude something about *other* memory from what it
    /// reads here.
    @_transparent
    public static var relaxed: Self {
        Self(_rawValue: _MemoryOrder.relaxed)
    }

    /// Publishes everything this thread wrote beforehand to whoever acquires
    /// this value.
    ///
    /// Writes issued before this store cannot be sunk below it, so a reader that
    /// acquires this value is guaranteed to see them. Write the data first, then
    /// release the flag or pointer that points at it.
    @_transparent
    public static var releasing: Self {
        Self(_rawValue: _MemoryOrder.releasing)
    }

    /// A releasing write that also joins one global order shared by every
    /// sequentially consistent operation.
    @_transparent
    public static var sequentiallyConsistent: Self {
        Self(_rawValue: _MemoryOrder.sequentiallyConsistent)
    }
}

extension AtomicStoreOrdering: Equatable {
    @_transparent
    public static func ==(left: Self, right: Self) -> Bool {
        left._rawValue == right._rawValue
    }
}

extension AtomicStoreOrdering: Hashable {
    @_transparent
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_rawValue)
    }
}

extension AtomicStoreOrdering: CustomStringConvertible {
    public var description: String {
        switch self {
        case .relaxed: "relaxed"
        case .releasing: "releasing"
        case .sequentiallyConsistent: "sequentiallyConsistent"
        default: "invalid"
        }
    }
}

extension AtomicStoreOrdering: Sendable {}

// MARK: - Update orderings

/// How an atomic read-modify-write orders itself against the memory accesses
/// around it.
///
/// A read-modify-write has both a read half and a write half, so it can carry
/// acquire semantics, release semantics, or both.
@frozen
public struct AtomicUpdateOrdering {
    @usableFromInline
    internal var _rawValue: Int32

    /// What a failed `compareExchange` falls back to.
    ///
    /// A compare-exchange that does not write is just a read, and a read cannot
    /// release anything. So the release half is dropped and whatever acquire
    /// half remains is kept.
    @usableFromInline
    internal var _failureRawValue: Int32

    @_transparent
    @usableFromInline
    internal init(_rawValue: Int32, _failureRawValue: Int32) {
        self._rawValue = _rawValue
        self._failureRawValue = _failureRawValue
    }
}

extension AtomicUpdateOrdering {
    /// Orders nothing beyond this operation itself.
    ///
    /// The operation stays indivisible, but neighbouring reads and writes may be
    /// reordered freely around it. Correct when the value answers for itself — a
    /// statistics counter, an identifier generator — and wrong whenever another
    /// thread is meant to conclude something about *other* memory from what it
    /// reads here.
    @_transparent
    public static var relaxed: Self {
        Self(
            _rawValue: _MemoryOrder.relaxed,
            _failureRawValue: _MemoryOrder.relaxed
        )
    }

    /// Acquires on the read half; imposes nothing on the write half.
    ///
    /// Appropriate when this operation consumes something another thread
    /// published but publishes nothing itself — taking ownership of a queued
    /// item, for instance.
    @_transparent
    public static var acquiring: Self {
        Self(
            _rawValue: _MemoryOrder.acquiring,
            _failureRawValue: _MemoryOrder.acquiring
        )
    }

    /// Releases on the write half; imposes nothing on the read half.
    ///
    /// Appropriate when this operation hands work off but does not need to see
    /// anything the previous holder did.
    @_transparent
    public static var releasing: Self {
        Self(
            _rawValue: _MemoryOrder.releasing,
            _failureRawValue: _MemoryOrder.relaxed
        )
    }

    /// Acquires on the read half and releases on the write half.
    ///
    /// The usual choice for a read-modify-write that both consumes what came
    /// before and publishes what follows.
    @_transparent
    public static var acquiringAndReleasing: Self {
        Self(
            _rawValue: _MemoryOrder.acquiringAndReleasing,
            _failureRawValue: _MemoryOrder.acquiring
        )
    }

    /// An acquiring-and-releasing update that also joins one global order
    /// shared by every sequentially consistent operation.
    @_transparent
    public static var sequentiallyConsistent: Self {
        Self(
            _rawValue: _MemoryOrder.sequentiallyConsistent,
            _failureRawValue: _MemoryOrder.sequentiallyConsistent
        )
    }
}

extension AtomicUpdateOrdering: Equatable {
    @_transparent
    public static func ==(left: Self, right: Self) -> Bool {
        left._rawValue == right._rawValue
    }
}

extension AtomicUpdateOrdering: Hashable {
    @_transparent
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_rawValue)
    }
}

extension AtomicUpdateOrdering: CustomStringConvertible {
    public var description: String {
        switch self {
        case .relaxed: "relaxed"
        case .acquiring: "acquiring"
        case .releasing: "releasing"
        case .acquiringAndReleasing: "acquiringAndReleasing"
        case .sequentiallyConsistent: "sequentiallyConsistent"
        default: "invalid"
        }
    }
}

extension AtomicUpdateOrdering: Sendable {}
#else
import Synchronization

public typealias AtomicLoadOrdering = Synchronization.AtomicLoadOrdering
public typealias AtomicStoreOrdering = Synchronization.AtomicStoreOrdering
public typealias AtomicUpdateOrdering = Synchronization.AtomicUpdateOrdering
#endif
