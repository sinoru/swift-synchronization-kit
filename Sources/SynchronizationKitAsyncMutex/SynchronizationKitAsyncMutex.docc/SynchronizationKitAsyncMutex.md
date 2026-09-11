# ``SynchronizationKitAsyncMutex``

A lock for Swift Concurrency that suspends the calling task, rather than
blocking its thread, while another task holds it.

## Overview

``AsyncMutex`` owns the value it protects, like `Mutex`, but its `withLock`
closure is `async`: the lock is held by a task rather than by a thread, so it
may be held across an `await`, which `Mutex` forbids because a task may resume
on a different thread from the one it suspended on.

```swift
final class ImageCache: Sendable {
    private let entries = AsyncMutex<[URL: Image]>([:])

    func image(at url: URL) async throws -> Image {
        try await entries.withLock { entries in
            if let image = entries[url] { return image }
            let image = try await download(url)
            entries[url] = image
            return image
        }
    }
}
```

Reach for an `actor` first: actors are reentrant at every `await`, which is
what makes them immune to deadlock, and this lock gives that up on purpose. It
is for what an actor cannot express — a critical section that must span an
`await`, like the cache above, which must not fetch the same key twice, or one
that must run on the caller's own actor. `withLock` also has a synchronous
form that blocks a thread where no task is running, so a thread and a task can
take turns on one value.

Waiters are served in priority order and in arrival order among equals, a
released lock is handed straight to the next waiter, and a task cancelled while
waiting throws `CancellationError` without running the closure. ``AsyncMutex``
documents the full policy, including where the OS escalates the holder's
priority.

## Topics

### Locks

- ``AsyncMutex``
