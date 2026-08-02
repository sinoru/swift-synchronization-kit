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
        .default(enabledTraits: ["Atomic", "Mutex", "RWLock"]),
    ],
    targets: [
        .target(
            name: "SynchronizationKit",
            dependencies: [
                .target(name: "SynchronizationKitAtomic", condition: .when(traits: ["Atomic"])),
                .target(name: "SynchronizationKitMutex", condition: .when(traits: ["Mutex"])),
                .target(name: "SynchronizationKitRWLock", condition: .when(traits: ["RWLock"])),
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .target(
            name: "CSynchronizationKitAtomic",
        ),
        // Darwin's address-based wait and wake. They are public API that the
        // SDK's `os` module map happens not to list, so Swift cannot see them
        // without a shim. Only the RWLock target needs them: `Mutex` is an
        // unfair lock, whose priority donation these calls do not offer.
        .target(
            name: "CSynchronizationKitRWLock",
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
        // An RWLock embeds a mutex for its writer-side exclusion, so the
        // dependency points at the Mutex target rather than duplicating its
        // handle.
        .target(
            name: "SynchronizationKitRWLock",
            dependencies: [
                "SynchronizationKitAtomic",
                "SynchronizationKitCore",
                "SynchronizationKitMutex",
                .target(
                    name: "CSynchronizationKitRWLock",
                    condition: .when(platforms: [
                        .macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS,
                    ]),
                ),
            ],
            swiftSettings: commonSwiftSettings,
        ),
        // What more than one suite has to agree about: which implementation is
        // under test, and whether a sanitizer is watching. Neither is in a
        // product, so neither reaches a client.
        //
        // A target rather than a file, because SwiftPM will not let two suites
        // share one — and the copies that restriction forced had already begun
        // to drift, one of them carrying a memory-safety warning the other did
        // not.
        .target(
            name: "SynchronizationKitTestSupport",
            swiftSettings: commonSwiftSettings,
        ),
        // The umbrella is the only target a client imports by name, and the
        // only one whose re-exports chain, so it gets a suite of its own even
        // though it declares nothing.
        .testTarget(
            name: "SynchronizationKitTests",
            dependencies: ["SynchronizationKit"],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitMutexTests",
            dependencies: ["SynchronizationKitMutex", "SynchronizationKitTestSupport"],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitAtomicTests",
            dependencies: ["SynchronizationKitAtomic", "SynchronizationKitTestSupport"],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitRWLockTests",
            dependencies: [
                "SynchronizationKitAtomic",
                "SynchronizationKitRWLock",
                "SynchronizationKitTestSupport",
            ],
            swiftSettings: commonSwiftSettings,
        ),
    ]
)
