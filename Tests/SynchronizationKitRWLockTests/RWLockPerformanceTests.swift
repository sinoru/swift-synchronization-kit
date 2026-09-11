//
//  RWLockPerformanceTests.swift
//  SynchronizationKit
//

import Dispatch
import Foundation
import SynchronizationKitAtomic
import SynchronizationKitMutex
import SynchronizationKitTestUtils
import XCTest

@testable import SynchronizationKitRWLock

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// What `RWLock` costs, on whichever backend the running OS provides — and
/// what the three things a client would otherwise write cost on the same
/// turns: the platform's `pthread_rwlock_t`; a concurrent `DispatchQueue`,
/// reads in `sync` and writes behind a `.barrier`; and this package's
/// `Mutex`, which the README says to prefer until reads are frequent, writes
/// rare, and the read section long enough for parallel reading to pay. Each
/// case runs once per implementation, so the four land in one report.
///
/// The harness, and why it measures the way it does, is in
/// `Measurement.swift`. Every case is skipped in a debug build, so an
/// ordinary `swift test` is untouched and no environment variable has to be
/// remembered. Measure in release:
///
///     swift test -c release -Xswiftc -enable-testing \
///         --filter RWLockPerformanceTests
///
/// `-enable-testing` is what the rest of the target's `@testable` imports need
/// in release; it is not what ships. It makes internal symbols externally
/// visible, which costs the optimizer some of what it may assume, so read these
/// as a self-consistent series rather than as the cost of a release build.
///
/// A critical section is one step of the chase, except in the `Section`
/// cases, which run the read-mostly mix again with every section 64, 256,
/// and 1024 steps long — from about a dictionary lookup to about a
/// microsecond of work. That is where a reader-writer lock is meant to pull
/// ahead of a mutex, and the series says at what length this one does.
///
/// On glibc and bionic the package's `RWLock` is itself a `pthread_rwlock_t`,
/// configured writer-preferring, so the `Pthread` cases there measure the
/// default configuration against it rather than a different lock. Where no
/// platform module offers one — Windows — those cases are absent and the
/// other three comparisons run.
final class RWLockPerformanceTests: XCTestCase {
    /// A reference to hold the lock by.
    ///
    /// Capturing a noncopyable value in a measured block currently fails to
    /// compile — "copy of noncopyable typed value", reported by the compiler as
    /// its own bug — so the block captures this instead and reaches the lock
    /// through it.
    final class LockBox: MeasuredReadWriteLock, @unchecked Sendable {
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

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    /// The platform's reader-writer lock, in its default configuration, and
    /// what it guards. Allocated rather than stored inline: a
    /// `pthread_rwlock_t` must not move once initialized, and a pointer is
    /// the plain way to promise that. `@safe`, with the pointer marked
    /// `@unsafe`: every access to it is spelled out below, and it is what the
    /// lock guards, so nothing else reaches it.
    @safe
    final class PthreadLockBox: MeasuredReadWriteLock, @unchecked Sendable {
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
#endif

