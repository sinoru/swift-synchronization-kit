//
//  ExclusiveTransfer.swift
//  SynchronizationKit
//

/// Detaches a lock's protected storage from the lock's isolation region so it
/// can be handed to a `sending` closure parameter.
///
/// `Mutex` needs no such device: it is unconditionally `Sendable`, so region
/// isolation never ties its storage to the caller. A reader-writer lock is
/// `Sendable` only for `Sendable` values — readers borrow the value at the
/// same time, and a non-`Sendable` one could leak shared mutable state through
/// that borrow — and for any other value the region checker pins the storage
/// to the lock: correctly in general, but not on the write path, where the
/// lock already guarantees the exclusivity that `sending` asks for.
///
/// Declared `package` for the same reason `_Cell` is: the two reader-writer
/// locks, one for threads and one for tasks, share one copy.
@unsafe
@usableFromInline
package struct _ExclusiveTransfer<Value: ~Copyable>: @unchecked Sendable {
    @usableFromInline
    package let address: UnsafeMutablePointer<Value>

    @_transparent
    @usableFromInline
    package init(_ address: UnsafeMutablePointer<Value>) {
        unsafe self.address = address
    }
}
