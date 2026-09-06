//
//  PriorityEscalationTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncMutex
import SynchronizationKitTestUtils
import Testing

/// Escalation needs the runtime support that arrived with Swift 6.2's
/// standard library, so these run only where `AsyncMutex` itself escalates.
@Suite("AsyncMutex priority escalation")
struct PriorityEscalationTests {
    @Test("a higher-priority waiter raises the holder's priority")
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
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

    @Test("a waiter escalated while queued passes the escalation on to the holder")
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
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

    @Test("a handoff escalates the new holder to the queue left behind it")
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
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