    /// The reader-writer pattern Dispatch offers: a concurrent queue, reads
    /// submitted with `sync`, writes with `sync` and the `.barrier` flag.
    final class QueueLockBox: MeasuredReadWriteLock, @unchecked Sendable {
        private let queue = DispatchQueue(
            label: "SynchronizationKitRWLockTests.QueueLockBox",
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
    final class MutexLockBox: MeasuredReadWriteLock, @unchecked Sendable {
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

    override func setUpWithError() throws {
        try skipUnlessMeasurable()
    }

    // MARK: - Harness

    /// Runs one reader and writer mix over a fresh lock, every section
    /// `steps` long. Writers come first in the worker numbering.
    private func measureContention<Lock: MeasuredReadWriteLock>(
        _: Lock.Type,
        readers: Int,
        writers: Int,
        iterations: Int,
        steps: Int = 1
    ) {
        measureContention(
            groups: [
                (workers: writers, iterations: iterations),
                (workers: readers, iterations: iterations),
            ],
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
        } check: { lock in
            XCTAssertEqual(lock.writes, writers * iterations, "the write side did not run")
        }
    }

    private func measureUncontended<Lock: MeasuredReadWriteLock>(
        _: Lock.Type,
        writing: Bool,
        iterations: Int
    ) {
        measureUncontended(iterations: iterations, makeFixture: Lock.init) { lock in
            var index = 0
            if writing {
                for _ in 0 ..< iterations {
                    index = lock.write(from: index, steps: 1)
                }
            } else {
                for _ in 0 ..< iterations {
                    index = lock.read(from: index, steps: 1)
                }
            }
            return index
        } check: { lock in
            XCTAssertEqual(lock.writes, writing ? iterations : 0, "the workload did not run")
        }
    }

    // MARK: - Uncontended

    func testUncontendedReads() {
        measureUncontended(LockBox.self, writing: false, iterations: 500_000)
    }

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testUncontendedReadsPthread() {
        measureUncontended(PthreadLockBox.self, writing: false, iterations: 500_000)
    }
#endif

    func testUncontendedReadsDispatchQueue() {
        measureUncontended(QueueLockBox.self, writing: false, iterations: 500_000)
    }

    func testUncontendedReadsMutex() {
        measureUncontended(MutexLockBox.self, writing: false, iterations: 500_000)
    }

    func testUncontendedWrites() {
        measureUncontended(LockBox.self, writing: true, iterations: 500_000)
    }

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testUncontendedWritesPthread() {
        measureUncontended(PthreadLockBox.self, writing: true, iterations: 500_000)
    }
#endif

    func testUncontendedWritesDispatchQueue() {
        measureUncontended(QueueLockBox.self, writing: true, iterations: 500_000)
    }

    func testUncontendedWritesMutex() {
        measureUncontended(MutexLockBox.self, writing: true, iterations: 500_000)
    }

    // MARK: - Read-mostly

    /// How many turns of a read-mostly worker are reads for each write.
    static let readsPerWrite = 99

    /// A lock and the count of writes its workers made, which is what the
    /// count of writes it saw has to come to. Made afresh with the lock: the
    /// harness runs a measured block several times over.
    private final class ReadMostlyFixture<Lock: MeasuredReadWriteLock>: Sendable {
        let lock = Lock()
        let expectedWrites = Atomic<Int>(0)
    }

    /// Runs `contendedWorkers` workers over a fresh lock, each writing once
    /// in every `readsPerWrite + 1` turns and reading otherwise, every
    /// section `steps` long. The writes are spread across the workers and
    /// through the run rather than given to one worker to make flat out, so
    /// no writer is forever queued behind the readers.
    private func measureReadMostly<Lock: MeasuredReadWriteLock>(
        _: Lock.Type,
        steps: Int = 1,
        iterations: Int = 50_000
    ) throws {
        try skipUnlessRoomToContend()
        measureContention(
            workers: contendedWorkers,
            iterations: iterations,
            makeFixture: ReadMostlyFixture<Lock>.init
        ) { fixture, worker, share in
            let lock = fixture.lock
            var index = worker
            var turn = 0
            var writes = 0
            share.eachTurn(steps: steps) {
                turn += 1
                if turn % (Self.readsPerWrite + 1) == 0 {
                    index = lock.write(from: index, steps: steps)
                    writes += 1
                } else {
                    index = lock.read(from: index, steps: steps)
                }
            }
            fixture.expectedWrites.wrappingAdd(writes, ordering: .relaxed)
            return index
        } check: { fixture in
            XCTAssertEqual(
                fixture.lock.writes,
                fixture.expectedWrites.load(ordering: .relaxed),
                "the write side did not run"
            )
        }
    }

    func testReadMostly() throws {
        try measureReadMostly(LockBox.self)
    }

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testReadMostlyPthread() throws {
        try measureReadMostly(PthreadLockBox.self)
    }
#endif

    func testReadMostlyDispatchQueue() throws {
        try measureReadMostly(QueueLockBox.self)
    }

    func testReadMostlyMutex() throws {
        try measureReadMostly(MutexLockBox.self)
    }

    // MARK: - The same, with sections long enough for reading in parallel to pay

    func testReadMostlySection64() throws {
        try measureReadMostly(LockBox.self, steps: 64, iterations: 20_000)
    }

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testReadMostlySection64Pthread() throws {
        try measureReadMostly(PthreadLockBox.self, steps: 64, iterations: 20_000)
    }
#endif

    func testReadMostlySection64DispatchQueue() throws {
        try measureReadMostly(QueueLockBox.self, steps: 64, iterations: 20_000)
    }

    func testReadMostlySection64Mutex() throws {
        try measureReadMostly(MutexLockBox.self, steps: 64, iterations: 20_000)
    }

    func testReadMostlySection256() throws {
        try measureReadMostly(LockBox.self, steps: 256, iterations: 10_000)
    }

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testReadMostlySection256Pthread() throws {
        try measureReadMostly(PthreadLockBox.self, steps: 256, iterations: 10_000)
    }
#endif

    func testReadMostlySection256DispatchQueue() throws {
        try measureReadMostly(QueueLockBox.self, steps: 256, iterations: 10_000)
    }

    func testReadMostlySection256Mutex() throws {
        try measureReadMostly(MutexLockBox.self, steps: 256, iterations: 10_000)
    }

    func testReadMostlySection1024() throws {
        try measureReadMostly(LockBox.self, steps: 1024, iterations: 4_000)
    }

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testReadMostlySection1024Pthread() throws {
        try measureReadMostly(PthreadLockBox.self, steps: 1024, iterations: 4_000)
    }
#endif

    func testReadMostlySection1024DispatchQueue() throws {
        try measureReadMostly(QueueLockBox.self, steps: 1024, iterations: 4_000)
    }

    func testReadMostlySection1024Mutex() throws {
        try measureReadMostly(MutexLockBox.self, steps: 1024, iterations: 4_000)
    }

    // MARK: - A writer releasing a crowd

    // Deliberately more readers than cores, so a departing writer has a queue to
    // hand the lock to. This is where releasing every one of them at once tells
    // against one system call each.

    func testWriterHandoff() throws {
        try skipUnlessRoomToContend()
        measureContention(
            LockBox.self,
            readers: ProcessInfo.processInfo.activeProcessorCount * 2,
            writers: 1,
            iterations: 4_000
        )
    }

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testWriterHandoffPthread() throws {
        try skipUnlessRoomToContend()
        measureContention(
            PthreadLockBox.self,
            readers: ProcessInfo.processInfo.activeProcessorCount * 2,
            writers: 1,
            iterations: 4_000
        )
    }
#endif

    func testWriterHandoffDispatchQueue() throws {
        try skipUnlessRoomToContend()
        measureContention(
            QueueLockBox.self,
            readers: ProcessInfo.processInfo.activeProcessorCount * 2,
            writers: 1,
            iterations: 4_000
        )
    }

    func testWriterHandoffMutex() throws {
        try skipUnlessRoomToContend()
        measureContention(
            MutexLockBox.self,
            readers: ProcessInfo.processInfo.activeProcessorCount * 2,
            writers: 1,
            iterations: 4_000
        )
    }

    // MARK: - Mixed

    func testMixedContention() throws {
        try skipUnlessRoomToContend()
        measureContention(LockBox.self, readers: contendedWorkers, writers: 4, iterations: 20_000)
    }

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
    func testMixedContentionPthread() throws {
        try skipUnlessRoomToContend()
        measureContention(
            PthreadLockBox.self,
            readers: contendedWorkers,
            writers: 4,
            iterations: 20_000
        )
    }
#endif

    func testMixedContentionDispatchQueue() throws {
        try skipUnlessRoomToContend()
        measureContention(
            QueueLockBox.self,
            readers: contendedWorkers,
            writers: 4,
            iterations: 20_000
        )
    }

    func testMixedContentionMutex() throws {
        try skipUnlessRoomToContend()
        measureContention(
            MutexLockBox.self,
            readers: contendedWorkers,
            writers: 4,
            iterations: 20_000
        )
    }
}

/// A lock the harness above can measure as a reader-writer lock: a chase
/// under the read lock, and a chase and a write under the write lock, each
/// returning where the chase ended. One protocol so that one harness serves
/// every implementation; it is private to this file and every adopter is
/// final, so the harness is specialized for each and no measured turn is
/// dispatched through it.
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

extension ChasePayload {
    /// `steps` steps of the chase from `index`, and where it ended.
    fileprivate func chase(from index: Int, steps: Int) -> Int {
        var index = index
        for _ in 0 ..< steps {
            index = cycle[index]
        }
        return index
    }
}
