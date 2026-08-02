# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.3] - 2026-08-02

### Changed

- Building the package now requires Swift 6.3, up from 6.2, and the manifest's
  tools version says so — a 6.2 toolchain refuses to resolve the package rather
  than failing partway through a build. The floor moves for `@inline(always)`
  (SE-0496), the official always-inline attribute, which `Mutex` and `RWLock`
  now carry on their locking methods in place of the underscored
  `@_transparent`. No API changes and no behavior changes.
- On the platforms that forward to the standard library — everything but
  Apple's — `Mutex`, `Atomic`, the three memory ordering types,
  `AtomicRepresentable`, `AtomicOptionalRepresentable`, and the storage
  representations are now re-exported rather than reached through a type alias.
  An alias carries the name but not the members, so a client that enabled
  `MemberImportVisibility` had to import `Synchronization` alongside this
  package to call `withLock`, `load(ordering:)`, or even to name `.relaxed`
  there, and not on Apple platforms. The re-export is scoped to the types each
  module forwards, so nothing else from `Synchronization` comes with it and the
  package traits still decide what a client can name.

## [0.0.2] - 2026-07-27

### Changed

- `RWLock`'s Apple backend now waits on an address rather than on a Mach
  semaphore wherever the OS provides it (macOS 14.4, iOS 17.4, tvOS 17.4,
  watchOS 10.4, visionOS 1.1). Nothing is allocated on that path: a lock costs
  no kernel object and no entry in the task's port name space, however many
  readers and writers contend on it, and a departing writer releases every
  reader queued behind it with one atomic add and one wake instead of one
  system call each.
- On Apple releases predating those calls, `RWLock` still uses Mach semaphores,
  but creates their ports the first time a lock actually blocks somebody rather
  than when the lock is constructed. A lock that is never contended — the
  common case, and the one that made creating locks in bulk expensive — now
  costs no port at all.
- Both Apple backends share one copy of the locking algorithm, meeting it at
  four handoff points that hand out and take permits. Which one a lock uses
  follows from the running OS and nothing can override it. The Mach half is
  written to be deleted outright once the deployment targets reach the releases
  above.

### Removed

- `_MutexHandle` and `_RWLockHandle`, along with their initializers, are no
  longer public. They were never meant to be called directly — they are the
  platform plumbing under `Mutex` and `RWLock` — and 0.0.1 exposed them by
  oversight.

### Fixed

- ThreadSanitizer no longer reports races on a value guarded by `RWLock` where
  the Mach semaphore backend runs, which is any deployment target predating the
  releases above. A thread woken from that backend's wait touches no atomic on
  its way out of it, so the ordering was the semaphore's alone, and
  ThreadSanitizer does not model those calls; the lock now tells it about that
  edge where it makes it. The reports were the sanitizer's blind spot rather
  than a missing ordering, but they surfaced in the sanitizer runs of anyone
  deploying that far back, with none of the context that says so.

## [0.0.1] - 2026-07-25

### Added

- `Mutex`, a lock that owns the value it protects, with `withLock` and the
  non-blocking `withLockIfAvailable`. Backed by `os_unfair_lock` on Apple
  platforms, matching the standard library's own implementation, and by the
  `Synchronization` module elsewhere.
- `Atomic`, lock-free storage for booleans, integers, pointers, and any
  `AtomicRepresentable` type, with explicit memory orderings.
- `RWLock`, a writer-preferring reader-writer lock that owns the value it
  protects, with `withReadLock`, `withWriteLock`, and their non-blocking
  variants. Readers receive the value by borrow, writers `inout`. The backend
  is selected per platform: atomic reader counting with Mach semaphores on
  Apple platforms, `pthread_rwlock_t` on glibc and Android, a semaphore-based
  implementation on musl and WASI, and an exclusive-mutex fallback elsewhere.
- Package traits `Atomic`, `Mutex`, and `RWLock`, all enabled by default, so a
  client can depend on only the primitives it needs. The `SynchronizationKit`
  umbrella module re-exports whichever traits are enabled.
- Back-deployment of `Mutex` and `Atomic` to macOS 12, iOS 15, tvOS 15,
  watchOS 8, and visionOS 1 — OS versions that predate the standard library's
  `Synchronization` module. Both are deprecated once the deployment target
  reaches the versions that ship it (macOS 15, iOS 18, tvOS 18, watchOS 11,
  visionOS 2), where migrating is a matter of changing an import. `RWLock` has
  no standard-library counterpart and stays supported past that point.
- Inline storage for every primitive — no heap allocation and no separate box
  — so each one is safe to declare as a `let` property or a global.

[unreleased]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/sinoru/swift-synchronization-kit/releases/tag/v0.0.1
