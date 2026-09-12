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
acquiring the lock, so writers cannot starve. Reading is cheap however many
threads read at once — a reader touches nothing another reader touches — and
writing is what pays for that, so prefer `Mutex` unless reads outnumber
writes.

Unlike `Mutex` and `Atomic`, this type has no standard-library counterpart to
defer to, so it is a real implementation on every platform at every deployment
target. The backend is chosen per platform; ``RWLock`` documents which one
applies where.

On Apple platforms the lock reads `mach_absolute_time`, and the privacy
manifest that App Store submission requires for it rides along as the one
resource of a target that only builds for Apple platforms depend on; an app
that links the package gets the manifest, and a resource bundle for that
target, without further steps.

## Topics

### Locks

- ``RWLock``
