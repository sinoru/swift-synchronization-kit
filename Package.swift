// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let commonSwiftSettings: [PackageDescription.SwiftSetting] = [
    .enableUpcomingFeature("ApproachableConcurrency"),
    .strictMemorySafety(),

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
    // exactly what this package exists to reach below.
    //
    // Non-Apple platforms bundle the Swift runtime with the application instead
    // of shipping it in the OS, so `Synchronization` is already available to
    // them regardless of OS version. This package is Apple-only by design.
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
            ],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitMutexTests",
            dependencies: ["SynchronizationKitMutex"],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitAtomicTests",
            dependencies: ["SynchronizationKitAtomic"],
            swiftSettings: commonSwiftSettings,
        ),
        .testTarget(
            name: "SynchronizationKitRWLockTests",
            dependencies: ["SynchronizationKitRWLock"],
            swiftSettings: commonSwiftSettings,
        ),
    ]
)
