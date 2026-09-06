//
//  Gate.swift
//  SynchronizationKit
//

import SynchronizationKitMutex

/// A one-shot signal: `wait()` suspends until `open()` has been called, and
/// every task waiting at that moment resumes.
///
/// Built on the package's own `Mutex` and a list of continuations. An
/// `AsyncStream` would be the obvious shape, and was the first one, but it is
/// single-consumer by contract and only became safe to share by accident: on
/// runtimes older than Swift 6.1 — iOS and tvOS before 18.4, watchOS before
/// 11.4, visionOS before 2.4 — `finish()` resumes one pending iterator and
/// leaks the rest, and since `AsyncStream` ships with the OS rather than the
/// toolchain, the simulator decides which behavior a test sees.
///
/// Leaning on `Mutex` costs nothing in independence: it is a synchronous
/// primitive with a suite of its own that never touches a gate, while the gate
/// only ever serves the asynchronous suites.
package final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    package init() {}

    /// Opens the gate and resumes every waiter. Idempotent: a second call finds
    /// nobody waiting and changes nothing.
    package func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends until the gate is open. Returns at once if it already is.
    package func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen {
                    state.waiters.append(continuation)
                }
                return state.isOpen
            }
            if isOpen {
                continuation.resume()
            }
        }
    }
}
