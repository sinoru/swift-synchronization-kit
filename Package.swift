// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let commonSwiftSettings: [PackageDescription.SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
    .strictMemorySafety(),

    // Imports default to `internal`, so every module that leaks into this
    // package's ABI has to say so with `public import`. Much of what this
    // package declares inlines into its callers, carrying its body across the
    // module boundary, so the line between an implementation detail and part of
    // the interface is not where it looks — the C shim behind `Atomic` is on
    // the wrong side of it. Making that explicit also makes it checkable: the
    // compiler warns when a `public import` stops being reachable from
    // inlinable code, and errors when an internal one starts.
    //
    // Member visibility follows the same principle one level down: a member is
    // in scope only where its defining module is imported outright, never by
    // way of something else that happens to import it.
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),

    // `Mutex` and `Atomic` store their payload inline, with no heap allocation
    // and no separate box, which is what `@_rawLayout` provides. The compiler
    // back-deploys the metadata initialization for these types on its own: it
    // picks `swift_initRawStructMetadata2`, `swift_initRawStructMetadata`, or a
    // `swift_initStructMetadata` fallback based on the deployment target, so
    // this reaches back as far as the Swift 5.0 runtime.
    //
    // `StaticExclusiveOnly` forbids declaring these types as `var`, which is
    // what makes an inline lock or atomic safe to expose by borrow.
    .enableExperimentalFeature("RawLayout"),
    .enableExperimentalFeature("StaticExclusiveOnly"),

    // `@available(anyAppleOS 26.0, *)` in place of the five-platform list.
    // Swift 6.4 accepts the spelling on its own and ignores this flag; 6.3
    // needs the flag. `#if os(anyAppleOS)` is a different matter: 6.3 quietly
    // evaluates it to false, flag or no flag, so the `#if` conditions keep
    // naming their platforms. Drop the flag once the package's minimum
    // toolchain is 6.4.
    .enableExperimentalFeature("AnyAppleOSAvailability"),
]

