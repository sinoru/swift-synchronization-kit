//
//  AsyncMutexHandle.swift
//  SynchronizationKit
//

// Both name types in this handle's `package` declarations — the wait queue
// and the mutex it lives under — so both are imported at that level.
package import SynchronizationKitAsyncCore
package import SynchronizationKitMutex

/// The bookkeeping behind `AsyncMutex`: which task holds the lock, and which
/// tasks are waiting for it.
///
/// This is a class where `_MutexHandle` is inline storage because the
/// cancellation and priority-escalation handlers installed around a wait are
/// closures that reach this state from whichever thread cancels or escalates
/// the waiting task, and a closure cannot capture a borrowed inline value. It
/// costs one allocation per lock; the protected value itself is still stored
/// inline in the `AsyncMutex`.
///
/// The waiting — queueing, suspending, cancellation — comes from
/// `_AsyncWaitQueueOwner`, and the escalation of the holder, with the lock
/// ordering it rests on, from `_AsyncHolderEscalating`; what this adds is
/// the holder itself.
/// `@usableFromInline` for `AsyncMutex`'s locking methods, which inline into
/// their callers and reach the lock through `_lock`, `_tryLock`, and
/// `_unlock` below: concrete entry points, so that the wait queue's protocols
/// stay `package` and a client's module has nothing of theirs to name. The
/// conformance is declared apart from the class for the same reason.
@usableFromInline
package final class _AsyncMutexHandle {
    /// The state proper. See `_AsyncWaitQueueOwner`'s lock-ordering note.
    package let state = Mutex<_State>(_State())

    /// See `_AsyncHolderEscalating`'s lock-ordering note.
    package let escalation = Mutex<Void>(())

    internal init() {}
}

extension _AsyncMutexHandle: _AsyncHolderEscalating {}

/// Who holds the lock and who is waiting for it. Guarded by `state`.
package struct _State: _AsyncWaitState {
    /// The task holding the lock, or `nil` while the lock is free.
    var holder: _AsyncHolder?

    /// There is one thing to ask a mutex for, so a waiter asks for nothing
    /// in particular.
    package var queue = _AsyncWaitQueue<Void>()
}

// MARK: - Acquiring

extension _AsyncMutexHandle {
    /// Acquires the lock, suspending while another task holds it.
    @usableFromInline
    package nonisolated(nonsending) func _lock() async throws {
        try await _acquire()
    }

    /// Takes the lock if it is free, without suspending.
    @usableFromInline
    package func _tryLock() -> Bool {
        _tryAcquire()
    }

    /// Acquires the lock, blocking the calling thread while another task or
    /// thread holds it.
    @available(*, noasync, message: "Blocks the thread; await _lock() from a task")
    @usableFromInline
    package func _lockBlocking() {
        _acquireBlocking(())
    }

    /// Takes the lock if it is free, without suspending.
    ///
    /// The holder is recorded without its priority: `_AsyncHolder` says why
    /// the fast path does not ask.
    package func _tryAcquire(_ request: Void) -> Bool {
        let task = unsafe withUnsafeCurrentTask { unsafe $0 }

        return state.withLock { state in
            guard state.holder == nil else {
                return false
            }
            state.holder = unsafe _AsyncHolder(task: task)
            return true
        }
    }

    package func _acquireIfAvailable(_ state: inout _State, for waiter: _AsyncWaiter<Void>) -> Bool {
        guard state.holder == nil else {
            return false
        }
        state.holder = unsafe _AsyncHolder(task: waiter.task, priority: waiter.priority)
        return true
    }

    package func _waiterDidQueue() {
        if #available(anyAppleOS 26.0, *) {
            _escalateHoldersIfNeeded()
        }
    }

    package func _waiterPriorityDidRise() {
        if #available(anyAppleOS 26.0, *) {
            _escalateHoldersIfNeeded()
        }
    }
}

// MARK: - Releasing

extension _AsyncMutexHandle {
    /// Releases the lock, handing it directly to the next waiter if there is
    /// one.
    ///
    /// The handoff transfers ownership while the lock stays marked as held,
    /// so a newcomer cannot slip in between a release and the waiter's
    /// resumption, and the waiter never has to contend again.
    ///
    @usableFromInline
    package func _unlock() {
        let (next, pinned, outranked) = state.withLock { state -> (_Grant?, Bool, Bool) in
            guard let holder = state.holder else {
                preconditionFailure("AsyncMutex released while not held")
            }
            let pinned = holder.wasReadForEscalation

            guard let waiter = state.queue.removeNext() else {
                state.holder = nil
                return (nil, pinned, false)
            }

            // The new holder inherits the queue that was behind it, which may
            // outrank it: decided here, in the critical section that put it
            // there, for the departure to act on.
            state.holder = unsafe _AsyncHolder(task: waiter.task, priority: waiter.priority)
            return (waiter.grant(), pinned, _needsEscalation(state))
        }

        next?.complete()

        if #available(anyAppleOS 26.0, *) {
            _departHolder(pinned: pinned, outranked: outranked)
        }
    }
}

// MARK: - Priority escalation

extension _AsyncMutexHandle {
    package func _nextEscalation(_ state: inout _State) -> (UnsafeCurrentTask, TaskPriority)? {
        guard var holder = state.holder, let priority = state.queue.highestPriority else {
            return nil
        }
        let task = unsafe holder._raise(to: priority)
        state.holder = holder
        return unsafe task.map { unsafe ($0, priority) }
    }

    package func _needsEscalation(_ state: _State) -> Bool {
        guard let holder = state.holder, let priority = state.queue.highestPriority else {
            return false
        }
        return holder._isBelow(priority)
    }
}
