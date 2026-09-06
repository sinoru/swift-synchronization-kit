//
//  TestSupport.swift
//  SynchronizationKit
//

import Testing

@testable import SynchronizationKitAsyncMutex

// Every `Task { }` in these suites spells out `@Sendable`. The lock under test
// is a local `let`, and on Swift 6.2 and 6.3 the region checker treats a
// local of a `@_staticExclusiveOnly` type captured by a `sending` closure as
// though the closure carried the local off with it, so a second closure
// capturing the same lock is rejected as a concurrent access — the standard
// library's own `Mutex` gets the same diagnosis there. A `@Sendable` closure
// is checked by capture instead and passes; Swift 6.4 accepts both. Real code
// keeps such a lock in a class, an actor, or a global, which is unaffected.

/// A one-shot signal: `wait()` suspends until `open()` has been called.
struct Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func open() {
        continuation.yield(())
        continuation.finish()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}

extension AsyncMutex where Value: ~Copyable {
    /// Suspends until `count` tasks are queued for the lock.
    ///
    /// Tests that release a lock or cancel a waiter need the waiter to have
    /// actually joined the queue first, which a task's mere existence does
    /// not guarantee.
    func waitForWaiters(_ count: Int) async {
        while handle._waiterCount < count {
            await Task.yield()
        }
    }
}

/// Polls `condition` until it holds or `attempts` yields have passed.
func eventually(attempts: Int = 100_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}
