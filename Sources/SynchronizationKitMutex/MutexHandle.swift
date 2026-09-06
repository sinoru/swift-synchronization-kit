//
//  MutexHandle.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
// `os_unfair_lock` is a stored property of a `@usableFromInline` type and the
// calls around it inline into their callers, so both modules are on this one's
// interface.
public import Darwin
public import SynchronizationKitCore

/// The platform lock backing `Mutex`.
///
/// This matches the standard library's Darwin implementation exactly, down to
/// the primitive: `os_unfair_lock`, which has been available since macOS 10.12
/// and iOS 10, far below this package's deployment targets. Nothing about the
/// lock itself needed backporting — only the inline storage around it.
///
/// The type and its locking operations are `package` rather than `internal`
/// for the inlining, not for a client in the package: `Mutex`'s entry points
/// are `@inline(always)`, which needs everything they call to be usable from
/// inline and refuses to sit beside `@usableFromInline`, and `package` grants
/// that on its own. Nothing else in the package reaches this handle —
/// `RWLock`, which once took it directly for its writer-side exclusion, takes
/// a `Mutex<Void>` now, which is this handle and nothing more.
@_staticExclusiveOnly
@usableFromInline
package struct _MutexHandle: ~Copyable {
    @usableFromInline
    internal let value: _Cell<os_unfair_lock>

    @_transparent
    @usableFromInline
    package init() {
        value = _Cell(os_unfair_lock())
    }

    @inline(always)
    package borrowing func _lock() {
        unsafe os_unfair_lock_lock(value._address)
    }

    @inline(always)
    package borrowing func _tryLock() -> Bool {
        unsafe os_unfair_lock_trylock(value._address)
    }

    @inline(always)
    package borrowing func _unlock() {
        unsafe os_unfair_lock_unlock(value._address)
    }
}
#endif
