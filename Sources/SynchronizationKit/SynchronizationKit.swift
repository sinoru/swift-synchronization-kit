//
//  SynchronizationKit.swift
//  SynchronizationKit
//

// Each primitive lives in a target of its own so a client can depend on only
// the ones it needs — `Mutex` in particular pulls in no C target. This
// umbrella re-exports each enabled one.
//
// The `Mutex` and `Atomic` names match the standard library's on purpose: once
// a deployment target reaches the OS versions that ship `Synchronization`,
// migrating is a matter of changing the import. Raising the deployment target
// that far also starts producing deprecation warnings here, which is the
// signal to do it. `RWLock`, `Semaphore`, `AsyncMutex`, and `AsyncSemaphore`
// have no standard-library counterpart and stay useful past that point.
//
// Where one file needs both modules at once, a module selector disambiguates:
// `SynchronizationKit::Mutex` versus `Synchronization::Mutex`.

#if Atomic
@_exported public import SynchronizationKitAtomic
#endif
#if Mutex
@_exported public import SynchronizationKitMutex
#endif
#if RWLock
@_exported public import SynchronizationKitRWLock
#endif
#if Semaphore
@_exported public import SynchronizationKitSemaphore
#endif
#if AsyncMutex
@_exported public import SynchronizationKitAsyncMutex
#endif
#if AsyncSemaphore
@_exported public import SynchronizationKitAsyncSemaphore
#endif
