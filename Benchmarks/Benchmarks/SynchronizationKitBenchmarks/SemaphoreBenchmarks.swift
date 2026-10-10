//
//  SemaphoreBenchmarks.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

import Benchmark
import Dispatch
import SynchronizationKit

// What `Semaphore` costs against `DispatchSemaphore`, which is what a client
// would otherwise reach for, on whichever backend the running OS provides.
//
// The semaphore is used as a lock — a count of one, taken around the chase —
// so that the same cases apply and the numbers sit beside the locks'. Each
// case runs twice, once per implementation.
//
// A semaphore has no fast path past the kernel once anybody is waiting, so
// the contended case is the handoff itself: every release wakes somebody.

/// The semaphore and what it guards, held by reference; `MutexBox` says why.
/// The payload is guarded by the semaphore, which is what makes the
/// unchecked conformance right.
final class SemaphoreBox: MeasuredLock, @unchecked Sendable {
    let semaphore = Semaphore(value: 1)
    private var payload = ChasePayload()

    func step(from index: Int) -> Int {
        semaphore.wait()
        payload.writes &+= 1
        let end = payload.cycle[index]
        semaphore.signal()
        return end
    }

    var writes: Int {
        semaphore.wait()
        let writes = payload.writes
        semaphore.signal()
        return writes
    }
}

final class DispatchSemaphoreBox: MeasuredLock, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 1)
    private var payload = ChasePayload()

    func step(from index: Int) -> Int {
        semaphore.wait()
        payload.writes &+= 1
        let end = payload.cycle[index]
        semaphore.signal()
        return end
    }

    var writes: Int {
        semaphore.wait()
        let writes = payload.writes
        semaphore.signal()
        return writes
    }
}

private let contendedScenarios = [
    (scenario: "contended", workers: contendedWorkers),
]

func registerSemaphoreBenchmarks() {
    registerLockCases(SemaphoreBox.self, named: "Semaphore", contended: contendedScenarios)
    registerLockCases(
        DispatchSemaphoreBox.self,
        named: "Semaphore",
        implementation: "DispatchSemaphore",
        contended: contendedScenarios
    )
}
