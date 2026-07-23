//
//  SynchronizationKit.swift
//  SynchronizationKit
//

// `Mutex`, `Atomic`, and `RWLock` live in separate targets so a client can
// depend on only the ones it needs — `Mutex` in particular pulls in no C
// target. This umbrella re-exports each enabled one.
//
// The `Mutex` and `Atomic` names match the standard library's on purpose: once
// a deployment target reaches the OS versions that ship `Synchronization`,
// migrating is a matter of changing the import. Raising the deployment target
// that far also starts producing deprecation warnings here, which is the
// signal to do it. `RWLock` has no standard-library counterpart and stays
// useful past that point.
//
// Where one file needs both modules at once, a module selector disambiguates:
// `SynchronizationKit::Mutex` versus `Synchronization::Mutex`.

#if Atomic
@_exported import SynchronizationKitAtomic
#endif
#if Mutex
@_exported import SynchronizationKitMutex
#endif
#if RWLock
@_exported import SynchronizationKitRWLock
#endif
