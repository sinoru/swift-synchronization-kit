// swift-tools-version: 6.3
//
//  Package.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

import PackageDescription

// A package of its own rather than a target of the one above it, so that
// nothing a client resolves ever includes the benchmark harness: the manifest
// they read has no dependencies, and this one is only ever opened from inside
// this directory.
let package = Package(
    name: "Benchmarks",
    // The harness's floor, not the library's. The library deploys further
    // back than this and is not held to it by being measured here.
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        // The library with its default traits, which is every primitive: the
        // benchmarks measure them all.
        .package(path: "../"),
        .package(url: "https://github.com/ordo-one/benchmark.git", from: "1.36.4"),
    ],
    targets: [
        .executableTarget(
            name: "SynchronizationKitBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "SynchronizationKit", package: "swift-synchronization-kit"),
            ],
            path: "Benchmarks/SynchronizationKitBenchmarks",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .enableUpcomingFeature("InternalImportsByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .strictMemorySafety(),
            ],
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
    ]
)
