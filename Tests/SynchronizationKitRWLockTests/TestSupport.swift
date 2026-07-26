//
//  TestSupport.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import Testing

@testable import SynchronizationKitRWLock

/// Waits for `semaphore`, failing rather than hanging if it never arrives.
///
/// `.timeLimit` would say this once for a whole suite, but it needs iOS 16 and
/// watchOS 9 and this package deploys below both. An unbounded `wait()` turns a
/// dropped wake into a six-hour CI timeout, which this repository has already
/// paid for once, so every join here is bounded by hand.
func expectSignal(
    _ semaphore: DispatchSemaphore,
    within seconds: Double = 60,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        semaphore.wait(timeout: .now() + seconds) == .success,
        comment ?? "timed out waiting for a worker",
        sourceLocation: sourceLocation
    )
}

#if canImport(Darwin)
/// Spins until `condition` holds, giving up rather than hanging the run.
///
/// Some states no signal announces — a reader having registered, a port having
/// been created. A bounded spin reports a regression as a failure; an unbounded
/// one would report it as a six-hour CI timeout.
func spin(untilTrue condition: () -> Bool, within seconds: Double = 10) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        sched_yield()
    }
    return condition()
}

/// How many readers have registered behind the writer holding `handle`.
///
/// Registered, not parked: a reader counts itself before it reaches the wait, so
/// this going up says a reader is on its way in, not that it is already asleep.
func registeredReaders(of handle: borrowing _RWLockHandle) -> Int32 {
    handle.readerCount.load(ordering: .relaxed) &+ _RWLockHandle._maxReaders
}
#endif
