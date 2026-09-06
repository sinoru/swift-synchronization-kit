//
//  Polling.swift
//  SynchronizationKit
//

// The extensions below add `package` members to types from both modules,
// which needs each to be visible at that level.
package import SynchronizationKitAsyncCore
package import SynchronizationKitAsyncMutex

/// Polls `condition` until it holds, giving up after `attempts` polls a
/// millisecond apart — about ten seconds by default.
///
/// It sleeps between polls rather than yielding, for two reasons. A yield
/// costs well under a microsecond when nothing else wants the thread, so a
/// count of yields is no bound in time at all: a hundred thousand of them
/// can pass in under a tenth of a second, before the task the condition is
/// waiting on has even been scheduled. And a sleep gives the thread up,
/// which under a loaded run is what lets that task get scheduled.
package func eventually(attempts: Int = 10_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

extension _AsyncWaitQueueOwner {
    /// Suspends until `count` tasks are queued.
    ///
    /// Tests that release, signal, or cancel a waiter need the waiter to have
    /// actually joined the queue first, which a task's mere existence does
    /// not guarantee.
    package func waitForWaiters(_ count: Int) async {
        while _waiterCount < count {
            await Task.yield()
        }
    }
}

extension AsyncMutex where Value: ~Copyable {
    /// Suspends until `count` tasks are queued for the lock.
    package func waitForWaiters(_ count: Int) async {
        await handle.waitForWaiters(count)
    }
}
