# ``SynchronizationKitSemaphore``

A counting semaphore that blocks the calling thread while it waits for a
signal, with no Dispatch behind it.

## Overview

``Semaphore`` is `DispatchSemaphore` without Dispatch: `wait()` decrements the
count and blocks while it is zero, and `signal()` increments it and wakes a
waiting thread if there is one. What it leaves behind is the library. A
program that uses threads but not Swift Concurrency links no Dispatch on Linux
with this, where `DispatchSemaphore` would bring `libdispatch` and its runtime
in for one type; and where there is no Dispatch at all, this is the semaphore
there is.

```swift
final class WorkerPool {
    private let slots = Semaphore(value: 4)

    func run(_ job: Job) {
        slots.wait()
        defer { slots.signal() }
        job.perform()
    }
}
```

A semaphore is a count, not a lock: the thread that signals need not be the
one that waited, which suits handing work between threads or bounding how many
run at once. To protect a value, use `Mutex`, which owns the value and releases
it from the thread that took it.

`wait()` blocks a thread, and is therefore unavailable from asynchronous
contexts, as `DispatchSemaphore.wait()` is. Tasks wait on `AsyncSemaphore`,
which suspends them instead.

The semaphore is stored inline, so it can be a `let` on a class or a global
with no allocation of its own. On Darwin it is one atomic word that threads
wait on by address, falling back to a Mach semaphore on releases predating
that call; elsewhere it is the platform's own semaphore. ``Semaphore``
documents which backend applies where, and the one thing to know about its
name: the platform overlays declare a `Semaphore` of their own, so a file that
imports `Foundation` names this one through its module in type position.

## Topics

### Semaphores

- ``Semaphore``
