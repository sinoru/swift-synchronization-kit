# ``SynchronizationKitAsyncRWLock``

A writer-preferring reader-writer lock for Swift Concurrency that suspends
the calling task, rather than blocking its thread, while it waits.

## Overview

``AsyncRWLock`` owns the value it protects, like `RWLock`, and admits any
number of concurrent readers or exactly one writer. Its closures are `async`:
the lock is held by a task rather than by a thread, so it may be held across an
`await`, which `RWLock` forbids because a task may resume on a different thread
from the one it suspended on. Readers receive the value by borrow and cannot
mutate it; a writer receives it `inout`. `withReadLockIfAvailable` and
`withWriteLockIfAvailable` are the variants that never suspend to acquire, and
every locking method has a synchronous form that blocks a thread where no task
is running, as `AsyncMutex`'s does.

```swift
final class ResourceCache: Sendable {
    private let entries = AsyncRWLock<[Key: Resource]>([:])

    func resource(for key: Key) async throws -> Resource? {
        try await entries.withReadLock { $0[key] }
    }

    func store(_ resource: Resource, for key: Key) async throws {
        try await entries.withWriteLock { $0[key] = resource }
    }
}
```

Reach for an `actor` first, for the reason `AsyncMutex` gives, and for
`AsyncMutex` next: this lock pays for tracking its readers, and only a read
section that does enough work — that waits on enough — earns it back.

Waiters are served in priority order and in arrival order among equals, a
waiting writer stops new readers from taking the lock, a departing holder hands
the lock straight to whoever the queue permits next, and a task cancelled while
waiting throws `CancellationError` without running the closure. ``AsyncRWLock``
documents the full policy, including where the OS escalates the holders'
priority.

## Topics

### Locks

- ``AsyncRWLock``
