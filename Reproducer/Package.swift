// swift-tools-version: 6.0

import PackageDescription

// Depends on nothing: the point of it is that the crash needs none of
// swift-synchronization-kit.
let package = Package(
    name: "Reproducer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "reproducer", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
