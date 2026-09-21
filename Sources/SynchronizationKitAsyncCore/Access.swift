//
//  Access.swift
//  SynchronizationKit
//

// Here rather than beside the reader-writer primitive that reads it: this is
// the one `Request` a wait queue carries that is not `Void`, so the generic
// parameter and the reason it exists live in the same module.

/// What a waiter asks for, where a primitive hands out shared access
/// alongside exclusive access.
///
/// The `Request` such a primitive queues. One that hands out a single kind
/// of access has nothing to ask and uses `Void`.
package enum _Access: Sendable {
    /// Shared access, alongside any number of other readers.
    case read
    /// Exclusive access.
    case write
}
