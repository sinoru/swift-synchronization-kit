//
//  PriorityEscalationTests.swift
//  SynchronizationKit
//

import SynchronizationKitAsyncRWLock
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import Testing

/// Escalation needs the runtime support that arrived with Swift 6.2's
/// standard library, so these run only where `AsyncRWLock` itself escalates.
///
/// Skipped under ThreadSanitizer on Linux for the reason `AsyncRWLockTests`
/// gives.
@Suite(
    "AsyncRWLock priority escalation",
    .disabled(
        if: !implementationIsThisPackage && threadSanitizerIsLoaded,
        "ThreadSanitizer does not model the standard library's Linux mutex."
    )
)
struct PriorityEscalationTests {
    @Test("a higher-priority waiting writer raises every reader holding the lock")
    @available(anyAppleOS 26.0, *)
    func writerEscalatesReaders() async throws {
        let lock = AsyncRWLock(0)
        let inside = Mutex(0)
        let release = Gate()
        let readers = 3

        var holders: [Task<Bool, any Error>] = []
        for _ in 0..<readers {
            holders.append(Task(priority: .low) { @Sendable in
                try await lock.withReadLock { _ -> Bool in
                    inside.withLock { $0 += 1 }
                    // Wait for the escalation the high-priority writer below
                    // is expected to cause, rather than for the gate: the
                    // gate only bounds how long a failing run spins.
                    let escalated = await eventually { Task.currentPriority >= .high }
                    await release.wait()
                    return escalated
                }
            })
        }
        #expect(await eventually { inside.withLock { $0 } == readers })

        let writer = Task(priority: .high) { @Sendable in
            try await lock.withWriteLock { _ in }
        }
        await lock.waitForWaiters(1)
        release.open()

        for holder in holders {
            #expect(try await holder.value == true)
        }
        try await writer.value
    }

    @Test("a higher-priority waiting reader raises the writer holding the lock")
    @available(anyAppleOS 26.0, *)
    func readerEscalatesWriter() async throws {
        let lock = AsyncRWLock(0)
        let acquired = Gate()
        let release = Gate()

        let holder = Task(priority: .low) { @Sendable in
            try await lock.withWriteLock { _ -> Bool in
                acquired.open()
                let escalated = await eventually { Task.currentPriority >= .high }
                await release.wait()
                return escalated
            }
        }
        await acquired.wait()

        let reader = Task(priority: .high) { @Sendable in
            try await lock.withReadLock { _ in }
        }
        await lock.waitForWaiters(1)
        release.open()

        #expect(try await holder.value == true)
        try await reader.value
    }

    // Only a 6.4 build installs the handler this relies on; `_acquire` says
    // why.
    #if compiler(>=6.4)
    @Test("a waiter escalated while queued passes the escalation on to the holders")
    @available(anyAppleOS 26.0, *)
    func escalatedWaiterEscalatesHolders() async throws {
        let lock = AsyncRWLock(0)
        let acquired = Gate()
        let release = Gate()

        let holder = Task(priority: .low) { @Sendable in
            try await lock.withReadLock { _ -> Bool in
                acquired.open()
                let escalated = await eventually { Task.currentPriority >= .high }
                await release.wait()
                return escalated
            }
        }
        await acquired.wait()

        let writer = Task(priority: .low) { @Sendable in
            try await lock.withWriteLock { _ in }
        }
        await lock.waitForWaiters(1)

        // Raise the waiter, not the holder. The waiter's escalation handler
        // is what must carry it across.
        writer.escalatePriority(to: .high)
        release.open()

        #expect(try await holder.value == true)
        try await writer.value
    }
    #endif

    @Test("a handoff escalates the new holders to the queue left behind them")
    @available(anyAppleOS 26.0, *)
    func handoffEscalatesNewHolders() async throws {
        let lock = AsyncRWLock(0)
        let acquired = Gate()
        let release = Gate()
        let secondRelease = Gate()

        let holder = Task(priority: .high) { @Sendable in
            try await lock.withWriteLock { _ in
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        // Queue a low-priority reader, then a high-priority writer. The queue
        // is served by priority, so the writer goes first, alone, and the
        // reader is admitted when it departs. Only then should a *later*
        // high-priority arrival be able to escalate the low reader.
        let low = Task(priority: .low) { @Sendable in
            try await lock.withReadLock { _ -> Bool in
                let escalated = await eventually { Task.currentPriority >= .high }
                await secondRelease.wait()
                return escalated
            }
        }
        await lock.waitForWaiters(1)
        let first = Task(priority: .high) { @Sendable in
            try await lock.withWriteLock { _ in }
        }
        await lock.waitForWaiters(2)

        release.open()
        try await holder.value
        try await first.value

        // `low` now holds the lock at low priority. A high-priority arrival
        // must raise it.
        let second = Task(priority: .high) { @Sendable in
            try await lock.withWriteLock { _ in }
        }
        await lock.waitForWaiters(1)
        secondRelease.open()

        #expect(try await low.value == true)
        try await second.value
    }
}
