//
//  AsyncRWLockHandle.swift
//  SynchronizationKit
//

// Both name types in this handle's `package` declarations — the wait queue
// and the mutex it lives under — so both are imported at that level.
package import SynchronizationKitAsyncCore
package import SynchronizationKitMutex

/// What a task asks an `AsyncRWLock` for.
package enum _Access: Sendable {
    /// Shared access, alongside any number of other readers.
    case read
    /// Exclusive access.
    case write
}

/// The bookkeeping behind `AsyncRWLock`: which tasks hold the lock, in which
/// mode, and which tasks are waiting for it.
///
/// A class for the reason `_AsyncMutexHandle` is: the handlers installed
/// around a wait reach this state from whichever thread cancels or escalates
/// the waiting task. The protected value itself is still stored inline in the
/// `AsyncRWLock`.
///
/// The waiting — queueing, suspending, cancellation — comes from
/// `_AsyncWaitQueueOwner`, and the escalation of holders from
/// `_AsyncHolderEscalating`; what this adds is the two kinds of holder and
/// the policy that decides who is served when.
///
/// ## Service policy
///
/// The queue is served in priority order, and in arrival order among equals,
/// as `AsyncMutex`'s is. A task that finds anyone queued joins the queue
/// whatever it asks for, so a newcomer never overtakes a waiter; and since a
/// writer waits only while somebody holds the lock, that is what makes the
/// lock writer-preferring: a waiting writer stops new readers from reading.
///
/// Whenever a holder departs, the head of the queue is served if the lock's
/// mode now permits it — a reader while no writer holds the lock, a writer
/// once nobody does — and then the new head, and so on, until the head is
/// something the mode does not permit. A run of readers at the head is thus
/// admitted together, and stops at the first writer among them; a writer is
/// admitted alone. Nothing is ever served past a head that must wait.
///
/// The same pass runs after a cancelled waiter has left the queue, from its
/// own task once it has been resumed: a writer that leaves may have been all
/// that held the readers behind it back.
/// `@usableFromInline` for `AsyncRWLock`'s locking methods, which inline
/// into their callers, on the terms `_AsyncMutexHandle` states.
@usableFromInline
package final class _AsyncRWLockHandle {
    /// The state proper. See `_AsyncWaitQueueOwner`'s lock-ordering note.
    package let state = Mutex<_State>(_State())

    /// See `_AsyncHolderEscalating`'s lock-ordering note.
    package let escalation = Mutex<Void>(())

    internal init() {}
}

extension _AsyncRWLockHandle: _AsyncHolderEscalating {}

/// Who holds the lock, how, and who is waiting for it. Guarded by `state`.
///
/// `writer` and `readers` are never both populated.
package struct _State: _AsyncWaitState {
    /// The task holding the lock for writing, or `nil` while none does.
    var writer: _AsyncHolder?

    /// The tasks holding the lock for reading. A task that reads recursively
    /// appears once per hold.
    var readers: [_AsyncHolder] = []

    package var queue = _AsyncWaitQueue<_Access>()

    /// Whether the lock's current mode admits `access` — leaving aside who
    /// may be queued ahead, which is the caller's business.
    fileprivate func _permits(_ access: _Access) -> Bool {
        switch access {
        case .read:
            writer == nil
        case .write:
            writer == nil && readers.isEmpty
        }
    }

    /// Records a holder of `access`: at `priority` where it waited and was
    /// served at one, and unasked otherwise, as `_AsyncHolder` explains.
    fileprivate mutating func _hold(
        _ access: _Access,
        task: UnsafeCurrentTask?,
        priority: TaskPriority? = nil
    ) {
        let holder = if let priority {
            unsafe _AsyncHolder(task: task, priority: priority)
        } else {
            unsafe _AsyncHolder(task: task)
        }
        switch access {
        case .read:
            readers.append(holder)
        case .write:
            writer = holder
        }
    }
}

// MARK: - Acquiring

extension _AsyncRWLockHandle {
    /// Acquires the lock for reading, suspending while a writer holds it or
    /// waits ahead.
    @usableFromInline
    package nonisolated(nonsending) func _readLock() async throws {
        try await _acquire(.read)
    }

    /// Takes the lock for reading if that can be had without waiting.
    @usableFromInline
    package func _tryReadLock() -> Bool {
        _tryAcquire(.read)
    }

    /// Acquires the lock for writing, suspending while anyone holds it.
    @usableFromInline
    package nonisolated(nonsending) func _writeLock() async throws {
        try await _acquire(.write)
    }

    /// Takes the lock for writing if that can be had without waiting.
    @usableFromInline
    package func _tryWriteLock() -> Bool {
        _tryAcquire(.write)
    }

    /// Takes the lock for `access` if that can be had without waiting.
    ///
    /// Unlike `_AsyncMutexHandle`, this has to look at the queue as well as
    /// the holders: a reader may find the lock read-held and still have to
    /// wait, because a writer is queued ahead of it.
    package func _tryAcquire(_ access: _Access) -> Bool {
        let task = unsafe withUnsafeCurrentTask { unsafe $0 }

        return state.withLock { state in
            guard state.queue.isEmpty, state._permits(access) else {
                return false
            }
            unsafe state._hold(access, task: task)
            return true
        }
    }

