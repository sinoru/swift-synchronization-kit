//
//  RWLockBenchmarks.swift
//  SynchronizationKitBenchmarks
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

import Benchmark
import Dispatch
import SynchronizationKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// What `RWLock` costs, on whichever backend the running OS provides — and
// what the three things a client would otherwise write cost on the same
// turns: the platform's `pthread_rwlock_t`; a concurrent `DispatchQueue`,
// reads in `sync` and writes behind a `.barrier`; and this package's
// `Mutex`, which the README says to prefer until reads are frequent, writes
// rare, and the read section long enough for parallel reading to pay. Each
// case runs once per implementation, so the four land in one report.
//
// A critical section is one step of the chase, except in the `section`
// cases, which run the read-mostly mix again with every section 64, 256,
// and 1024 steps long — from about a dictionary lookup to about a
// microsecond of work. That is where a reader-writer lock is meant to pull
// ahead of a mutex, and the series says at what length this one does.
//
// On glibc the package's `RWLock` is itself a `pthread_rwlock_t`,
// configured writer-preferring, so the `pthread_rwlock_t` cases there
// measure the default configuration against it rather than a different
// lock.

/// A lock the cases below can measure as a reader-writer lock: a chase
/// under the read lock, and a chase and a write under the write lock, each
/// returning where the chase ended. One protocol so that one set of cases
/// serves every implementation; every adopter is final, so the cases are
/// specialized for each and no measured turn is dispatched through it.
private protocol MeasuredReadWriteLock: Sendable {
    init()

    /// `steps` steps of the chase from `index` under the read lock.
    func read(from index: Int, steps: Int) -> Int

    /// One write and `steps` steps of the chase from `index` under the write
    /// lock.
    func write(from index: Int, steps: Int) -> Int

    /// How many writes have happened, read under the lock.
    var writes: Int { get }
}

/// A reference to hold the lock by; `MutexBox` says why.
private final class RWLockBox: MeasuredReadWriteLock, @unchecked Sendable {
    let lock = RWLock(ChasePayload())

    func read(from index: Int, steps: Int) -> Int {
        lock.withReadLock { $0.chase(from: index, steps: steps) }
    }

    func write(from index: Int, steps: Int) -> Int {
        lock.withWriteLock {
            $0.writes &+= 1
            return $0.chase(from: index, steps: steps)
        }
    }

    var writes: Int {
        lock.withReadLock { $0.writes }
    }
}

/// The platform's reader-writer lock, in its default configuration, and
/// what it guards. Allocated rather than stored inline: a
/// `pthread_rwlock_t` must not move once initialized, and a pointer is the
/// plain way to promise that. `@safe`, with the pointer marked `@unsafe`:
/// every access to it is spelled out below, and it is what the lock guards,
/// so nothing else reaches it.
@safe
private final class PthreadLockBox: MeasuredReadWriteLock, @unchecked Sendable {
    @unsafe private let lock: UnsafeMutablePointer<pthread_rwlock_t>
    private var payload = ChasePayload()

    init() {
        unsafe lock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        unsafe lock.initialize(to: pthread_rwlock_t())
        let result = unsafe pthread_rwlock_init(lock, nil)
        precondition(result == 0, "pthread_rwlock_init failed")
    }

    deinit {
        unsafe pthread_rwlock_destroy(lock)
        unsafe lock.deinitialize(count: 1)
        unsafe lock.deallocate()
    }

    func read(from index: Int, steps: Int) -> Int {
        var result = unsafe pthread_rwlock_rdlock(lock)
        precondition(result == 0, "pthread_rwlock_rdlock failed")
        let end = payload.chase(from: index, steps: steps)
        result = unsafe pthread_rwlock_unlock(lock)
        precondition(result == 0, "pthread_rwlock_unlock failed")
        return end
    }

    func write(from index: Int, steps: Int) -> Int {
        var result = unsafe pthread_rwlock_wrlock(lock)
        precondition(result == 0, "pthread_rwlock_wrlock failed")
        payload.writes &+= 1
        let end = payload.chase(from: index, steps: steps)
        result = unsafe pthread_rwlock_unlock(lock)
        precondition(result == 0, "pthread_rwlock_unlock failed")
        return end
    }

    var writes: Int {
        var result = unsafe pthread_rwlock_rdlock(lock)
        precondition(result == 0, "pthread_rwlock_rdlock failed")
        let writes = payload.writes
        result = unsafe pthread_rwlock_unlock(lock)
        precondition(result == 0, "pthread_rwlock_unlock failed")
        return writes
    }
}

/// The reader-writer pattern Dispatch offers: a concurrent queue, reads
/// submitted with `sync`, writes with `sync` and the `.barrier` flag.
private final class QueueLockBox: MeasuredReadWriteLock, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "SynchronizationKitBenchmarks.QueueLockBox",
        attributes: .concurrent
    )
    private var payload = ChasePayload()

    func read(from index: Int, steps: Int) -> Int {
        queue.sync { payload.chase(from: index, steps: steps) }
    }

    func write(from index: Int, steps: Int) -> Int {
        queue.sync(flags: .barrier) {
            payload.writes &+= 1
            return payload.chase(from: index, steps: steps)
        }
    }

    var writes: Int {
        queue.sync { payload.writes }
    }
}

