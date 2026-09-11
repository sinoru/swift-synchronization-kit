//
//  AsyncSemaphore.swift
//  SynchronizationKit
//

// `AsyncSemaphore` is public and conforms to `_AsyncWaitQueueOwner` directly,
// where `AsyncMutex` puts a handle in between. A conformance on a public type
// counts as public however the protocol is declared, and the compiler will not
// admit one from a module that is not imported publicly. Nothing leaks by it:
// everything the module declares is `package`, so a client can name none of
// it.
public import SynchronizationKitAsyncCore
package import SynchronizationKitMutex

/// A counting semaphore that suspends the calling task, rather than blocking
/// its thread, while it waits for a signal — and that a thread may wait on
/// too.
///
/// This is `Semaphore` restated for Swift Concurrency: `wait()` decrements
/// the count, suspending until a signal arrives if it is zero, and
/// `signal()` increments it, resuming a waiting task if there is one. The
/// difference is that the wait is a suspension point instead of a blocked
/// thread, which is what lets it be called from a task at all —
/// `Semaphore.wait()`, like `DispatchSemaphore.wait()`, is unavailable from
/// asynchronous contexts.
///
///     final class Downloader: Sendable {
///         private let slots = AsyncSemaphore(value: 4)
///
///         func download(_ url: URL) async throws -> Data {
///             try await slots.wait()
///             defer { slots.signal() }
///             return try await fetch(url)
///         }
///     }
///
/// A semaphore is a count, not a lock: the task that signals need not be the
/// one that waited, which is what makes it fit for handing work between tasks
/// or bounding how many of them run at once. For protecting a value, use
/// `AsyncMutex`, which owns the value and knows who holds it.
///
/// ## One count, two kinds of waiter
///
/// `wait()` comes in two forms with one name: the asynchronous one above,
/// and a synchronous one that blocks the calling thread, for the thread that
/// has no task to suspend — a `main` waiting for the work it started, a
/// callback-based API being given a synchronous face. Both take from the
/// same count and wait in the same queue, so a thread and a task can wait on
/// one semaphore and be signaled from either side:
///
///     let done = AsyncSemaphore(value: 0)
///     Task {
///         await run()
///         done.signal()
///     }
///     done.wait()    // on a thread of its own, until the task signals
///
/// The compiler picks the form by where the call is: the asynchronous one
/// wherever `await` is possible, the synchronous one elsewhere. The
/// synchronous one is unavailable from asynchronous contexts, as
/// `Semaphore.wait()` is, so a task cannot reach it by mistake — including
/// from a `Task { }` body with no other `await` in it, where overload
/// resolution alone would have chosen it. Wrapping the call in a synchronous
/// closure gets around that, as it does for every `noasync` declaration, and
/// blocks a thread of the cooperative pool, which is the deadlock this is
/// designed against.
///
/// This is the semaphore for a count that threads and tasks share, not for
/// threads alone: a thread waits here through a lock and a queue and a park
/// of its own, where `Semaphore` hands off in the kernel, and under
/// contention that is several times the cost. Threads that only ever wait on
/// threads belong on `Semaphore`.
///
/// ## Waiting, cancellation, and priority
///
/// When the count is positive `wait()` takes one without suspending;
/// otherwise the task joins a queue and is resumed by a signal, which hands
/// it the count directly, so a newcomer cannot overtake it. Waiters are
/// served in priority order, and in arrival order among equals. A task or a
/// thread waits at the priority `Task.currentPriority` reports for it — a
/// thread's is its QoS on Darwin — and takes its turn among the rest on those
/// terms.
///
/// A task that is cancelled while waiting stops waiting: `wait()` throws
/// `CancellationError` and the count is untouched. A task that is already
/// cancelled when it calls `wait()` still takes a positive count —
/// cancellation ends waiting, not acquiring — but throws instead of joining
/// the queue. A thread has no cancellation: its `wait()` returns when a
/// signal reaches it and not before, which is what `Semaphore.wait()`
/// promises too.
///
/// Cancellation is also how a wait is bounded in time. There is no
/// `wait(timeout:)`, for the reason `Task.sleep` has none: in Swift
/// Concurrency a deadline is a task that gets cancelled. Keep what the count
/// is used for inside the task that waited, so a count granted just as the
/// deadline lands is put back rather than stranded:
///
///     try await withThrowingTaskGroup(of: Void.self) { group in
///         group.addTask {
///             try await slots.wait()
///             defer { slots.signal() }
///             try await work()
///         }
///         group.addTask {
///             try await Task.sleep(for: .seconds(10))
///             throw TimedOut()
///         }
///         try await group.next()
///         group.cancelAll()
///     }
///
/// Unlike `AsyncMutex`, a semaphore has no holder to escalate: a count may be
/// taken by many tasks at once and given back by any task, so there is no one
/// task whose priority a waiter could raise. `DispatchSemaphore` has no
/// ownership for the same reason. A waiter's own escalation does move it up
/// the queue, when the package is built with Swift 6.4 or later; a 6.3 build
/// leaves a queued waiter at the priority it arrived with, as does a thread
/// on any build, there being no task to escalate.
///
/// A semaphore stays alive for as long as any task waits on it: the wait
/// itself holds a reference, through the cancellation handler it installs.
/// Each waiting task is suspended on a continuation that only a signal can
/// resume, so a semaphore that nothing else references, with a waiter and no
/// prospect of a signal, is a leaked task rather than a dangling one — the
/// same bargain `DispatchSemaphore` makes. A waiting thread holds a
/// reference of its own for as long as it blocks, and is a blocked thread
/// on the same terms.
public final class AsyncSemaphore: Sendable {
    package let state: Mutex<_State>

