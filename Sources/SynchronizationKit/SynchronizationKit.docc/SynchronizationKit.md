# ``SynchronizationKit``

Synchronization primitives for Swift: the standard library's `Mutex` and
`Atomic` back-deployed to OS versions that predate the `Synchronization`
module, and five the standard library does not provide — a writer-preferring
`RWLock`, a `Semaphore` that needs no Dispatch, and an `AsyncMutex`, an
`AsyncRWLock`, and an `AsyncSemaphore` that suspend the task waiting on them
instead of blocking its thread.

## Overview

Every primitive owns the value it protects: the value is reachable only from
inside the locking methods, so there is no way to touch it without holding the
lock. All of them store their value inline — no heap allocation, no separate
box — and are safe to declare as a `let` property or a global.

```swift
import SynchronizationKit

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

`SynchronizationKit` is an umbrella module: it declares nothing of its own and
re-exports one module per primitive. Importing it is all a client needs to do;
the modules below are where the types are documented.

### Modules

- [**SynchronizationKitMutex**](./synchronizationkitmutex) — `Mutex`, a lock
  that owns the value it protects and grants exclusive access through
  `withLock`. On Darwin it is backed by `os_unfair_lock`, matching the standard
  library's implementation down to the primitive.
- [**SynchronizationKitAtomic**](./synchronizationkitatomic) — `Atomic`,
  lock-free storage for booleans, integers, pointers, and any type that adopts
  `AtomicRepresentable`, with explicit memory orderings.
- [**SynchronizationKitRWLock**](./synchronizationkitrwlock) — `RWLock`, a
  reader-writer lock that admits any number of concurrent readers or exactly
  one writer, and prefers writers so they cannot starve.
- [**SynchronizationKitSemaphore**](./synchronizationkitsemaphore) —
  `Semaphore`, `DispatchSemaphore` without Dispatch: a counting semaphore that
  blocks the thread, stored inline, on every platform with threads.
- [**SynchronizationKitAsyncMutex**](./synchronizationkitasyncmutex) —
  `AsyncMutex`, a lock for Swift Concurrency whose `withLock` closure is
  `async`, so it may be held across an `await`.
- [**SynchronizationKitAsyncRWLock**](./synchronizationkitasyncrwlock) —
  `AsyncRWLock`, `RWLock` restated for Swift Concurrency: readers that run
  alongside each other, or one writer, each holding the lock across an
  `await`.
- [**SynchronizationKitAsyncSemaphore**](./synchronizationkitasyncsemaphore) —
  `AsyncSemaphore`, `Semaphore` restated for Swift Concurrency: `wait()`
  suspends the task rather than blocking its thread.

### Choosing a Primitive

Start from how the protected value is used, not from which primitive is
newest.

- **A value touched from synchronous code** wants a `Mutex`. It is the
  cheapest lock here, and the one the standard library will eventually replace
  it with.
- **A single machine word** — a counter, a flag, a pointer — wants an `Atomic`
  instead of a lock. If the type does not fit in a word, it is not a candidate:
  guard it with a `Mutex`.
- **A value read more often than it is written** may want an `RWLock`. A
  reader touches nothing another reader touches, so reading stays cheap
  however many threads read at once, and it is the writer that pays for that:
  a write costs more than a `Mutex`'s exclusive take, so a value written as
  often as it is read is better behind a `Mutex`.
- **A value touched from tasks** wants an `actor` first. Actors are reentrant
  at every `await`, which is what makes them immune to deadlock. Reach for an
  `AsyncMutex` only for what an actor handles badly: a critical section that
  must span an `await`, such as a cache that must not fetch the same key
  twice. `AsyncRWLock` stands to `AsyncMutex` as `RWLock` does to `Mutex`:
  for read sections frequent, long, and concurrent enough to pay for the
  bookkeeping of tracking each reader.
- **A count rather than a value** — a pool of slots, a hand-off between
  threads or tasks — wants a semaphore: `Semaphore` from threads,
  `AsyncSemaphore` from tasks. The one that signals need not be the one that
  waited, which is what a lock forbids and a semaphore is for.

A `Mutex` must not be held across an `await`, because a task may resume on a
different thread from the one it suspended on. The asynchronous primitives
are the bridge the other way: each has a synchronous form that blocks a
thread where no task is running, so a thread and a task can wait on one
`AsyncSemaphore` count, or take turns on the value an `AsyncMutex` or
`AsyncRWLock` guards — the task holding across an `await` while the thread
waits its turn.

### Package Traits

Each primitive lives in its own target behind a
[package trait](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)
of the same name, all enabled by default. Two aggregate traits select a whole
family at once: `Sync` enables `Atomic`, `Mutex`, `RWLock`, and `Semaphore`,
and `Async` enables `AsyncMutex`, `AsyncRWLock`, and `AsyncSemaphore`. The
umbrella module re-exports whichever ones are enabled.

```swift
.package(
    url: "https://github.com/sinoru/swift-synchronization-kit.git",
    from: "1.0.1",
    traits: ["Mutex"]
),
```

A trait decides what the umbrella re-exports. `Mutex` and `Atomic` also
shrink what gets built — `Mutex` alone pulls in no C target. `RWLock` builds
the others either way: its backend takes a mutex for writer exclusion,
atomics for the table readers publish themselves in, and two semaphores for
the handoff between them.

Where one file needs both this package's `Mutex` and the standard library's
at once, a module selector disambiguates:
`SynchronizationKit::Mutex` versus `Synchronization::Mutex`.

### Additional Resources

- [SynchronizationKit on GitHub](https://github.com/sinoru/swift-synchronization-kit)
- [Changelog](https://github.com/sinoru/swift-synchronization-kit/blob/main/CHANGELOG.md)
