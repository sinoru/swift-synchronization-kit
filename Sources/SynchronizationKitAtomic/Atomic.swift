//
//  Atomic.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
/// A value that can be read and updated by several threads at once without
/// tearing or losing writes.
///
/// Every operation names the memory ordering it applies. Ordering controls what
/// a *neighbouring* access is allowed to observe, not the atomicity of this
/// access; use `.relaxed` when the value stands alone (a counter, a flag nobody
/// keys other reads off), and a stronger ordering when the value guards access
/// to something else.
///
/// The value is stored inline. An `Atomic<Int64>` occupies eight bytes and
/// performs no allocation, so it can be held directly by a class or a global
/// without an extra indirection.
///
/// - Important: `_address` hands out a pointer that outlives the
///   `withUnsafePointer(to:)` call that produced it, which is not sound for an
///   ordinary value. Two properties of this type make it sound here. Under
///   `@_rawLayout` the struct's own storage *is* the value's storage, so there
///   is no temporary buffer the closure could have been handed instead; and
///   `@_staticExclusiveOnly` rejects `var` declarations, so the storage cannot
///   be reassigned or moved while a borrow is outstanding. Reusing this pattern
///   on a type lacking either property yields a dangling pointer.
@available(macOS, deprecated: 15.0, message: "Use Synchronization.Atomic instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(iOS, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(tvOS, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(watchOS, deprecated: 11.0, message: "Use Synchronization.Atomic instead")
@available(visionOS, deprecated: 2.0, message: "Use Synchronization.Atomic instead")
@_rawLayout(like: Value.AtomicRepresentation)
@_staticExclusiveOnly
public struct Atomic<Value: AtomicRepresentable>: ~Copyable {
    @_transparent
    @usableFromInline
    internal var _address: UnsafeMutablePointer<Value.AtomicRepresentation> {
        unsafe withUnsafePointer(to: self) { pointer in
            unsafe UnsafeMutableRawPointer(mutating: pointer)
                .assumingMemoryBound(to: Value.AtomicRepresentation.self)
        }
    }

    /// The storage's address, for the operations below and for the sibling
    /// targets that hand it to a system call.
    ///
    /// `package` rather than `internal` because `RWLock`'s address-based
    /// waiting needs the very address the atomic occupies: the kernel compares
    /// the word there against an expected value, so any copy would defeat it.
    /// Clients never see this.
    @_transparent
    @usableFromInline
    package var _rawAddress: UnsafeMutableRawPointer {
        unsafe withUnsafePointer(to: self) { pointer in
            unsafe UnsafeMutableRawPointer(mutating: pointer)
        }
    }

    /// Creates an atomic holding `initialValue`.
    ///
    /// Construction is not itself an atomic operation; nothing else may observe
    /// the storage until initialization completes.
    @_transparent
    public init(_ initialValue: consuming Value) {
        unsafe _address.initialize(to: Value.encodeAtomicRepresentation(initialValue))
    }

    @inlinable
    deinit {
        let oldValue = Value.decodeAtomicRepresentation(unsafe _address.pointee)
        _ = consume oldValue

        unsafe _address.deinitialize(count: 1)
    }
}

// Every extension of `Atomic` repeats the type's deprecation: a use inside a
// deprecated context is not diagnosed, so this is what keeps the package from
// warning about itself when the deployment target reaches the versions above.
@available(macOS, deprecated: 15.0, message: "Use Synchronization.Atomic instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(iOS, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(tvOS, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(watchOS, deprecated: 11.0, message: "Use Synchronization.Atomic instead")
@available(visionOS, deprecated: 2.0, message: "Use Synchronization.Atomic instead")
extension Atomic: @unchecked Sendable where Value: Sendable {}

// MARK: - Primitive operations

@available(macOS, deprecated: 15.0, message: "Use Synchronization.Atomic instead")
@available(macCatalyst, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(iOS, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(tvOS, deprecated: 18.0, message: "Use Synchronization.Atomic instead")
@available(watchOS, deprecated: 11.0, message: "Use Synchronization.Atomic instead")
@available(visionOS, deprecated: 2.0, message: "Use Synchronization.Atomic instead")
extension Atomic where Value.AtomicRepresentation: _AtomicStorage {
    /// Raises `successOrdering` until it is at least as strong as
    /// `failureOrdering`.
    ///
    /// LLVM rejects a compare-exchange whose failure ordering outranks its
    /// success ordering, but the pairing is natural to write — `.releasing` on
    /// success with `.acquiring` on failure, say — so the pair is normalized
    /// here instead of being rejected. Both arguments are literals at any
    /// ordinary call site, so this folds away before it reaches codegen.
    @_transparent
    @usableFromInline
    internal static func _strengthening(
        _ successOrdering: Int32,
        toAtLeast failureOrdering: Int32
    ) -> Int32 {
        if failureOrdering == _MemoryOrder.sequentiallyConsistent {
            return _MemoryOrder.sequentiallyConsistent
        }

        if failureOrdering == _MemoryOrder.acquiring {
            if successOrdering == _MemoryOrder.relaxed {
                return _MemoryOrder.acquiring
            }

            if successOrdering == _MemoryOrder.releasing {
                return _MemoryOrder.acquiringAndReleasing
            }
        }

        return successOrdering
    }

    @_transparent
    @usableFromInline
    internal static func _decode(
        _ rawValue: Value.AtomicRepresentation._RawValue
    ) -> Value {
        Value.decodeAtomicRepresentation(
            Value.AtomicRepresentation(_rawValue: rawValue)
        )
    }

    @_transparent
    @usableFromInline
    internal static func _encode(
        _ value: consuming Value
    ) -> Value.AtomicRepresentation._RawValue {
        Value.encodeAtomicRepresentation(value)._rawValue
    }

    /// Reads the current value.
    ///
    /// - Parameter ordering: What this read makes visible to the accesses
    ///   around it.
    /// - Returns: The value at the moment of the read.
    @_transparent
    public borrowing func load(ordering: AtomicLoadOrdering) -> Value {
        unsafe Self._decode(
            Value.AtomicRepresentation._load(_rawAddress, ordering._rawValue)
        )
    }

    /// Replaces the current value, discarding it.
    ///
    /// - Parameter desired: The value to write.
    /// - Parameter ordering: What this write publishes to the accesses around
    ///   it.
    @_transparent
    public borrowing func store(
        _ desired: consuming Value,
        ordering: AtomicStoreOrdering
    ) {
        unsafe Value.AtomicRepresentation._store(
            _rawAddress, Self._encode(desired), ordering._rawValue
        )
    }

    /// Replaces the current value and hands back the one it displaced.
    ///
    /// - Parameter desired: The value to write.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: The value that was there before this call.
    @discardableResult
    @_transparent
    public borrowing func exchange(
        _ desired: consuming Value,
        ordering: AtomicUpdateOrdering
    ) -> Value {
        unsafe Self._decode(
            Value.AtomicRepresentation._exchange(
                _rawAddress, Self._encode(desired), ordering._rawValue
            )
        )
    }

    /// Writes `desired`, but only if the current value is still `expected`.
    ///
    /// The comparison and the write happen as one indivisible step, so no other
    /// thread can slip a write in between them. Read as ordinary code, with the
    /// whole body understood to be uninterruptible:
    ///
    ///     let seen = currentValue
    ///     if seen != expected { return (false, seen) }
    ///     currentValue = desired
    ///     return (true, seen)
    ///
    /// - Parameter expected: The value this call assumes is present.
    /// - Parameter desired: The value to write if that assumption holds.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: Whether the write happened, and the value that was actually
    ///   there. A failed call reports the value that defeated it, which is what
    ///   a retry loop should feed back in as its next `expected`.
    @_transparent
    public borrowing func compareExchange(
        expected: consuming Value,
        desired: consuming Value,
        ordering: AtomicUpdateOrdering
    ) -> (exchanged: Bool, original: Value) {
        compareExchange(
            expected: expected,
            desired: desired,
            successOrdering: ordering,
            failureOrdering: AtomicLoadOrdering(
                _rawValue: ordering._failureRawValue
            )
        )
    }

    /// Writes `desired` only if the current value is still `expected`, applying
    /// a different ordering depending on which way it goes.
    ///
    /// A failed call writes nothing, so it can be no stronger than a load —
    /// which is why `failureOrdering` is an `AtomicLoadOrdering`. Weakening the
    /// failure path is worth doing in a retry loop, where failure is expected
    /// and the release side only matters once, on the attempt that wins.
    ///
    /// - Parameter expected: The value this call assumes is present.
    /// - Parameter desired: The value to write if that assumption holds.
    /// - Parameter successOrdering: The ordering applied when the write happens.
    /// - Parameter failureOrdering: The ordering applied when it does not.
    /// - Returns: Whether the write happened, and the value that was actually
    ///   there.
    @_transparent
    public borrowing func compareExchange(
        expected: consuming Value,
        desired: consuming Value,
        successOrdering: AtomicUpdateOrdering,
        failureOrdering: AtomicLoadOrdering
    ) -> (exchanged: Bool, original: Value) {
        _compareExchange(
            expected: expected,
            desired: desired,
            weak: false,
            successOrdering: successOrdering,
            failureOrdering: failureOrdering
        )
    }

    /// Like `compareExchange`, but allowed to fail even when the value does
    /// match.
    ///
    /// On processors that implement compare-and-swap with a load-linked /
    /// store-conditional pair, an unrelated interrupt can break the reservation
    /// and defeat the write. `compareExchange` hides that behind a retry loop
    /// of its own; this variant lets it surface, so a caller that already has a
    /// retry loop does not pay for a second one nested inside it.
    ///
    /// Only meaningful inside such a loop — a single call proves nothing when
    /// it returns `false`.
    ///
    /// - Parameter expected: The value this call assumes is present.
    /// - Parameter desired: The value to write if that assumption holds.
    /// - Parameter ordering: The ordering to apply.
    /// - Returns: Whether the write happened, and the value that was actually
    ///   there.
    @_transparent
    public borrowing func weakCompareExchange(
        expected: consuming Value,
        desired: consuming Value,
        ordering: AtomicUpdateOrdering
    ) -> (exchanged: Bool, original: Value) {
        weakCompareExchange(
            expected: expected,
            desired: desired,
            successOrdering: ordering,
            failureOrdering: AtomicLoadOrdering(
                _rawValue: ordering._failureRawValue
            )
        )
    }

    /// A `weakCompareExchange` that applies a different ordering depending on
    /// whether the write happens.
    ///
    /// - Parameter expected: The value this call assumes is present.
    /// - Parameter desired: The value to write if that assumption holds.
    /// - Parameter successOrdering: The ordering applied when the write happens.
    /// - Parameter failureOrdering: The ordering applied when it does not.
    /// - Returns: Whether the write happened, and the value that was actually
    ///   there.
    @_transparent
    public borrowing func weakCompareExchange(
        expected: consuming Value,
        desired: consuming Value,
        successOrdering: AtomicUpdateOrdering,
        failureOrdering: AtomicLoadOrdering
    ) -> (exchanged: Bool, original: Value) {
        _compareExchange(
            expected: expected,
            desired: desired,
            weak: true,
            successOrdering: successOrdering,
            failureOrdering: failureOrdering
        )
    }

    @_transparent
    @usableFromInline
    internal borrowing func _compareExchange(
        expected: consuming Value,
        desired: consuming Value,
        weak: Bool,
        successOrdering: AtomicUpdateOrdering,
        failureOrdering: AtomicLoadOrdering
    ) -> (exchanged: Bool, original: Value) {
        let (exchanged, original) = unsafe Value.AtomicRepresentation._compareExchange(
            _rawAddress,
            Self._encode(expected),
            Self._encode(desired),
            weak,
            Self._strengthening(
                successOrdering._rawValue,
                toAtLeast: failureOrdering._rawValue
            ),
            failureOrdering._rawValue
        )

        return (exchanged, Self._decode(original))
    }
}
#else
// Re-exported rather than aliased, which is what this branch used to do. A
// type alias carries the name across but not the members, so under
// `MemberImportVisibility` a client calling `load(ordering:)` would have to
// import `Synchronization` itself — on these platforms and not on Apple's,
// which is exactly the seam this package exists to hide. `@_exported` brings
// the members along with the name, and the two platforms read the same again.
//
// Scoped to the one declaration this file forwards. A whole-module re-export
// would hand a client every other `Synchronization` type as well — `Mutex`
// among them — so a package trait that excludes the Mutex target would stop
// excluding anything here, and code written against this module would compile
// on these platforms and not on Apple's. That is the same seam, reopened from
// the other side.
//
// The scope holds for a source build and for a binary module, which is what
// SwiftPM produces. It does not survive a textual module interface: asked for
// one, the compiler warns that scoped imports are unsupported there and writes
// the access path out as a comment — `@_exported public import
// Synchronization/*.Atomic*/` — which a consumer of that interface reads as the
// whole module. Nothing here emits one, since that takes library evolution and
// SwiftPM offers no setting for it, but the day this package is built for
// distribution is the day this scoping quietly stops holding.
//
// The two halves are also governed by different rules, which is what makes the
// pairing work: member visibility is granted per module and ignores the access
// path, while name lookup honours it. Only the second half is what scoping is
// for here. The first is the subject of swiftlang/swift#79616, which calls the
// asymmetry a bug — though the narrowing it asks for is the one this package
// wants, since it would leave the named type's members reachable and take away
// the incidental reach into everything else.
@_exported public import struct Synchronization.Atomic
#endif
