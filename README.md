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
        from: "1.1.2"
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
    from: "1.1.2",
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
| `RWLock` | A value read more often than it is written. Any number of readers or one writer; writer-preferring. Readers touch nothing in common, so reading stays cheap however many threads read at once, and writing is what pays for that. | [SynchronizationKitRWLock](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitrwlock) |
| `Semaphore` | A count rather than a value, from threads — a pool of slots, a hand-off between threads. `DispatchSemaphore` without Dispatch, stored inline. | [SynchronizationKitSemaphore](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitsemaphore) |
| `AsyncMutex` | A critical section that must span an `await`, or one that must run on the caller's own actor — what an actor cannot express. Suspends the task instead of blocking its thread, and has a synchronous form that blocks one where no task is running, so a thread and a task can take turns on one value. | [SynchronizationKitAsyncMutex](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncmutex) |
| `AsyncRWLock` | `RWLock` for Swift Concurrency: read sections that may span an `await` and run alongside each other, or one write section. Writer-preferring, with synchronous forms for a thread as `AsyncMutex` has. | [SynchronizationKitAsyncRWLock](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncrwlock) |
| `AsyncSemaphore` | The same count, from tasks — or from a thread that has none. `Semaphore` for Swift Concurrency: `wait()` suspends the task instead of blocking its thread, and has a synchronous form that blocks one where no task is running. | [SynchronizationKitAsyncSemaphore](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncsemaphore) |

