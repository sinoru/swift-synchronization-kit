//
//  Benchmarks.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

import Benchmark

/// What the harness runs: every benchmark in this target, one register call
/// per primitive, each measured beside what a client would otherwise write.
///
/// Every sample takes as many turns as its scaling factor says and the
/// output is scaled, so what prints is the cost of one turn: one take and
/// release of the lock around one step of the chase that `Harness.swift`
/// describes. Read instructions for anything uncontended — it varies by a
/// fraction of a percent between runs where the clock varies by tens — and
/// the clock under contention, where the scheduler dominates both; on Linux
/// the instruction count needs performance counters the kernel may not let
/// a process read, and the column is then absent rather than wrong.
///
/// What a primitive allocates and retains on the way — for a lock's fast
/// path it should be nothing — is not measured by default, because
/// counting it costs what it counts: the harness hooks every allocation and
/// every retain and release to count them, which added an eighth to the
/// clock of an asynchronous handoff and instructions of its own to every
/// path that retains. The counts are a pass of their own:
///
///     swift package benchmark --metric mallocCountTotal \
///         --metric retainCount --metric releaseCount
///
/// Nothing here fails on a regression, and no threshold is checked in: the
/// numbers are to be read, or compared against a baseline taken on the same
/// machine before a change.
let benchmarks: @Sendable () -> Void = {
    // The harness keeps its defaults in a `nonisolated(unsafe)` static,
    // written once here before any benchmark reads it.
    unsafe Benchmark.defaultConfiguration = .init(
        metrics: [
            .wallClock,
            .instructions,
        ],
        timeUnits: .nanoseconds,
        scalingFactor: .mega
    )

    registerMutexBenchmarks()
    registerSemaphoreBenchmarks()
    registerRWLockBenchmarks()
    registerAsyncMutexBenchmarks()
    registerAsyncRWLockBenchmarks()
    registerAsyncSemaphoreBenchmarks()
}

extension Benchmark.Configuration {
    /// An uncontended case: a million turns per sample, as many samples as
    /// fit in a few seconds. Computed rather than stored so that it reads
    /// the defaults as they are when a benchmark is registered.
    static var uncontended: Self {
        .init(maxDuration: .seconds(3))
    }

    /// A case contended by threads: the same million turns shared between
    /// the workers, a handful of samples after one to warm up, since one
    /// sample is a whole contended run — or as many as fit in ten seconds,
    /// on a machine where a handoff costs tens of microseconds. Context
    /// switches on top of the defaults, since under contention they are
    /// what a handoff costs; skipped on a machine too small for the result
    /// to say anything about contention.
    static var contended: Self {
        .init(
            metrics: unsafe Benchmark.defaultConfiguration.metrics + [.cpuTotal, .contextSwitches],
            warmupIterations: 1,
            maxDuration: .seconds(10),
            maxIterations: 5,
            skip: !hasRoomToContend
        )
    }

    /// A case contended by tasks: as `contended`, but a task needs no core
    /// of its own, so nothing is skipped.
    static var handoff: Self {
        .init(
            metrics: unsafe Benchmark.defaultConfiguration.metrics + [.cpuTotal, .contextSwitches],
            warmupIterations: 1,
            maxDuration: .seconds(10),
            maxIterations: 5
        )
    }
}