    package func _acquireIfAvailable(_ state: inout _State, for waiter: _AsyncWaiter<_Access>) -> Bool {
        guard state._permits(waiter.request) else {
            return false
        }
        unsafe state._hold(waiter.request, task: waiter.task, priority: waiter.priority)
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

    package func _waiterDidCancel() {
        let (admitted, outranked) = state.withLock { state in
            _admit(&state)
        }
        for grant in admitted {
            grant.complete()
        }

        if #available(anyAppleOS 26.0, *), outranked {
            // Whoever was let in inherits the queue behind it.
            _escalateHoldersIfNeeded()
        }
    }
}

// MARK: - Releasing

extension _AsyncRWLockHandle {
    /// Gives up a read hold, and serves whoever that lets in.
    ///
    /// The hold is found by task: the task that took the lock is the one
    /// releasing it, and a task that holds it more than once gives up one
    /// hold per call.
    ///
    @usableFromInline
    package func _readUnlock() {
        let task = unsafe withUnsafeCurrentTask { unsafe $0 }

        let (pinned, admitted, outranked) = state.withLock { state in
            guard let index = state.readers.firstIndex(where: { unsafe $0.task == task }) else {
                preconditionFailure("AsyncRWLock read-unlocked by a task that does not hold it")
            }
            let pinned = state.readers.remove(at: index).wasReadForEscalation
            let (admitted, outranked) = _admit(&state)
            return (pinned, admitted, outranked)
        }

        _depart(pinned: pinned, admitting: admitted, outranked: outranked)
    }

    /// Gives up the write hold, and serves whoever that lets in.
    ///
    @usableFromInline
    package func _writeUnlock() {
        let (pinned, admitted, outranked) = state.withLock { state in
            guard let writer = state.writer else {
                preconditionFailure("AsyncRWLock write-unlocked while not write-locked")
            }
            state.writer = nil
            let (admitted, outranked) = _admit(&state)
            return (writer.wasReadForEscalation, admitted, outranked)
        }

        _depart(pinned: pinned, admitting: admitted, outranked: outranked)
    }

    /// Serves the head of the queue for as long as the lock's mode permits
    /// it, recording each admitted waiter as a holder, and returns what
    /// resumes them, for the caller to resume once it has let go of the
    /// state lock — along with whether the holders left are outranked by
    /// the queue left behind them, decided here rather than in a critical
    /// section of its own.
    ///
    /// The handoff records the holder while the lock is still held, so a
    /// newcomer cannot slip in between a release and the waiter's
    /// resumption, and the waiter never has to contend again.
    private func _admit(
        _ state: inout _State
    ) -> (admitted: [_Grant], outranked: Bool) {
        var admitted: [_Grant] = []
        while true {
            // Asked of a snapshot: the queue is mutated by the call that asks,
            // and the closure must not touch the state it is part of.
            let permitsReading = state._permits(.read)
            let permitsWriting = state._permits(.write)
            guard let waiter = state.queue.removeNext(where: { waiter in
                switch waiter.request {
                case .read:
                    permitsReading
                case .write:
                    permitsWriting
                }
            }) else {
                return (admitted, _needsEscalation(state))
            }
            unsafe state._hold(waiter.request, task: waiter.task, priority: waiter.priority)
            admitted.append(waiter.grant())
        }
    }

    /// The tail of a release, once the state has been updated and the lock
    /// let go of: resumes the tasks the release let in, then does what
    /// escalation asks of a departure — `_departHolder` says what, on the
    /// two facts the critical section established.
    private func _depart(pinned: Bool, admitting admitted: [_Grant], outranked: Bool) {
        for grant in admitted {
            grant.complete()
        }

        if #available(anyAppleOS 26.0, *) {
            _departHolder(pinned: pinned, outranked: outranked)
        }
    }
}

// MARK: - Priority escalation

extension _AsyncRWLockHandle {
    /// Every holder is raised, readers included: what a waiter waits for is
    /// the departure of whoever holds the lock, and by the premise of a
    /// reader-writer lock — reads frequent, writes rare — that is usually a
    /// set of readers. A queued writer is not a holder and is not raised: a
    /// reader that outranks it is served before it rather than after, so no
    /// waiter is ever waiting on it.
    package func _nextEscalation(_ state: inout _State) -> (UnsafeCurrentTask, TaskPriority)? {
        guard let priority = state.queue.highestPriority else {
            return nil
        }

        if var writer = state.writer {
            let task = unsafe writer._raise(to: priority)
            state.writer = writer
            if let task = unsafe task {
                return unsafe (task, priority)
            }
        }

        for index in state.readers.indices {
            if let task = unsafe state.readers[index]._raise(to: priority) {
                return unsafe (task, priority)
            }
        }

        return nil
    }

    package func _needsEscalation(_ state: _State) -> Bool {
        guard let priority = state.queue.highestPriority else {
            return false
        }
        if let writer = state.writer, writer._isBelow(priority) {
            return true
        }
        return state.readers.contains { $0._isBelow(priority) }
    }
}
