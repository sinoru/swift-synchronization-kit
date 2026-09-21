//
//  Parking.swift
//  SynchronizationKit
//

/// Where a queued waiter is parked: what a grant has to poke to wake it.
///
/// The thread case is present only where `_ThreadPark` is; see that file for
/// the condition.
package enum _Parking: Sendable {
    /// A task, suspended on this continuation.
    case continuation(CheckedContinuation<Void, any Error>)
    #if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows) || (os(WASI) && _runtime(_multithreaded))
    /// A thread, blocked in `_ThreadPark.semaphore`.
    case thread(_ThreadPark)
    #endif
}
