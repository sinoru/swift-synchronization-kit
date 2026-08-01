//
//  RWLockHandle+Waiting.swift
//  SynchronizationKit
//

#if canImport(Darwin) || canImport(Musl) || canImport(wasi_pthread)
import SynchronizationKitCore

#if canImport(Darwin)
import CSynchronizationKitRWLock
import Darwin
public import SynchronizationKitAtomic
#elseif canImport(Musl)
import Musl
#else
import WASILibc
import wasi_pthread
#endif

// How a thread sleeps and how it is woken, kept apart from the algorithm that
// decides when.
//
// Each of the four entry points below is a counting semaphore operation:
// `_release` hands out permits and `_acquire` takes one, blocking until there
// is one to take. Permits rather than a condition is what lets the handoffs in
// `RWLockHandle.swift` stay as short as they are — a release that lands before
// its counterpart blocks is kept, so neither side re-checks anything on waking.
//
// - Note: On Darwin the semaphore half of this file goes when the deployment
//   targets reach macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4 and visionOS
//   1.1. That is `usesAddressWait`, every branch it picks, `_destroyAnySemaphore`
//   and its two calls in the handle's `deinit`, leaving the permit count as the
//   only reading of a wait word.

extension _RWLockHandle {
    /// Blocks until a permit is available on the writer's word, then takes it.
    @usableFromInline
    internal borrowing func _acquireWriterGate() {
        #if canImport(Darwin)
        _acquire(writerWord)
        #else
        _acquire(writerSemaphore)
        #endif
    }

    /// Blocks until a permit is available on the readers' word, then takes it.
    @usableFromInline
    internal borrowing func _acquireReaderGate() {
        #if canImport(Darwin)
        _acquire(readerWord)
        #else
        _acquire(readerSemaphore)
        #endif
    }

    /// Hands out `count` permits on the writer's word and wakes whoever can use
    /// them.
    ///
    /// - Precondition: `count` is positive.
    @usableFromInline
    internal borrowing func _releaseWriterGate(_ count: Int32) {
        #if canImport(Darwin)
        _release(count, on: writerWord)
        #else
        _release(count, on: writerSemaphore)
        #endif
    }

    /// Hands out `count` permits on the readers' word and wakes whoever can use
    /// them.
    ///
    /// - Precondition: `count` is positive.
    @usableFromInline
    internal borrowing func _releaseReaderGate(_ count: Int32) {
        #if canImport(Darwin)
        _release(count, on: readerWord)
        #else
        _release(count, on: readerSemaphore)
        #endif
    }
}

#if canImport(Darwin)
extension _RWLockHandle {
    private borrowing func _acquire(_ word: borrowing _AtomicWord) {
        if usesAddressWait {
            _acquireByAddressWait(word)
        } else {
            _acquireBySemaphore(word)
        }
    }

    private borrowing func _release(_ count: Int32, on word: borrowing _AtomicWord) {
        precondition(count > 0, "a gate cannot release a non-positive number of permits")
        if usesAddressWait {
            _releaseByAddressWait(count, on: word)
        } else {
            _releaseBySemaphore(count, on: word)
        }
    }

    // MARK: - Waiting on an address

    /// The word's address, which is what the kernel compares against.
    private borrowing func _address(
        of word: borrowing _AtomicWord
    ) -> UnsafeMutablePointer<UInt32> {
        unsafe word._rawAddress.assumingMemoryBound(to: UInt32.self)
    }

    private borrowing func _acquireByAddressWait(_ word: borrowing _AtomicWord) {
        while true {
            var permits = word.load(ordering: .acquiring)
            while permits > 0 {
                let (exchanged, current) = word.compareExchange(
                    expected: permits,
                    desired: permits &- 1,
                    ordering: .acquiringAndReleasing
                )
                if exchanged {
                    return
                }
                permits = current
            }

            // No permit to take, so sleep until the count moves off zero. A
            // release landing between the read above and this call cannot be
            // missed: the kernel compares the word itself, so such a release
            // either fails the comparison or wakes the sleep it established.
            if unsafe sk_rwlock_wait_on_address(_address(of: word), 0) < 0 {
                precondition(
                    errno == EINTR || errno == EFAULT || errno == ENOMEM,
                    "os_sync_wait_on_address failed"
                )
                // Every one of those is a documented early return rather than a
                // failure; the loop re-reads the count and decides again.
            }
        }
    }

