//
//  SynchronizationKit.swift
//  SynchronizationKit
//

// `Mutex` and `Atomic` live in separate targets so a client can depend on only
// the one it needs — `Mutex` in particular pulls in no C target. This umbrella
// re-exports both.
//
// The type names match the standard library's on purpose: once a deployment
// target reaches the OS versions that ship `Synchronization`, migrating is a
// matter of changing the import. Raising the deployment target that far also
// starts producing deprecation warnings here, which is the signal to do it.
//
// Where one file needs both modules at once, a module selector disambiguates:
// `SynchronizationKit::Mutex` versus `Synchronization::Mutex`.

#if Atomic
@_exported import SynchronizationKitAtomic
#endif
#if Mutex
@_exported import SynchronizationKitMutex
#endif
