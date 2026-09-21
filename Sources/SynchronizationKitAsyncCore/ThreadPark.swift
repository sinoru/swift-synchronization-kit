//
//  ThreadPark.swift
//  SynchronizationKit
//

// A thread waits in the queue on a `Semaphore`, so a thread can wait only
// where one exists: the condition is the Semaphore module's own. Where it
// fails there is nothing to block a thread on, and the blocking entry
// points are left out with it, on every owner. `_Parking` and `_Grant`
// repeat the condition for the case and the wake that reach this type.
#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows) || (os(WASI) && _runtime(_multithreaded))
package import SynchronizationKitSemaphore

/// The semaphore a thread blocks on while it waits in the queue.
///
/// A class rather than a semaphore on the waiting thread's stack, so that the
/// signaling side holds a reference of its own for as long as it is inside
/// `signal()`. Otherwise the waiter, woken by the count going up, could
/// return and free the semaphore while the signaler is still in the wake
/// call on it — the classic way to destroy a semaphore out from under a
/// post. The queue entry and the waiting thread each keep it alive; the
/// grant takes the last reference the signaler needs.
package final class _ThreadPark: Sendable {
    package let semaphore = Semaphore(value: 0)

    package init() {}
}
#endif