/// This package's `Mutex`, taken for reads and writes alike.
private final class MutexLockBox: MeasuredReadWriteLock, @unchecked Sendable {
    let lock = Mutex(ChasePayload())

    func read(from index: Int, steps: Int) -> Int {
        lock.withLock { $0.chase(from: index, steps: steps) }
    }

    func write(from index: Int, steps: Int) -> Int {
        lock.withLock {
            $0.writes &+= 1
            return $0.chase(from: index, steps: steps)
        }
    }

    var writes: Int {
        lock.withLock { $0.writes }
    }
}

/// How many turns of a read-mostly worker are reads for each write.
private let readsPerWrite = 99

/// A lock and the count of writes its workers made, which is what the count
/// of writes it saw has to come to.
private final class ReadMostlyFixture<Lock: MeasuredReadWriteLock>: Sendable {
    let lock = Lock()
    let expectedWrites = Atomic<Int>(0)
}

/// Registers every case for `Lock` under "RWLock", with `implementation`
/// appended where the lock is a comparison rather than the primitive
/// itself.
private func registerReadWriteLockCases<Lock: MeasuredReadWriteLock>(
    _: Lock.Type,
    implementation: String? = nil
) {
    let suffix = implementation.map { ", \($0)" } ?? ""

    /// Runs one reader and writer mix over a fresh lock, every section
    /// `steps` long. Writers come first in the worker numbering.
    func registerContention(_ scenario: String, readers: Int, writers: Int, steps: Int = 1) {
        Benchmark("RWLock \(scenario)\(suffix)", configuration: .contended) { benchmark in
            benchmark.measureContention(
                groups: [writers, readers],
                makeFixture: Lock.init
            ) { lock, worker, share in
                var index = worker
                if worker < writers {
                    share.eachTurn(steps: steps) {
                        index = lock.write(from: index, steps: steps)
                    }
                } else {
                    share.eachTurn(steps: steps) {
                        index = lock.read(from: index, steps: steps)
                    }
                }
                return index
            } check: { lock, budgets in
                precondition(lock.writes == budgets[0], "the write side did not run")
            }
        }
    }

    func registerUncontended(_ scenario: String, writing: Bool) {
        Benchmark("RWLock \(scenario)\(suffix)", configuration: .uncontended) { benchmark in
            benchmark.measureUncontended(makeFixture: Lock.init) { lock, turns in
                var index = 0
                if writing {
                    for _ in turns {
                        index = lock.write(from: index, steps: 1)
                    }
                } else {
                    for _ in turns {
                        index = lock.read(from: index, steps: 1)
                    }
                }
                return index
            } check: { lock in
                precondition(
                    lock.writes == (writing ? benchmark.turnsPerSample : 0),
                    "the workload did not run"
                )
            }
        }
    }

    /// Runs `contendedWorkers` workers over a fresh lock, each writing once
    /// in every `readsPerWrite + 1` turns and reading otherwise, every
    /// section `steps` long. The writes are spread across the workers and
    /// through the run rather than given to one worker to make flat out, so
    /// no writer is forever queued behind the readers.
    func registerReadMostly(_ scenario: String, steps: Int = 1) {
        Benchmark("RWLock \(scenario)\(suffix)", configuration: .contended) { benchmark in
            benchmark.measureContention(
                workers: contendedWorkers,
                makeFixture: ReadMostlyFixture<Lock>.init
            ) { fixture, worker, share in
                let lock = fixture.lock
                var index = worker
                var turn = 0
                var writes = 0
                share.eachTurn(steps: steps) {
                    turn += 1
                    if turn % (readsPerWrite + 1) == 0 {
                        index = lock.write(from: index, steps: steps)
                        writes += 1
                    } else {
                        index = lock.read(from: index, steps: steps)
                    }
                }
                fixture.expectedWrites.wrappingAdd(writes, ordering: .relaxed)
                return index
            } check: { fixture in
                precondition(
                    fixture.lock.writes == fixture.expectedWrites.load(ordering: .relaxed),
                    "the write side did not run"
                )
            }
        }
    }

    registerUncontended("uncontended reads", writing: false)
    registerUncontended("uncontended writes", writing: true)

    // Every worker reads and nobody writes: what a read costs when the lock
    // is doing the one thing a reader-writer lock is for. The section is one
    // step, so the number is the lock and nothing else.
    registerContention("concurrent reads", readers: contendedWorkers, writers: 0)

    registerReadMostly("read-mostly")
    for steps in [64, 256, 1024] {
        registerReadMostly("read-mostly, section \(steps)", steps: steps)
    }

    // Deliberately more readers than cores, so a departing writer has a
    // queue to hand the lock to. This is where releasing every one of them
    // at once tells against one system call each.
    registerContention("writer handoff", readers: oversubscribedWorkers, writers: 1)

    registerContention("mixed contention", readers: contendedWorkers, writers: 4)
}

func registerRWLockBenchmarks() {
    registerReadWriteLockCases(RWLockBox.self)
    registerReadWriteLockCases(PthreadLockBox.self, implementation: "pthread_rwlock_t")
    registerReadWriteLockCases(QueueLockBox.self, implementation: "DispatchQueue")
    registerReadWriteLockCases(MutexLockBox.self, implementation: "Mutex")
}
