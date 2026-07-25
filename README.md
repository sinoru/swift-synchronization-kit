# Swift Synchronization Kit

[![Swift](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/swift.yml/badge.svg)](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/swift.yml)
[![Apple Platforms](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/apple-platforms.yml/badge.svg)](https://github.com/sinoru/swift-synchronization-kit/actions/workflows/apple-platforms.yml)

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
| Apple platforms | Back-deployed implementation | Atomic reader counting, an unfair-lock writer mutex, and Mach semaphores for sleep/wake |
| Linux (glibc), Android | Standard library type alias | `pthread_rwlock_t`, configured writer-preferring |
| Linux (musl), WASI | Standard library type alias | Semaphore-based, writer-preferring |
| Others (Windows, embedded) | Standard library type alias | Exclusive-mutex fallback — correct, but without reader parallelism |

Building the package requires Swift 6.2 or later.

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
    traits: ["RWLock"]
),
```

## Contributing

Bug reports, feature ideas, and pull requests are welcome on
[GitHub](https://github.com/sinoru/swift-synchronization-kit).

## License

[Apache License 2.0](LICENSE)
