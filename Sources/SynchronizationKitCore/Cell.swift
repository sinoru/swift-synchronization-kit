//
//  Cell.swift
//  SynchronizationKit
//

/// Storage for exactly one value of `Value`, laid out inline rather than boxed.
///
/// This mirrors the standard library's `_Cell`. The one difference is how the
/// storage address is recovered: the standard library uses
/// `Builtin.addressOfRawLayout`, which requires building with the `Builtin`
/// module, while this reaches the same address through `withUnsafePointer(to:)`.
///
/// Declared `package` so the sibling targets (`Mutex`, `RWLock`) can share one
/// copy without exposing it to clients; `@usableFromInline` is what lets their
/// inlined entry points carry references to it into client code, the same way
/// `internal` worked when each target had its own copy.
///
/// - Important: `_address` deliberately lets the pointer outlive the
///   `withUnsafePointer(to:)` closure, which is not sound for values in
///   general. It is sound here, and only here, because a `@_rawLayout` type's
///   storage *is* the value's own storage — there is no separate buffer that
///   could be materialized as a temporary — and because `@_staticExclusiveOnly`
///   forbids declaring such a value as a `var`, so its storage cannot be
///   reassigned or moved out from under a borrow. Copying this pattern to a
///   type without both of those properties would produce a dangling pointer.
@_rawLayout(like: Value, movesAsLike)
@_staticExclusiveOnly
@usableFromInline
package struct _Cell<Value: ~Copyable>: ~Copyable {
    @_transparent
    @usableFromInline
    package var _address: UnsafeMutablePointer<Value> {
        unsafe withUnsafePointer(to: self) { pointer in
            unsafe UnsafeMutableRawPointer(mutating: pointer)
                .assumingMemoryBound(to: Value.self)
        }
    }

    @_transparent
    @usableFromInline
    package init(_ initialValue: consuming Value) {
        unsafe _address.initialize(to: initialValue)
    }

    @inlinable
    deinit {
        unsafe _address.deinitialize(count: 1)
    }
}
