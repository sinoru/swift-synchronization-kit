//
//  TestSupport.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import SynchronizationKitAtomic

@testable import SynchronizationKitRWLock

/// How many readers have registered behind the writer holding `handle`.
///
/// Registered, not parked: a reader counts itself before it reaches the wait, so
/// this going up says a reader is on its way in, not that it is already asleep.
func registeredReaders(of handle: borrowing _RWLockHandle) -> Int32 {
    handle.readerCount.load(ordering: .relaxed) &+ _RWLockHandle._maxReaders
}
#endif
