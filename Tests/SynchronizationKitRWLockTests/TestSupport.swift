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

/// Turns `handle`'s table off by hand, marked as a writer would leave it while
/// holding the lock, so that every reader from here on is counted rather than
/// published: for the checks that need a reader on the counted path, which is
/// where the gates are. A writer arriving afterwards finds the table off and
/// proceeds as one does; nothing has to be undone.
func keepReadersCounted(on handle: borrowing _RWLockHandle) {
    handle.bias.word.store(Int64.min | _ReaderBias._held, ordering: .relaxed)
}
#endif
