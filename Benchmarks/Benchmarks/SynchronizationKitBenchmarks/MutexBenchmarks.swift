//
//  MutexBenchmarks.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

import Benchmark
import SynchronizationKit

#if canImport(Darwin)
import Synchronization
#endif

// What `Mutex` costs — and on Apple platforms, where it is this package's
// own, what it costs against the standard library's, which is what a client
// on a new enough OS would otherwise use.
//
// On Apple platforms each case runs twice, once per implementation, so the
// two land in one report: the package's is an `os_unfair_lock` reached
// through a raw-layout struct, the standard library's the same lock reached
// through its own, and the numbers say what the reaching costs. Elsewhere
// the package's `Mutex` is the standard library's, re-exported, so the
// comparison would be of a thing with itself and only the first half runs —
// as the cost of the lock every asynchronous primitive here keeps its state
// under.

/// A reference to hold the lock by.
///
/// Capturing a noncopyable value in a measured closure currently fails to
/// compile — "copy of noncopyable typed value", reported by the compiler as
/// its own bug — so the closure captures this instead and reaches the lock
/// through it.
final class MutexBox: MeasuredLock, @unchecked Sendable {
    let lock = SynchronizationKit.Mutex(ChasePayload())

    func step(from index: Int) -> Int {
        lock.withLock {
            $0.writes &+= 1
            return $0.cycle[index]
        }
    }

    var writes: Int {
        lock.withLock { $0.writes }
    }
}

#if canImport(Darwin)
@available(macOS 15, *)
final class StandardMutexBox: MeasuredLock, @unchecked Sendable {
    let lock = Synchronization.Mutex(ChasePayload())

    func step(from index: Int) -> Int {
        lock.withLock {
            $0.writes &+= 1
            return $0.cycle[index]
        }
    }

    var writes: Int {
        lock.withLock { $0.writes }
    }
}
#endif

/// Every core but two, so the handoff is between threads that each have
/// somewhere to run; and twice the cores, so most of the time the lock is
/// handed to a thread that has to be woken for it.
private let contendedScenarios = [
    (scenario: "contended", workers: contendedWorkers),
    (scenario: "oversubscribed", workers: oversubscribedWorkers),
]

func registerMutexBenchmarks() {
    registerLockCases(MutexBox.self, named: "Mutex", contended: contendedScenarios)

    #if canImport(Darwin)
    if #available(macOS 15, *) {
        registerLockCases(
            StandardMutexBox.self,
            named: "Mutex",
            implementation: "standard library",
            contended: contendedScenarios
        )
    }
    #endif
}