    /// Creates a semaphore whose count starts at `value`.
    ///
    /// - Parameter value: How many waits can succeed before one has to
    ///   suspend. Must not be negative.
    public init(value: Int) {
        precondition(value >= 0, "AsyncSemaphore requires a non-negative initial value")
        state = Mutex(_State(value: value))
    }

    deinit {
        // Unreachable with a waiter queued — `_wait` holds `self` through the
        // handler it installs for as long as the task waits, and a blocked
        // thread holds it from its own frame — and kept as the statement of
        // that invariant, where a change to the waiting layer that broke it
        // would surface.
        precondition(
            state.withLock { $0.queue.isEmpty },
            "AsyncSemaphore deallocated while tasks are waiting on it"
        )
    }
}

/// The count and who is waiting for it. Guarded by `state`.
///
/// The queue is non-empty only while `value` is zero: a signal that finds a
/// waiter hands the count to it rather than incrementing, so the two never
/// coexist.
package struct _State: _AsyncWaitState {
    var value: Int

    /// There is one thing to ask a semaphore for, so a waiter asks for
    /// nothing in particular.
    package var queue = _AsyncWaitQueue<Void>()
}

// MARK: - Waiting

extension AsyncSemaphore: _AsyncWaitQueueOwner {
    package func _tryAcquire(_ request: Void) -> Bool {
        state.withLock { state in
            guard state.value > 0 else {
                return false
            }
            state.value -= 1
            return true
        }
    }

    package func _acquireIfAvailable(_ state: inout _State, for waiter: _AsyncWaiter<Void>) -> Bool {
        guard state.value > 0 else {
            return false
        }
        state.value -= 1
        return true
    }

    /// Decrements the count, suspending until a signal arrives if it is zero.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting,
    ///   or would have to wait while already cancelled.
    public nonisolated(nonsending) func wait() async throws {
        try await _acquire()
    }

    /// Decrements the count, blocking the calling thread until a signal
    /// arrives if it is zero.
    ///
    /// This is the `wait()` for a thread with no task to suspend. It takes
    /// from the same count and waits in the same queue as the asynchronous
    /// one, and cannot be cancelled. It blocks the calling thread, which is
    /// why it is unavailable from asynchronous contexts, where the
    /// asynchronous `wait()` is chosen instead.
    @available(*, noasync, message: "Blocks the thread; await wait() instead")
    public func wait() {
        _acquireBlocking(())
    }
}

// MARK: - Signaling

extension AsyncSemaphore {
    /// Increments the count, resuming the next waiting task if there is one.
    ///
    /// - Returns: Whether a task was resumed. `false` means nobody was
    ///   waiting, and the count went up instead.
    @discardableResult
    public func signal() -> Bool {
        let next = state.withLock { state -> _Grant? in
            guard let waiter = state.queue.removeNext() else {
                state.value += 1
                return nil
            }
            return waiter.grant()
        }

        guard let next else {
            return false
        }
        next.complete()
        return true
    }
}