Choose between `Mutex` and `RWLock` by what the readers do. Where several
threads read at once and a read does some work — a lookup, a comparison —
`RWLock` is ahead, and further ahead the longer the read. Where the section
is a load or a store, or writes come as often as reads, `Mutex` is: a write
costs more than an exclusive take, and so does a read nobody contends.
[Performance](#performance) puts numbers on each.
Prefer an `actor` over `AsyncMutex` wherever one fits: actors are reentrant at
every `await`, which is what makes them immune to deadlock, and `AsyncMutex`
gives that up on purpose. Prefer `AsyncMutex` over `AsyncRWLock` on the same
terms as `Mutex` over `RWLock`. A `Mutex` must not be held across an `await`;
the asynchronous primitives are for the section that must be.

Waiting, cancellation, and priority semantics for the asynchronous primitives
are documented on the types themselves.

## Performance

Measured on an Apple M4 Pro, macOS 26.6.2, Swift 6.4, at v1.1.2, by the
performance suites described under [Running the tests](#running-the-tests),
built as the library ships; contended cases run twelve threads. Each figure
is the mean of seven runs; read them as a comparison on one machine.

| | This package (ns/op) | Alternative (ns/op) |
| --- | --- | --- |
| `Mutex`, uncontended / contended | 1.7 / 8.0 | Standard library `Mutex`: 1.7 / 7.8 |
| `Semaphore`, uncontended / contended handoff | 3.4 / 702 | `DispatchSemaphore`: 3.4 / 1,720 |
| `RWLock`, uncontended read / write | 3.0 / 5.4 | `pthread_rwlock_t`: 5.5 / 5.5 · concurrent `DispatchQueue`: 162 / 162 |
| `RWLock`, read across twelve threads | 4.4 | `pthread_rwlock_t`: 458 · concurrent `DispatchQueue`: 1,420 · `Mutex`: 8.1 |
| `AsyncMutex`, uncontended / handoff | 603 / 1,920 | `actor`: 369 / 461 |
| `AsyncRWLock`, uncontended read / write / writer handoff | 708 / 598 / 2,070 | |
| `AsyncSemaphore`, uncontended / handoff | 381 / 1,380 | |

A turn of the asynchronous primitives is a take, a `Task.yield()`, and a
release; a handoff resumes the next waiter across threads of the cooperative
pool, and costs the same at 8, 64, and 512 waiters. The actor is cheaper on
every count because it cannot hold across the yield. What `AsyncMutex` buys is
holding across an `await`, and this is its price. `AsyncRWLock`'s writers hand
off as `AsyncMutex` does; with one turn in eight a write and the rest reads, a
turn costs 2,180 ns among 8 tasks and 3,820 among 64.

`RWLock` against the alternatives on a read-mostly mix — twelve threads,
each writing once in a hundred turns — as the critical section grows, in
nanoseconds per turn:

| Critical section | `RWLock` | `Mutex` | `pthread_rwlock_t` | `DispatchQueue` + barrier |
| --- | --- | --- | --- | --- |
| ~1 ns | 37 | 8.9 | 418 | 1,610 |
| ~70 ns | 82 | 125 | 569 | 1,660 |
| ~300 ns | 145 | 426 | 588 | 1,730 |
| ~1.1 µs | 272 | 1,380 | 516 | 1,750 |

Readers touch nothing in common while no writer is about, so twelve threads
reading at once cost each of them less than a `Mutex` would; what they pay
here is the write in every hundred turns, which turns that off for a spell
and is what a `Mutex` still wins at the shortest section. By a few dozen
nanoseconds of reading `RWLock` is ahead, at a few hundred it takes a third
of the mutex's time, and at a microsecond a fifth.
`pthread_rwlock_t` and a barrier queue enter the kernel on nearly every
contended operation, however short the section.

## Platform Support

The package supports macOS 12, iOS 15, tvOS 15, watchOS 8, and visionOS 1 or
later, Linux, Android, WASI, and Windows. `Semaphore` and `RWLock` select
their backends per platform, and a platform the table does not name takes its
last row:

| Platform | `Atomic` / `Mutex` | `Semaphore` backend | `RWLock` backend |
| --- | --- | --- | --- |
| Apple platforms | Back-deployed implementation | Atomic word waited on by address; a Mach semaphore below macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, visionOS 1.1 | Readers published in a shared table; atomics, a `Mutex`, and two `Semaphore`s behind it |
| Linux (glibc), Android | Standard library type, re-exported | Unnamed POSIX semaphore | Readers published in a shared table; `pthread_rwlock_t`, configured writer-preferring, behind it |
| Linux (musl), WASI with threads | Standard library type, re-exported | Unnamed POSIX semaphore | Readers published in a shared table; atomics, a `Mutex`, and two `Semaphore`s behind it |
| Windows | Standard library type, re-exported | Kernel semaphore object, created on first use | Readers published in a shared table; atomics, a `Mutex`, and two `Semaphore`s behind it |
| WASI without threads, others | Standard library type, re-exported | Not available: nothing to block a thread on | Exclusive-mutex fallback — correct, but without reader parallelism |

WASI comes in two flavors, and the target triple decides the row. The
released Swift SDK for WebAssembly builds `wasm32-unknown-wasip1`, where
wasi-libc gives a module one thread and no semaphore, so that is the last
row, and the one the Swift workflow builds and tests through WasmKit. The
`wasm32-unknown-wasip1-threads` triple, available only in development
snapshots of the SDK, takes the musl row; the package builds for it, and
nothing runs it: the runtimes the toolchain ships cannot load a threaded
module, and the standard library's `Mutex` there can lose a wakeup with two
or more threads waiting on it, which `RWLock` builds on. The blocking entry
points of the asynchronous types — `AsyncSemaphore.wait()` and the
synchronous `withLock` family — exist where `Semaphore` does, and not on
the last row.

The fast paths — `Atomic`'s operations, and the atomic operation or two that
take or release a `Semaphore` or `RWLock` when nobody has to sleep or be woken
— inline into the client, so they are compiled for the client's deployment
target rather than the package's minimum. On arm64 that decides whether an
atomic operation is one instruction or a load-exclusive/store-exclusive loop;
a deployment target whose devices all have the instructions, or `-target-cpu
apple-a12` or later, gets the single instruction. One exception: Swift 6.3
with compilation caching enabled compiles those atomics for the SDK's CPU
instead, which would trap on a device without the instructions
([swiftlang/swift#90380](https://github.com/swiftlang/swift/issues/90380)).
A header cannot tell a cached build apart from any other Xcode build of
explicit modules, so under Swift 6.3 every iPhone device build from Xcode
calls out-of-line copies compiled for the package's minimum instead, at one
call per operation. Swift 6.4 corrects the bug, and the atomics inline
again.

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
swift test -c release --disable-testable-imports --filter PerformanceTests
```

Every primitive also has a stress suite. A plain run takes it at a size that
does not slow a local run; the flag below turns the repetition up fiftyfold,
which is how CI runs it on every push.

```sh
swift test -c release --disable-testable-imports \
    -Xswiftc -DSYNCHRONIZATIONKIT_LONG_TESTS --filter StressTests
```

CI runs the unit tests in debug, where `@testable import` reaches the
internals they check, and the stress suites and the measurements in release,
built as the library ships, since a lock's bugs are the ones the optimizer
creates.

## Contributing

Bug reports, feature ideas, and pull requests are welcome on
[GitHub](https://github.com/sinoru/swift-synchronization-kit).

## License

[Apache License 2.0](LICENSE)
