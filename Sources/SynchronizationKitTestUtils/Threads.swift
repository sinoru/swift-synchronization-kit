//
//  Threads.swift
//  SynchronizationKit
//

// The synchronous suites drive threads, and join them by `DispatchSemaphore`
// rather than by the primitive under test. Both helpers are bounded: a wait
// that never returns is reported as a failure, not as a six-hour CI timeout,
// which this repository has already paid for once.
//
// Guarded on `Testing` because this is not a test target, and the static
// Linux SDK ships no testing library: the musl row builds this target and
// runs nothing, so what it cannot link it must not see.
#if canImport(Testing) && canImport(Dispatch)
// `package import`: both name types in the signatures below.
package import Dispatch
import Foundation
package import Testing

/// Waits for `semaphore`, failing rather than hanging if it never arrives.
///
/// `.timeLimit` would say this once for a whole suite, but it needs iOS 16 and
/// watchOS 9 and this package deploys below both, so every join is bounded by
/// hand.
package func expectSignal(
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

/// Spins until `condition` holds, giving up rather than hanging the run.
///
/// Some states no signal announces — a reader having registered, a port having
/// been created. A bounded spin reports a regression as a failure; an unbounded
/// one would report it as a timeout.
package func spin(untilTrue condition: () -> Bool, within seconds: Double = 10) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.0001)
    }
    return condition()
}
#endif
