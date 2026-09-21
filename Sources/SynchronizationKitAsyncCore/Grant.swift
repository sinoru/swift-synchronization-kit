//
//  Grant.swift
//  SynchronizationKit
//

// `complete()` signals a blocked thread's park, so this file imports the
// Semaphore under the condition `_ThreadPark` is declared with. Internal
// rather than `package`: the type is reached from a body here, never named
// in a declaration.
#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows) || (os(WASI) && _runtime(_multithreaded))
import SynchronizationKitSemaphore
#endif

/// A waiter taken out of the queue with what it asked for, waiting to be
/// woken.
///
/// Returned by `_AsyncWaiter.grant()` under the state lock, and completed
/// outside it: waking a task takes the task's status lock, which the lock
/// ordering in `_AsyncWaitQueueOwner` forbids inside ours, and waking a thread
/// is a kernel call there is no reason to hold a lock across.
package struct _Grant: Sendable {
    private let parking: _Parking

    internal init(parking: _Parking) {
        self.parking = parking
    }

    /// Wakes the waiter: resumes the task, or signals the thread's park.
    package consuming func complete() {
        switch parking {
        case .continuation(let continuation):
            continuation.resume()
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows) || (os(WASI) && _runtime(_multithreaded))
        case .thread(let park):
            park.semaphore.signal()
        #endif
        }
    }
}
