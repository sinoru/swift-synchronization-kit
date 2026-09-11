# SynchronizationKit

[![GitHub Actions — Swift](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/swift.yml/badge.svg)](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/swift.yml)
[![GitHub Actions — Apple Platforms](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/apple-platforms.yml/badge.svg)](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/apple-platforms.yml)

[![Swift Package Index — Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsinoru%2Fswift-synchronization-kit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/sinoru/swift-synchronization-kit)
[![Swift Package Index — Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsinoru%2Fswift-synchronization-kit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/sinoru/swift-synchronization-kit)

**SynchronizationKit** provides synchronization primitives for Swift: the
standard library's `Mutex` and `Atomic` back-deployed to OS versions that
predate the `Synchronization` module, and five primitives the standard
library does not provide — a writer-preferring `RWLock`, a `Semaphore` that
needs no Dispatch, and an `AsyncMutex`, an `AsyncRWLock`, and an
`AsyncSemaphore` that suspend the task waiting on them instead of blocking its
thread.

The [API documentation](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkit)
is hosted on the Swift Package Index.

## Table of Contents

* [Getting Started](#getting-started)
* [Provided Primitives](#provided-primitives)
* [Performance](#performance)
* [Platform Support](#platform-support)
* [Contributing](#contributing)
* [License](#license)

## Getting Started

Add the package to your `Package.swift`, and `SynchronizationKit` to the
target that uses it:

```swift
dependencies: [
    .package(
        url: "https://github.com/sinoru/swift-synchronization-kit.git",
        from: "1.0.0"
    ),
]
```

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "SynchronizationKit", package: "swift-synchronization-kit"),
    ]
),
```

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

Every primitive owns the value it protects: the value is reachable only from
inside the locking methods, so there is no way to touch it without holding the
lock. All of them store their value inline and are safe to declare as a `let`
property or a global.

## Provided Primitives

Each primitive lives in its own target behind a
[package trait](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)
of the same name, all enabled by default. Two aggregate traits select a whole
family at once: `Sync` enables `Atomic`, `Mutex`, `RWLock`, and `Semaphore`,
and `Async` enables `AsyncMutex`, `AsyncRWLock`, and `AsyncSemaphore`. The
`SynchronizationKit` umbrella module re-exports whichever ones are enabled. To
pull in only the primitives you need, enable their traits explicitly:

```swift
.package(
    url: "https://github.com/sinoru/swift-synchronization-kit.git",
    from: "1.0.0",
    traits: ["Mutex"]
),
```

A trait decides what the umbrella module re-exports, and `Mutex` and `Atomic`
also shrink what gets built. `RWLock` builds `Atomic`, `Mutex`, and
`Semaphore` either way, since its backend is made of them.

| Primitive | Use it for | Documentation |
| --- | --- | --- |
| `Mutex` | A value touched from synchronous code. Exclusive access through `withLock`; backed by `os_unfair_lock` on Darwin. | [SynchronizationKitMutex](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitmutex) |
| `Atomic` | A single machine word — a counter, a flag, a pointer — or any type that adopts `AtomicRepresentable`. Lock-free, with explicit memory orderings. | [SynchronizationKitAtomic](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitatomic) |
| `RWLock` | A value read far more often than it is written, when the read closure does enough work for concurrency to pay. Any number of readers or one writer; writer-preferring. | [SynchronizationKitRWLock](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitrwlock) |
| `Semaphore` | A count rather than a value, from threads — a pool of slots, a hand-off between threads. `DispatchSemaphore` without Dispatch, stored inline. | [SynchronizationKitSemaphore](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitsemaphore) |
| `AsyncMutex` | A critical section that must span an `await`, or one that must run on the caller's own actor — what an actor cannot express. Suspends the task instead of blocking its thread, and has a synchronous form that blocks one where no task is running, so a thread and a task can take turns on one value. | [SynchronizationKitAsyncMutex](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncmutex) |
| `AsyncRWLock` | `RWLock` for Swift Concurrency: read sections that may span an `await` and run alongside each other, or one write section. Writer-preferring, with synchronous forms for a thread as `AsyncMutex` has. | [SynchronizationKitAsyncRWLock](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncrwlock) |
| `AsyncSemaphore` | The same count, from tasks — or from a thread that has none. `Semaphore` for Swift Concurrency: `wait()` suspends the task instead of blocking its thread, and has a synchronous form that blocks one where no task is running. | [SynchronizationKitAsyncSemaphore](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncsemaphore) |

Prefer `Mutex` over `RWLock` unless reads are frequent, writes are rare, *and*
the read section is long enough for parallel reading to pay for tracking
readers; [Performance](#performance) puts a number on where that falls.
Prefer an `actor` over `AsyncMutex` wherever one fits: actors are reentrant at
every `await`, which is what makes them immune to deadlock, and `AsyncMutex`
gives that up on purpose. Prefer `AsyncMutex` over `AsyncRWLock` on the same
terms as `Mutex` over `RWLock`. A `Mutex` must not be held across an `await`;
the asynchronous primitives are for the section that must be.

Waiting, cancellation, and priority semantics for the asynchronous primitives
are documented on the types themselves.

## Performance

Measured on an Apple M4 Pro, macOS 26.6.2, Swift 6.3.3, at commit `6d7a105`,
by the performance suites described under
[Running the tests](#running-the-tests); contended cases run twelve threads.
The package is built with `-enable-testing` for these suites, a cost the
standard library's and Dispatch's precompiled code does not pay, so read its
figures as conservative — and all of them as a comparison within one run on
one machine.

| | This package (ns/op) | Alternative (ns/op) |
| --- | --- | --- |
| `Mutex`, uncontended / contended | 1.7 / 7.7 | Standard library `Mutex`: 1.7 / 8.3 |
| `Semaphore`, uncontended / contended handoff | 5.4 / 740 | `DispatchSemaphore`: 4.1 / 1,860 |
| `RWLock`, uncontended read | 3.3 | `pthread_rwlock_t`: 5.5 · concurrent `DispatchQueue`: 160 |
| `AsyncMutex`, uncontended / handoff | 700 / 2,600 | `actor`: 390 / 440 |
| `AsyncSemaphore`, uncontended / handoff | 390 / 2,000 | |

A turn of the asynchronous primitives is a take, a `Task.yield()`, and a
release; a handoff resumes the next waiter across threads of the cooperative
pool, and costs the same at 8, 64, and 512 waiters. The actor is cheaper on
every count because it cannot hold across the yield. What `AsyncMutex` buys is
holding across an `await`, and this is its price.

`RWLock` against the alternatives on a read-mostly mix — twelve threads,
each writing once in a hundred turns — as the critical section grows, in
nanoseconds per turn:

| Critical section | `RWLock` | `Mutex` | `pthread_rwlock_t` | `DispatchQueue` + barrier |
| --- | --- | --- | --- | --- |
| ~1 ns | 74 | 10 | 490 | 1,560 |
| ~70 ns | 260 | 126 | 710 | 1,630 |
| ~300 ns | 324 | 445 | 673 | 1,730 |
| ~1.1 µs | 365 | 1,500 | 592 | 1,730 |

Below a few hundred nanoseconds a `Mutex` wins, since tracking readers bounces
a cache line between cores on every read; at a microsecond `RWLock` takes a
quarter of the mutex's time. `pthread_rwlock_t` and a barrier queue enter the
kernel on nearly every contended operation, however short the section.

## Platform Support

The package supports macOS 12, iOS 15, tvOS 15, watchOS 8, and visionOS 1 or
later, along with every platform the Swift toolchain targets. `Semaphore` and
`RWLock` select their backends per platform:

| Platform | `Atomic` / `Mutex` | `Semaphore` backend | `RWLock` backend |
| --- | --- | --- | --- |
| Apple platforms | Back-deployed implementation | Atomic word waited on by address; a Mach semaphore below macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, visionOS 1.1 | Atomics, a `Mutex`, and two `Semaphore`s |
| Linux (glibc), Android | Standard library type, re-exported | Unnamed POSIX semaphore | `pthread_rwlock_t`, configured writer-preferring |
| Linux (musl), WASI | Standard library type, re-exported | Unnamed POSIX semaphore | Atomics, a `Mutex`, and two `Semaphore`s |
| Windows | Standard library type, re-exported | Kernel semaphore object, created on first use | Atomics, a `Mutex`, and two `Semaphore`s |
| Others (embedded) | Standard library type, re-exported — this package's own implementation where `Synchronization` is absent | Not available: nothing to block a thread on | Exclusive-mutex fallback — correct, but without reader parallelism |

The fast paths — `Atomic`'s operations, and the atomic operation or two that
take or release a `Semaphore` or `RWLock` when nobody has to sleep or be woken
— inline into the client, so they are compiled for the client's deployment
target rather than the package's minimum. On arm64 that decides whether an
atomic operation is one instruction or a load-exclusive/store-exclusive loop;
a deployment target whose devices all have the instructions, or `-target-cpu
apple-a12` or later, gets the single instruction. One caveat: Xcode 26 with
compilation caching enabled compiles those atomics for the SDK's CPU instead,
and the result traps on a device without the instructions
([swiftlang/swift#90380](https://github.com/swiftlang/swift/issues/90380));
Swift 6.4 corrects this.

Building the package requires Swift 6.3 or later.

### Running the tests

`swift test` needs no arguments and takes no environment variables. Nothing
selects a backend: `Semaphore` and `RWLock` use the one their OS provides, so
the Mach semaphore path is exercised only on a simulator runtime older than
the versions in the table above, which the Apple Platforms workflow pins one
of for that reason.

A debug build skips the measurements, since an unoptimized one says nothing.
There is one performance suite per primitive, each measured beside what a
client would otherwise write: `Mutex` beside the standard library's,
`Semaphore` beside `DispatchSemaphore`, `RWLock` beside `pthread_rwlock_t`, a
concurrent `DispatchQueue`, and `Mutex`, and `AsyncMutex` beside an `actor`.
Read the numbers; nothing there fails on a regression.

```sh
swift test -c release -Xswiftc -enable-testing --filter PerformanceTests
```

Every primitive also has a stress suite. A plain run takes it at a size that
does not slow a local run; the flag below turns the repetition up fiftyfold,
which is how CI runs it on every push.

```sh
swift test -c release -Xswiftc -enable-testing \
    -Xswiftc -DSYNCHRONIZATIONKIT_LONG_TESTS --filter StressTests
```

CI builds and tests in release throughout, since a lock's bugs are the ones
the optimizer creates. ThreadSanitizer is clean on every backend; where it
needs an annotation to be, `CSynchronizationKitCore.h` says why.

## Contributing

Bug reports, feature ideas, and pull requests are welcome on
[GitHub](https://github.com/sinoru/swift-synchronization-kit).

## License

[Apache License 2.0](LICENSE)
