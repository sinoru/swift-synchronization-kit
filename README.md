# Swift Synchronization Kit

[![GitHub Actions — Swift](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/swift.yml/badge.svg)](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/swift.yml)
[![GitHub Actions — Apple Platforms](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/apple-platforms.yml/badge.svg)](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/apple-platforms.yml)

[![Swift Package Index — Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsinoru%2Fswift-synchronization-kit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/sinoru/swift-synchronization-kit)
[![Swift Package Index — Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsinoru%2Fswift-synchronization-kit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/sinoru/swift-synchronization-kit)

**SynchronizationKit** provides synchronization primitives for Swift: the
standard library's `Mutex` and `Atomic` back-deployed to OS versions that
predate the `Synchronization` module, and a writer-preferring `RWLock` that
the standard library does not provide.

## Table of Contents

* [Getting Started](#getting-started)
* [Provided Primitives](#provided-primitives)
* [Designed to Be Replaced](#designed-to-be-replaced)
* [Platform Support](#platform-support)
* [Using Swift Synchronization Kit in Your Project](#using-swift-synchronization-kit-in-your-project)
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
box — and are safe to declare as a `let` property or a global.

## Provided Primitives

Each primitive lives in its own target behind a
[package trait](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0450-swiftpm-package-traits.md)
of the same name, all enabled by default. The `SynchronizationKit` umbrella
module re-exports whichever ones are enabled.

### Mutex

A lock that owns the value it protects, providing exclusive access through
`withLock` and its non-blocking variant `withLockIfAvailable`:

```swift
let counters = Mutex<[String: Int]>([:])

counters.withLock { $0["requests", default: 0] += 1 }
```

On Darwin platforms it is backed by `os_unfair_lock`, matching the standard
library's own implementation down to the primitive.

### Atomic

Lock-free atomic storage for booleans, integers, pointers, and any
`AtomicRepresentable` type, with explicit memory orderings:

```swift
let counter = Atomic<Int>(0)

counter.add(1, ordering: .relaxed)
let current = counter.load(ordering: .relaxed)
```

### RWLock

A reader-writer lock that owns the value it protects: any number of concurrent
readers, or exactly one writer. The lock is writer-preferring — a blocked
writer stops new readers from acquiring the lock, so writers cannot starve.

Readers receive the value by borrow and cannot mutate it; a writer receives it
`inout` with the same exclusive access `Mutex.withLock` grants.
`withReadLockIfAvailable` and `withWriteLockIfAvailable` are the non-blocking
variants.

Prefer `Mutex` unless reads are frequent, writes are rare, *and* the read
closure does enough work for concurrency to pay: with very short read
sections, the cost of tracking readers exceeds what parallel reading saves.

## Designed to Be Replaced

`Mutex` and `Atomic` intentionally match the standard library's names and
APIs. Once your deployment target reaches the OS versions that ship
`Synchronization` (macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2), this
package starts emitting deprecation warnings — the signal that migrating is a
matter of changing an import. `RWLock` has no standard-library counterpart
and stays useful past that point.

On non-Apple platforms the Swift runtime is bundled with the application, so
`Synchronization` is always available regardless of OS version; there, `Mutex`
and `Atomic` are forwarding type aliases to the standard library's.

## Platform Support

The package supports macOS 12, iOS 15, tvOS 15, watchOS 8, and visionOS 1 or
later, along with every platform the Swift toolchain targets. `RWLock` selects
its backend per platform:

| Platform | `Atomic` / `Mutex` | `RWLock` backend |
| --- | --- | --- |
| Apple platforms | Back-deployed implementation | Atomic reader counting, an unfair-lock writer mutex, and address-based waiting for sleep/wake — Mach semaphores below macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, visionOS 1.1 |
| Linux (glibc), Android | Standard library type alias | `pthread_rwlock_t`, configured writer-preferring |
| Linux (musl), WASI | Standard library type alias | Semaphore-based, writer-preferring |
| Others (Windows, embedded) | Standard library type alias | Exclusive-mutex fallback — correct, but without reader parallelism |

Building the package requires Swift 6.2 or later.

### Running the tests

`swift test` needs no arguments and takes no environment variables. Nothing
selects a backend: `RWLock` uses the one its OS provides, so what a run covers
is what that OS would ship. Running the suite on a simulator runtime older than
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

## Using Swift Synchronization Kit in Your Project

To use this package in a SwiftPM project, add the following to your
`Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/sinoru/swift-synchronization-kit.git",
        "0.0.1"..<"0.1.0"
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
    "0.0.1"..<"0.1.0",
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
