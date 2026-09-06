# ``SynchronizationKitRWLock``

A writer-preferring reader-writer lock that owns the value it protects.

## Overview

``RWLock`` admits any number of concurrent readers, or exactly one writer.
Readers receive the value by borrow and cannot mutate it; a writer receives it
`inout` with the same exclusive access `Mutex.withLock` grants.
`withReadLockIfAvailable` and `withWriteLockIfAvailable` are the non-blocking
variants.

```swift
final class ResourceCache: Sendable {
    private let entries = RWLock<[Key: Resource]>([:])

    func resource(for key: Key) -> Resource? {
        entries.withReadLock { $0[key] }
    }

    func store(_ resource: Resource, for key: Key) {
        entries.withWriteLock { $0[key] = resource }
    }
}
```

The lock is writer-preferring: a blocked writer stops new readers from
acquiring the lock, so writers cannot starve. Prefer `Mutex` unless reads are
frequent, writes are rare, *and* the read closure does enough work for
concurrency to pay.

Unlike `Mutex` and `Atomic`, this type has no standard-library counterpart to
defer to, so it is a real implementation on every platform at every deployment
target. The backend is chosen per platform; ``RWLock`` documents which one
applies where.

## Topics

### Locks

- ``RWLock``
