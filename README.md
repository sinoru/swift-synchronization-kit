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
* [Designed to Be Replaced](#designed-to-be-replaced)
* [Platform Support](#platform-support)
* [Using SynchronizationKit in Your Project](#using-synchronizationkit-in-your-project)
* [Contributing](#contributing)
* [License](#license)

## Getting Started

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
lock. All of them store their value inline — no heap allocation, no separate
box — and are safe to declare as a `let` property or a global. (`AsyncMutex`
and `AsyncRWLock` allocate once, for the queue their waiters share; the value
is still inline. The two semaphores guard a count rather than a value:
`Semaphore` is inline, `AsyncSemaphore` a class.)

## Provided Primitives

Each primitive lives in its own target behind a
[package trait](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)
of the same name, all enabled by default. Two aggregate traits select a whole
family at once: `Sync` enables `Atomic`, `Mutex`, `RWLock`, and `Semaphore`,
and `Async` enables `AsyncMutex`, `AsyncRWLock`, and `AsyncSemaphore`. The
`SynchronizationKit` umbrella module re-exports whichever ones are enabled.

| Primitive | Use it for | Documentation |
| --- | --- | --- |
| `Mutex` | A value touched from synchronous code. Exclusive access through `withLock`; backed by `os_unfair_lock` on Darwin. | [SynchronizationKitMutex](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitmutex) |
| `Atomic` | A single machine word — a counter, a flag, a pointer — or any type that adopts `AtomicRepresentable`. Lock-free, with explicit memory orderings. | [SynchronizationKitAtomic](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitatomic) |
| `RWLock` | A value read far more often than it is written, when the read closure does enough work for concurrency to pay. Any number of readers or one writer; writer-preferring. | [SynchronizationKitRWLock](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitrwlock) |
| `Semaphore` | A count rather than a value, from threads — a pool of slots, a hand-off between threads. `DispatchSemaphore` without Dispatch, stored inline. | [SynchronizationKitSemaphore](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitsemaphore) |
| `AsyncMutex` | A critical section that must span an `await`, which an actor cannot express. Suspends the task instead of blocking its thread. | [SynchronizationKitAsyncMutex](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncmutex) |
| `AsyncRWLock` | `RWLock` for Swift Concurrency: read sections that may span an `await` and run alongside each other, or one write section. Writer-preferring. | [SynchronizationKitAsyncRWLock](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncrwlock) |
| `AsyncSemaphore` | The same count, from tasks. `Semaphore` for Swift Concurrency: `wait()` suspends the task instead of blocking its thread. | [SynchronizationKitAsyncSemaphore](https://swiftpackageindex.com/sinoru/swift-synchronization-kit/documentation/synchronizationkitasyncsemaphore) |

Prefer `Mutex` over `RWLock` unless reads are frequent, writes are rare, *and*
the read section is long enough for parallel reading to outweigh the cost of
tracking readers. Prefer an `actor` over `AsyncMutex` whenever one fits:
actors are reentrant at every `await`, which is what makes them immune to
deadlock, and `AsyncMutex` gives that up on purpose; and prefer `AsyncMutex`
over `AsyncRWLock` on the same terms as `Mutex` over `RWLock`. The synchronous
locks and the asynchronous ones do not mix — a `Mutex` must not be held across
an `await`, and an `AsyncMutex` cannot be taken from synchronous code.

Waiting, cancellation, and priority semantics for the asynchronous primitives,
and the backend each platform gets for `RWLock` and `Semaphore`, are
documented on the types themselves. One note on `Semaphore`'s name: the
platform overlays declare a `Semaphore` of their own, the pointer type
`sem_open` returns, and `Foundation` re-exports it. A file that imports
neither sees only this package's; one that does names this one through its
module — `SynchronizationKit::Semaphore` — where a type is named, though
calls such as `Semaphore(value: 4)` need nothing.

## Designed to Be Replaced

`Mutex` and `Atomic` intentionally match the standard library's names and
APIs. Once your deployment target reaches the OS versions that ship
`Synchronization` (macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2), this
package starts emitting deprecation warnings — the signal that migrating is a
matter of changing an import. `RWLock`, `Semaphore`, `AsyncMutex`,
`AsyncRWLock`, and `AsyncSemaphore` have no standard-library counterpart and
stay useful past that point.

On non-Apple platforms the Swift runtime is bundled with the application, so
`Synchronization` is always available regardless of OS version; there, `Mutex`
and `Atomic` are the standard library's own, re-exported. Importing this
package's module is enough to call their methods — `Synchronization` itself
never has to appear in your imports, exactly as on Apple platforms.

## Platform Support

The package supports macOS 12, iOS 15, tvOS 15, watchOS 8, and visionOS 1 or
later, along with every platform the Swift toolchain targets. `Semaphore` and
`RWLock` select their backends per platform:

| Platform | `Atomic` / `Mutex` | `Semaphore` backend | `RWLock` backend |
| --- | --- | --- | --- |
| Apple platforms | Back-deployed implementation | One atomic word, waited on by address — a Mach semaphore below macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, visionOS 1.1 | Atomic reader counting, a `Mutex` for writers, and two `Semaphore`s for sleep/wake |
| Linux (glibc), Android | Standard library type, re-exported | Unnamed POSIX semaphore | `pthread_rwlock_t`, configured writer-preferring |
| Linux (musl), WASI | Standard library type, re-exported | Unnamed POSIX semaphore | Atomic reader counting, a `Mutex` for writers, and two `Semaphore`s for sleep/wake |
| Windows | Standard library type, re-exported | Kernel semaphore object, created on first use | Atomic reader counting, a `Mutex` for writers, and two `Semaphore`s for sleep/wake |
| Others (embedded) | Standard library type, re-exported — this package's own implementation where `Synchronization` is absent | Not available: nothing to block a thread on | Exclusive-mutex fallback — correct, but without reader parallelism |

Building the package requires Swift 6.3 or later.

### Running the tests

`swift test` needs no arguments and takes no environment variables. Nothing
selects a backend: `Semaphore` and `RWLock` use the one their OS provides, so
what a run covers is what that OS would ship. Running the suite on a simulator runtime older than
the versions in the table above is therefore the only way to exercise the Mach
semaphore path, and the Apple Platforms workflow pins one runtime that old for
exactly that.

The one thing a plain run leaves out is the measurements, which a debug build
skips because an unoptimized one says nothing. Read the numbers; nothing there
fails on a regression.

```sh
swift test -c release -Xswiftc -enable-testing --filter RWLockPerformanceTests
```

CI builds and tests in release throughout, so that is where they run. A lock is
a type whose bugs the optimizer is entitled to create — a reordering, a dead
store, an access folded into a register — and none of those appear in a debug
run. Nothing is given up for it: every runtime check here is a `precondition`,
which survives `-O`.

It also runs the suite on one simulator runtime per OS major, back as far as
Apple still publishes one. That is not as far back as the versions in the table
above: iOS 15, tvOS 15 and watchOS 8 runtimes are no longer served, so the
oldest each platform is actually exercised on is iOS 16.4, tvOS 16.4,
watchOS 9.4 and visionOS 1.2. Support for the releases below those rests on
compiling for them, not on running there.

ThreadSanitizer is clean on both backends. The Mach semaphore one needs help to
be: a woken thread takes no atomic on its way out of the wait, so the ordering
is the semaphore's alone and the sanitizer does not model those calls. The lock
tells it about that edge where it makes it, which matters most for somebody
running their own app under the sanitizer with a deployment target old enough to
take that backend. The note on `MutualExclusionTests` records how it was pinned
down.

## Using SynchronizationKit in Your Project

To use this package in a SwiftPM project, add the following to your
`Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/sinoru/swift-synchronization-kit.git",
        "0.0.4"..<"0.1.0"
    ),
]
```

Then add `SynchronizationKit` as a dependency of your target:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "SynchronizationKit", package: "swift-synchronization-kit"),
    ]
),
```

To pull in only the primitives you need, enable their traits explicitly:

```swift
.package(
    url: "https://github.com/sinoru/swift-synchronization-kit.git",
    "0.0.4"..<"0.1.0",
    traits: ["Mutex"]
),
```

A trait decides what the umbrella module re-exports. `Mutex` and `Atomic` also
shrink what gets built — `Mutex` alone pulls in no C target. `RWLock` builds all
three either way: its backend takes a mutex for writer exclusion and an atomic
counter for readers.

## Contributing

Bug reports, feature ideas, and pull requests are welcome on
[GitHub](https://github.com/sinoru/swift-synchronization-kit).

## License

[Apache License 2.0](LICENSE)