    private borrowing func _releaseByAddressWait(_ count: Int32, on word: borrowing _AtomicWord) {
        word.wrappingAdd(UInt32(count), ordering: .releasing)

        // Publishing the permits above is what a sleeper's comparison tests, so
        // the wake below only has to cover threads already blocked.
        while true {
            let result =
                count == 1
                ? unsafe sk_rwlock_wake_one_by_address(_address(of: word))
                : unsafe sk_rwlock_wake_all_by_address(_address(of: word))
            if result >= 0 || errno == ENOENT {
                // `ENOENT` reports that nobody was blocked yet. The permits
                // stand, and the next thread to look will find them.
                return
            }

            precondition(
                errno == EINTR || errno == EFAULT || errno == ENOMEM,
                "os_sync_wake_by_address failed"
            )
            // The SDK gives the wake-all call the same early returns as the
            // wait: interrupted, or the kernel briefly short of memory. The
            // permits are already published, so abandoning the wake here would
            // leave sleepers parked on them; ask again instead.
        }
    }

    // MARK: - Waiting on a Mach semaphore

    private borrowing func _acquireBySemaphore(_ word: borrowing _AtomicWord) {
        let port = _semaphorePort(for: word)
        var result: kern_return_t
        repeat {
            result = semaphore_wait(port)
        } while result == KERN_ABORTED
        precondition(result == KERN_SUCCESS, "semaphore_wait failed")

        // The wait is the whole of this backend's ordering — a woken thread
        // reads the protected value without touching another atomic first — and
        // it is ordering ThreadSanitizer cannot see. Nothing but the sanitizer
        // reads this.
        unsafe sk_rwlock_tsan_acquire(UnsafeMutableRawPointer(_address(of: word)))
    }

    private borrowing func _releaseBySemaphore(_ count: Int32, on word: borrowing _AtomicWord) {
        // A signal can reach the gate before its counterpart blocks, and it may
        // not be dropped, so the waking side creates the semaphore too.
        let port = _semaphorePort(for: word)

        // Before the signal, so that the edge is on record by the time anything
        // can wake on it.
        unsafe sk_rwlock_tsan_release(UnsafeMutableRawPointer(_address(of: word)))

        for _ in 0 ..< count {
            semaphore_signal(port)
        }
    }

    /// The semaphore `word` names, creating it if this is the first thread to
    /// need one.
    private borrowing func _semaphorePort(for word: borrowing _AtomicWord) -> semaphore_t {
        let existing = word.load(ordering: .relaxed)
        return existing != 0 ? existing : _createSemaphorePort(for: word)
    }

    private borrowing func _createSemaphorePort(for word: borrowing _AtomicWord) -> semaphore_t {
        var created: semaphore_t = 0
        let result = unsafe semaphore_create(
            mach_task_self_, &created, SYNC_POLICY_FIFO, 0
        )
        precondition(result == KERN_SUCCESS, "semaphore_create failed")

        // Relaxed is enough: the word carries a port name and nothing else, and
        // the kernel object it names is complete before `semaphore_create`
        // returns, so there is no user-space write for this store to publish.
        let (exchanged, current) = word.compareExchange(
            expected: 0,
            desired: created,
            ordering: .relaxed
        )
        guard exchanged else {
            // Another thread got there first; hand this one back rather than
            // leaving it to occupy a port name for nothing.
            unsafe semaphore_destroy(mach_task_self_, created)
            return current
        }

        return created
    }

    /// Releases the semaphore `word` names, if one was ever created.
    ///
    /// Called only from `deinit`, and only for a handle that chose the
    /// semaphore reading — on the other one `word` is a permit count, which
    /// `semaphore_destroy` has no business being handed.
    @usableFromInline
    internal borrowing func _destroyAnySemaphore(_ word: borrowing _AtomicWord) {
        let name = word.load(ordering: .relaxed)
        if name != 0 {
            unsafe semaphore_destroy(mach_task_self_, name)
        }
    }
}
#else
extension _RWLockHandle {
    private borrowing func _acquire(_ semaphore: borrowing _Cell<sem_t>) {
        while unsafe sem_wait(semaphore._address) != 0 {
            // The wait aborts when a signal lands; nothing else is expected.
            precondition(errno == EINTR, "sem_wait failed")
        }
    }

    private borrowing func _release(_ count: Int32, on semaphore: borrowing _Cell<sem_t>) {
        precondition(count > 0, "a gate cannot release a non-positive number of permits")
        for _ in 0 ..< count {
            unsafe sem_post(semaphore._address)
        }
    }
}
#endif
#endif
