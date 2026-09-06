# ``SynchronizationKitAsyncSemaphore``

A counting semaphore for Swift Concurrency that suspends the calling task,
rather than blocking its thread, while it waits for a signal.

## Overview

``AsyncSemaphore`` is `DispatchSemaphore` restated for tasks: `wait()`
decrements the count and suspends while it is zero, and `signal()` increments
it and resumes a waiting task if there is one. `DispatchSemaphore.wait()`
itself is unavailable from asynchronous contexts, and this is what to reach for
in its place.

```swift
final class Downloader: Sendable {
    private let slots = AsyncSemaphore(value: 4)

    func download(_ url: URL) async throws -> Data {
        try await slots.wait()
        defer { slots.signal() }
        return try await fetch(url)
    }
}
```

A semaphore is a count, not a lock: the task that signals need not be the one
that waited, which suits handing work between tasks or bounding how many run at
once. To protect a value, use `AsyncMutex`, which owns the value and knows who
holds it.

Waiters are served in priority order and in arrival order among equals, a
signal is handed straight to the next waiter, and a task cancelled while
waiting throws `CancellationError` and leaves the count untouched. There is no
`wait(timeout:)`, for the reason `Task.sleep` has none: a deadline in Swift
Concurrency is a task that gets cancelled, and `wait()` is cancellable.

## Topics

### Semaphores

- ``AsyncSemaphore``
