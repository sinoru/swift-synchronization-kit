//
//  MutexHandle.swift
//  SynchronizationKit
//

#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
import Darwin

/// The platform lock backing `Mutex`.
///
/// This matches the standard library's Darwin implementation exactly, down to
/// the primitive: `os_unfair_lock`, which has been available since macOS 10.12
/// and iOS 10, far below this package's deployment targets. Nothing about the
/// lock itself needed backporting — only the inline storage around it.
@_staticExclusiveOnly
public struct _MutexHandle: ~Copyable {
    @usableFromInline
    internal let value: _Cell<os_unfair_lock>

    @_transparent
    public init() {
        value = _Cell(os_unfair_lock())
    }

    @_transparent
    @usableFromInline
    internal borrowing func _lock() {
        unsafe os_unfair_lock_lock(value._address)
    }

    @_transparent
    @usableFromInline
    internal borrowing func _tryLock() -> Bool {
        unsafe os_unfair_lock_trylock(value._address)
    }

    @_transparent
    @usableFromInline
    internal borrowing func _unlock() {
        unsafe os_unfair_lock_unlock(value._address)
    }
}
#endif