let package = Package(
    name: "SynchronizationKit",
    // The standard library's own Synchronization module starts here, which is
    // exactly what `Atomic` and `Mutex` exist to reach below.
    //
    // Non-Apple platforms bundle the Swift runtime with the application instead
    // of shipping it in the OS, so `Synchronization` is already available to
    // them regardless of OS version, and those two targets forward to it.
    // `RWLock` has no standard-library counterpart to forward to, so it is a
    // real implementation on every platform, Apple or not.
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "SynchronizationKit",
            targets: ["SynchronizationKit"]
        ),
    ],
    traits: [
        .trait(name: "Atomic"),
        .trait(name: "Mutex"),
        .trait(name: "RWLock"),
        .trait(name: "Semaphore"),
        .trait(name: "AsyncMutex"),
        .trait(name: "AsyncRWLock"),
        .trait(name: "AsyncSemaphore"),
        // Aggregates, so a client can pick a whole family without naming each
        // primitive: `Sync` is everything that blocks or spins a thread,
        // `Async` everything that suspends a task.
        .trait(name: "Sync", enabledTraits: ["Atomic", "Mutex", "RWLock", "Semaphore"]),
        .trait(name: "Async", enabledTraits: ["AsyncMutex", "AsyncRWLock", "AsyncSemaphore"]),
        .default(enabledTraits: ["Sync", "Async"]),
    ],
    targets: [
        .target(
            name: "SynchronizationKit",
            dependencies: [
                .target(name: "SynchronizationKitAtomic", condition: .when(traits: ["Atomic"])),
                .target(name: "SynchronizationKitMutex", condition: .when(traits: ["Mutex"])),
                .target(name: "SynchronizationKitRWLock", condition: .when(traits: ["RWLock"])),
                .target(name: "SynchronizationKitSemaphore", condition: .when(traits: ["Semaphore"])),
                .target(name: "SynchronizationKitAsyncMutex", condition: .when(traits: ["AsyncMutex"])),
                .target(name: "SynchronizationKitAsyncRWLock", condition: .when(traits: ["AsyncRWLock"])),
                .target(name: "SynchronizationKitAsyncSemaphore", condition: .when(traits: ["AsyncSemaphore"])),
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .target(
            name: "CSynchronizationKitAtomic",
        ),
        // Darwin's address-based wait and wake. They are public API that the
        // SDK's `os` module map happens not to list, so Swift cannot see them
        // without a shim. Only the Semaphore target needs them — RWLock waits
        // through its semaphores — and `Mutex` does not: it is an unfair lock,
        // whose priority donation these calls do not offer.
        .target(
            name: "CSynchronizationKitSemaphore",
        ),
        // The ThreadSanitizer annotations for a handoff the sanitizer cannot
        // see, which have to be compiled as C to know whether the sanitizer is
        // in play; the header says why the runtime's own annotations are not
        // enough. Two targets record such a handoff — Semaphore on its Mach
        // backend, the asynchronous wait queue on every platform — and this is
        // the one place the pair is defined.
        .target(
            name: "CSynchronizationKitCore",
        ),
        // Internal plumbing shared by the lock targets: inline raw-layout
        // storage. `package` access keeps it invisible to clients, so it needs
        // no trait and never appears in the umbrella.
        .target(
            name: "SynchronizationKitCore",
            swiftSettings: commonSwiftSettings,
        ),
        .target(
            name: "SynchronizationKitAtomic",
            dependencies: ["CSynchronizationKitAtomic"],
            swiftSettings: commonSwiftSettings,
        ),
        .target(
            name: "SynchronizationKitMutex",
            dependencies: ["SynchronizationKitCore"],
            swiftSettings: commonSwiftSettings,
        ),
        // A Semaphore is one atomic word on Darwin, waited on by address
        // through the shim, and the platform's own semaphore elsewhere. The
        // sanitizer annotations are for the Mach backend, so they too are
        // reached only from the Darwin side, but the target that carries them
        // builds everywhere and needs no condition.
        .target(
            name: "SynchronizationKitSemaphore",
            dependencies: [
                "CSynchronizationKitCore",
                "SynchronizationKitAtomic",
                "SynchronizationKitCore",
                .target(
                    name: "CSynchronizationKitSemaphore",
                    condition: .when(platforms: [
                        .macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS,
                    ]),
                ),
            ],
            swiftSettings: commonSwiftSettings,
        ),
        // An RWLock embeds a mutex for its writer-side exclusion and two
        // semaphores for its handoffs, so the dependencies point at those
        // targets rather than duplicating their handles.
        .target(
            name: "SynchronizationKitRWLock",
            dependencies: [
                "SynchronizationKitAtomic",
                "SynchronizationKitCore",
                "SynchronizationKitMutex",
                "SynchronizationKitSemaphore",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        // Internal plumbing shared by the asynchronous targets: the queue of
        // waiting tasks, how a task joins it, suspends, and leaves it on
        // cancellation, and how the tasks holding what the queue waits for
        // are escalated to the queue's priority. The queue is bookkeeping
        // under a synchronous mutex, so the dependency points at the Mutex
        // target the same way RWLock's does. `package` access, like
        // `SynchronizationKitCore`.
        //
        // The C dependency is for the ThreadSanitizer annotations on the
        // queue's handoff, on every platform: the wait queue is the same
        // everywhere.
        .target(
            name: "SynchronizationKitAsyncCore",
            dependencies: ["CSynchronizationKitCore", "SynchronizationKitMutex"],
            swiftSettings: commonSwiftSettings,
        ),
        // An AsyncMutex adds a holder to the shared wait queue, and stores its
        // value inline the way Mutex does.
        .target(
            name: "SynchronizationKitAsyncMutex",
            dependencies: [
                "SynchronizationKitAsyncCore",
                "SynchronizationKitCore",
                "SynchronizationKitMutex",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        // An AsyncRWLock adds a writer and a set of readers to the shared wait
        // queue, and stores its value inline the way RWLock does.
        .target(
            name: "SynchronizationKitAsyncRWLock",
            dependencies: [
                "SynchronizationKitAsyncCore",
                "SynchronizationKitCore",
                "SynchronizationKitMutex",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        // An AsyncSemaphore adds a count to the shared wait queue.
        .target(
            name: "SynchronizationKitAsyncSemaphore",
            dependencies: [
                "SynchronizationKitAsyncCore",
                "SynchronizationKitMutex",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        // What more than one suite has to agree about: which implementation is
        // under test, whether a sanitizer is watching, and how to wait for a
        // task to reach a queue. Neither is in a product, so neither reaches a
        // client; `package` access keeps it that way.
        //
        // A target rather than a file, because SwiftPM will not let two suites
        // share one — and the copies that restriction forced had already begun
        // to drift, one of them carrying a memory-safety warning the other did
        // not.
        //
        // The asynchronous dependencies are for the helpers that reach into the
        // wait queue; Atomic is for the measurement harness's counter. The
        // synchronous suites pay for the former in build time and nothing
        // else: what they import from here is a pair of globals, the stress
        // dial, and the harness.
        .target(
            name: "SynchronizationKitTestUtils",
            dependencies: [
                "SynchronizationKitAsyncCore",
                "SynchronizationKitAsyncMutex",
                "SynchronizationKitAsyncRWLock",
                "SynchronizationKitAtomic",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitMutexTests",
            dependencies: [
                "SynchronizationKitAtomic",
                "SynchronizationKitMutex",
                "SynchronizationKitTestUtils",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitAtomicTests",
            dependencies: ["SynchronizationKitAtomic", "SynchronizationKitTestUtils"],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitSemaphoreTests",
            dependencies: [
                "SynchronizationKitAtomic",
                "SynchronizationKitSemaphore",
                "SynchronizationKitTestUtils",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitRWLockTests",
            dependencies: [
                "SynchronizationKitAtomic",
                "SynchronizationKitMutex",
                "SynchronizationKitRWLock",
                "SynchronizationKitSemaphore",
                "SynchronizationKitTestUtils",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitAsyncMutexTests",
            dependencies: [
                "SynchronizationKitAsyncCore",
                "SynchronizationKitAsyncMutex",
                "SynchronizationKitTestUtils",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitAsyncRWLockTests",
            dependencies: [
                "SynchronizationKitAsyncCore",
                "SynchronizationKitAsyncRWLock",
                "SynchronizationKitMutex",
                "SynchronizationKitTestUtils",
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitAsyncSemaphoreTests",
            dependencies: [
                "SynchronizationKitAsyncCore",
                "SynchronizationKitAsyncSemaphore",
                "SynchronizationKitTestUtils",
            ],
            swiftSettings: commonSwiftSettings,
        ),
    ]
)
