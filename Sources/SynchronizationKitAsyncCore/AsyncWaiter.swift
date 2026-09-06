//
//  AsyncWaiter.swift
//  SynchronizationKit
//

import CSynchronizationKitAsyncCore

/// A task waiting in an `_AsyncWaitQueue`. Everything but `task` and `request`
/// is guarded by the owning primitive's state lock.
///
/// `Request` is what the task asked for, for a primitive that hands out more
/// than one kind of access — read or write, say. A primitive with one kind
/// uses `Void`.
///
/// `@safe`: the unsafe part is the task reference, and every read of it is
/// marked as such. `@unchecked Sendable` for the same reference: the SDK's
/// `UnsafeCurrentTask` does not declare `Sendable`, and escalating a task
/// from another thread is one of the operations its documentation permits.
///
/// A waiter's own address is the token its handoff is annotated on for
/// ThreadSanitizer: `grant()` releases it, `_AsyncWaitQueueOwner._wait`
/// acquires it once the task is back, and the two pair exactly once per
/// waiter. The handle's address would pair every grant with every resumption
/// and put edges on record that were never made.
@safe
package final class _AsyncWaiter<Request: Sendable>: @unchecked Sendable {
    package enum Phase {
        /// Created, but not yet suspended on a continuation.
        case pending
        /// In the queue, suspended on this continuation.
        case waiting(CheckedContinuation<Void, any Error>)
        /// Granted what it waited for; the continuation has been resumed.
        case granted
        /// Left the queue by cancellation; the continuation has been resumed,
        /// or will be told not to suspend at all.
        case cancelled
    }

    /// The waiting task. Valid for as long as the task waits, and, once
    /// granted, for as long as it then holds what it was granted.
    @unsafe package let task: UnsafeCurrentTask?

    /// What the task is waiting for.
    package let request: Request

    /// The waiter's priority as last observed. An escalation handler raises
    /// it while the task waits, through `_AsyncWaitQueue.raisePriority`, so
    /// the queue's own record of its maximum keeps up.
    package internal(set) var priority: TaskPriority

    package var phase: Phase = .pending

    package init(task: UnsafeCurrentTask?, request: Request, priority: TaskPriority) {
        unsafe self.task = task
        self.request = request
        self.priority = priority
    }

    /// Marks the waiter as granted and returns the continuation that resumes
    /// it, for the caller to resume once it has let go of the state lock.
    ///
    /// Also where the handoff is put on record for ThreadSanitizer: before
    /// the continuation is handed back, so the edge exists by the time
    /// anything can resume on it. Under the state lock, which is fine — the
    /// call is an annotation, not a wait.
    ///
    /// - Precondition: The waiter is queued, which is to say suspended.
    package func grant() -> CheckedContinuation<Void, any Error> {
        guard case .waiting(let continuation) = phase else {
            preconditionFailure("queued a waiter that was not waiting")
        }
        phase = .granted
        unsafe sk_async_core_tsan_release(Unmanaged.passUnretained(self).toOpaque())
        return continuation
    }
}
