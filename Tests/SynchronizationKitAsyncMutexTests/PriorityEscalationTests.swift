//
//  PriorityEscalationTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncCore
import SynchronizationKitAsyncMutex
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

/// Escalation needs the runtime support that arrived with Swift 6.2's
/// standard library, so these run only where `AsyncMutex` itself escalates.
///
/// Skipped under ThreadSanitizer on Linux for the reason `AsyncMutexTests`
/// gives.
@Suite(
    "AsyncMutex priority escalation",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct PriorityEscalationTests {
    @Test("a higher-priority waiter raises the holder's priority")
    @available(anyAppleOS 26.0, *)
    func waiterEscalatesHolder() async throws {
        let mutex = AsyncMutex(0)
        let release = Gate()

        let holder = Task(priority: .low) { @Sendable in
            try await mutex.withLock { _ -> Bool in
                // Wait for the escalation the high-priority waiter below is
                // expected to cause, rather than for the gate: the gate only
                // bounds how long a failing run spins.
                let escalated = await eventually { Task.currentPriority >= .high }
                await release.wait()
                return escalated
            }
        }
        await eventuallyHeld(mutex)

        let waiter = Task(priority: .high) { @Sendable in
            try await mutex.withLock { _ in }
        }
        await mutex.waitForWaiters(1)
        release.open()

        #expect(try await holder.value == true)
        try await waiter.value
    }

    // Only a 6.4 build installs the handler this relies on; `_acquire` says
    // why.
    #if compiler(>=6.4)
    @Test("a waiter escalated while queued passes the escalation on to the holder")
    @available(anyAppleOS 26.0, *)
    func escalatedWaiterEscalatesHolder() async throws {
        let mutex = AsyncMutex(0)
        let release = Gate()

        let holder = Task(priority: .low) { @Sendable in
            try await mutex.withLock { _ -> Bool in
                let escalated = await eventually { Task.currentPriority >= .high }
                await release.wait()
                return escalated
            }
        }
        await eventuallyHeld(mutex)

        let waiter = Task(priority: .low) { @Sendable in
            try await mutex.withLock { _ in }
        }
        await mutex.waitForWaiters(1)

        // Raise the waiter, not the holder. The waiter's escalation handler
        // is what must carry it across.
        waiter.escalatePriority(to: .high)
        release.open()

        #expect(try await holder.value == true)
        try await waiter.value
    }

    /// The queue keeps its highest priority as waiters come and go rather
    /// than scanning for it, and a waiter raised while queued moves within
    /// that record: it has to be counted once at the priority it leaves
    /// and once at the one it joins, or the record outlives the queue.
    /// Caught here by what a stale record does next — with nobody waiting,
    /// a later low-priority holder is raised to a priority nobody holds.
    @Test("a waiter raised while queued leaves no priority behind when served")
    @available(anyAppleOS 26.0, *)
    func raisedWaiterLeavesNoPriorityBehind() async throws {
        let mutex = AsyncMutex(0)
        let release = Gate()

        let holder = Task(priority: .low) { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        // The only waiter, so it is the only one at the queue's maximum.
        let waiter = Task(priority: .low) { @Sendable in
            try await mutex.withLock { _ in }
        }
        await mutex.waitForWaiters(1)
        waiter.escalatePriority(to: .high)
        #expect(mutex.handle.state.withLock { $0.queue.highestPriority } == .high)

        release.open()
        try await holder.value
        try await waiter.value

        // Served and gone: the queue is empty, and has to say so.
        #expect(mutex.handle.state.withLock { $0.queue.highestPriority } == nil)

        // And a fresh holder, at low priority with nobody behind it, is left
        // where it is. Its priority is read through a gate rather than by
        // awaiting the task, since awaiting a task raises it to the
        // awaiter's priority — the runtime's doing, not the lock's.
        let observed = Mutex<TaskPriority?>(nil)
        let reported = Gate()
        let later = Task(priority: .low) { @Sendable in
            try await mutex.withLock { _ in
                await Task.yield()
                observed.withLock { $0 = Task.currentPriority }
                reported.open()
            }
        }
        await reported.wait()
        #expect(observed.withLock { $0 } == .low)
        try await later.value
    }
    #endif

    @Test("a handoff escalates the new holder to the queue left behind it")
    @available(anyAppleOS 26.0, *)
    func handoffEscalatesNewHolder() async throws {
        let mutex = AsyncMutex(0)
        let release = Gate()
        let secondRelease = Gate()

        let holder = Task(priority: .high) { @Sendable in
            try await mutex.withLock { _ in await release.wait() }
        }
        await eventuallyHeld(mutex)

        // Queue a high-priority waiter first, then a low one. The queue is
        // served by priority, so the high waiter goes first and the low one
        // waits behind it. Only after the high waiter has released should a
        // *later* high-priority arrival be able to escalate the low holder.
        let first = Task(priority: .high) { @Sendable in
            try await mutex.withLock { _ in }
        }
        await mutex.waitForWaiters(1)

        let low = Task(priority: .low) { @Sendable in
            try await mutex.withLock { _ -> Bool in
                let escalated = await eventually { Task.currentPriority >= .high }
                await secondRelease.wait()
                return escalated
            }
        }
        await mutex.waitForWaiters(2)

        release.open()
        try await holder.value
        try await first.value

        // `low` now holds the lock at low priority. A high-priority arrival
        // must raise it.
        let second = Task(priority: .high) { @Sendable in
            try await mutex.withLock { _ in }
        }
        await mutex.waitForWaiters(1)
        secondRelease.open()

        #expect(try await low.value == true)
        try await second.value
    }
}
