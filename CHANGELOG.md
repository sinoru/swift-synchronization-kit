# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[unreleased]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/sinoru/swift-synchronization-kit/releases/tag/v0.0.1
