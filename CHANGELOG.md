# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `AsyncMutex` and `AsyncRWLock` can be taken by a thread. `withLock`,
  `withReadLock`, and `withWriteLock` gain synchronous forms that block the
  calling thread, chosen wherever `await` is not possible and unavailable
  from asynchronous contexts, as `AsyncSemaphore`'s blocking `wait()` is;
  the three `IfAvailable` methods gain synchronous forms that never block. A
  thread waits in the same queue as the tasks, at the priority the runtime
  reports for it, and is served in its turn among them. It cannot be
  cancelled, and while it holds the lock no waiter can raise its priority,
  there being no task to raise. A task may hold the lock across an `await`
  while a thread waits, which makes each lock the bridge between the two that
  `AsyncSemaphore` already was for a count.

### Changed

- `AsyncMutex`, `AsyncRWLock`, and `AsyncSemaphore` hand off in the same
  time however many tasks are waiting, and at whatever mix of priorities.
  Their shared wait queue was an array, and each handoff scanned it for the
  waiter to serve next; under a few hundred waiters that scan was most of
  what a handoff cost, and a task cancelled while waiting was searched for as
  well. The queue is now a list threaded through the waiters themselves and
  kept in the order it is served, so the waiter to serve next is always at
  its head, a newcomer is placed by its priority without a walk past those it
  outranks, and leaving — on being served or on cancellation — unlinks in
  place. Order is unchanged: by priority, and by arrival among equals, which
  a waiter raised while queued keeps at its new priority.
- The fast paths of `RWLock` and `Semaphore` — taking or releasing either
  when no thread has to sleep or be woken, an atomic operation or two — now
  inline into the client, as `Mutex`'s and `Atomic`'s already did, and are
  therefore compiled for the client's deployment target rather than the
  package's minimum. On arm64 that is what decides whether an atomic
  operation is one instruction or a load-exclusive/store-exclusive loop, and
  the two differ by about twofold on an uncontended `RWLock`: an app
  deploying to iOS 26 or later, or opting in with `-target-cpu`, now gets the
  single instruction on those paths, where the package's own iOS 15 minimum
  had fixed the loop. Sleeping and waking stay inside the package; the
  README's platform notes say which targets get which.
- `AsyncMutex` and `AsyncRWLock` spend less on an uncontended take. On the
  package's own measurements, an uncontended `AsyncMutex` turn — take, yield,
  release — went from about 860 ns to about 680; a contended handoff is
  unchanged within measurement noise, as is `AsyncSemaphore`. Three changes,
  none to what the primitives promise:
  - A holder that took the lock without waiting is no longer asked its
    priority on the way in. The priority is read from the task itself the
    first time a waiter arrives to compare against it, which is the only
    time it is needed — a relaxed load of the task's status word, which the
    runtime makes from any thread.
  - A release whose holder no escalation has read no longer passes through
    the escalation lock to pin the holder, nor looks at the queue a second
    time to see whether the new holder is outranked; the critical section
    that hands the lock over now says whether either is needed. That is
    every uncontended release, and most contended ones.
  - The locking methods inline into the caller, as `Mutex`'s and `RWLock`'s
    do, so the generic closure they take is called where its types are
    known.

## [0.0.5] - 2026-09-07

### Added

- `AsyncRWLock`, a reader-writer lock for Swift Concurrency, behind a package
  trait of the same name that is enabled by default and included in the
  `Async` aggregate. It is `RWLock` restated for tasks, as `AsyncMutex` is
  `Mutex`: any number of readers or one writer, the value stored inline, and
  `async` closures that run on the caller's actor and may hold the lock across
  an `await`. Waiters are queued by priority and by arrival among equals; a
  waiting writer stops new readers, so writers cannot starve; and a departing
  holder hands the lock straight to the queue's head — a run of readers
  together, up to the first writer, or a writer alone. A task cancelled while
  waiting throws `CancellationError` without running the closure, and whoever
  it was holding back is served; a task that is already cancelled still takes
  a lock it can have without waiting. Where the OS escalates task priority, a
  waiter of higher priority than a holder raises every holder — each reader,
  when a writer waits on them — for as long as it holds the lock.
- `AsyncSemaphore` can be waited on by a thread. `wait()` gains a synchronous
  form that blocks the calling thread, chosen wherever `await` is not possible
  and unavailable from asynchronous contexts, as `Semaphore.wait()` is, so a
  task cannot reach it by mistake — including from a `Task { }` body with no
  other `await` in it. It takes from the same count and waits in the same
  queue as the asynchronous one, at the priority the runtime reports for the
  thread, so one semaphore can stand between a thread and a task with either
  side waiting and either side signaling. A thread's wait cannot be
  cancelled, and the priority it arrived at is the one it waits at. The count
  is handed straight to the waiter, so each contended handoff is a context
  switch, several times what `Semaphore` costs when it lets the signalling
  thread take the count back; threads that only ever wait on threads belong
  on `Semaphore`.

### Changed

- The package builds without warnings on Swift 6.4 as well as 6.3. Swift 6.4
  treats a `withUnsafePointer` call as safe in itself and flagged the `unsafe`
  marker that 6.3 requires on it as covering nothing; the six call sites
  concerned are now branched on the compiler version, so each sees the
  spelling it asks for.
- Availability for task priority escalation is spelled
  `@available(anyAppleOS 26.0, *)` in place of the five-platform list, with the
  `AnyAppleOSAvailability` experimental feature enabled for Swift 6.3, which
  needs it. Swift 6.4 accepts the spelling on its own.
- On Apple platforms, a `Semaphore` signal with nobody waiting no longer
  enters the kernel. The word threads wait on grows to 64 bits, permits in
  one half and waiting threads in the other — the arrangement glibc's `sem_t`
  uses — so a signal can see whether there is anyone to wake before asking;
  an address wait, unlike the Mach semaphore this replaced, keeps no signal
  that arrives before its waiter, so the count of waiters has to be kept
  here. An uncontended wait-and-signal pair falls from about 120 ns to under
  5 ns, level with `DispatchSemaphore`; a contended handoff stays several
  times faster than one. The price is eight bytes: a `Semaphore` strides at
  16 rather than 8, and an `RWLock` at 40 rather than 32.
- `AsyncMutex` and `AsyncRWLock` no longer pay for priority escalation at
  every handoff. Whether a holder is outranked is now decided in the critical
  section that queued the waiter, or once after the release has pinned the
  departing holder, rather than in two more trips through the state lock at
  every step, and the wait queue keeps its highest priority as waiters come
  and go instead of scanning for it each time. With sixty-four tasks
  contending, a handoff falls from about 43 µs to under 4, level with
  `AsyncSemaphore`; nothing escalates any later than it did.

### Fixed

- ThreadSanitizer no longer reports races on a value guarded by `AsyncMutex`,
  `AsyncRWLock`, or handed across an `AsyncSemaphore` under a fast enough
  handoff. A waiter granted before its task has finished suspending continues
  in place, and that path through the runtime records no acquire where the
  enqueued path does, leaving the sanitizer with no edge between one holder
  and the next; the wait queue now records that edge itself, as `Semaphore`
  does for its Mach wait. As there, the reports were the sanitizer's blind
  spot rather than a missing ordering, but they would surface in the
  sanitizer runs of anyone contending one of these locks hard enough.

## [0.0.4] - 2026-09-06

### Added

- `AsyncMutex`, a lock for Swift Concurrency, behind a package trait of the
  same name that is enabled by default. Acquiring it suspends the calling task
  rather than blocking its thread, and its `withLock` closure is `async`, so
  the lock may be held across an `await`. The closure runs on the caller's
  actor. Waiters are queued by priority and by arrival among equals, and a
  released lock is handed directly to the next waiter. A task cancelled while
  waiting throws `CancellationError` without running the closure; a task that
  is already cancelled still takes a free lock but never waits for a held one.
  On macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, and every non-Apple
  platform, a waiter of higher priority than the holder escalates the holder
  for as long as it holds the lock. A waiter escalated while already queued
  passes that on, and moves up the queue, when built with Swift 6.4 or later.
- `AsyncSemaphore`, a counting semaphore for Swift Concurrency, behind a
  package trait of the same name that is enabled by default. It is
  `DispatchSemaphore` restated for tasks: `wait()` suspends the calling task
  rather than blocking its thread while the count is zero, and `signal()`
  resumes the next waiting task, returning whether there was one. Waiters are
  queued by priority and by arrival among equals, and a signal is handed
  directly to the next waiter. A task cancelled while waiting throws
  `CancellationError` and takes no count; a task that is already cancelled
  still takes a positive count but never waits for one. There is no
  `wait(timeout:)`: the wait is cancellable, which is how Swift Concurrency
  spells a deadline.
- `Semaphore`, a counting semaphore for threads, behind a package trait of
  the same name that is enabled by default. It is `DispatchSemaphore` without
  Dispatch: `wait()` blocks the thread while the count is zero, `signal()`
  wakes a waiting thread, and `wait()` is unavailable from asynchronous
  contexts, as Dispatch's is. The semaphore is stored inline — one atomic word
  on Darwin, waited on by address, with a Mach semaphore on releases predating
  that call; an unnamed POSIX semaphore on Linux, Android and WASI; a kernel
  semaphore object on Windows — so a program that uses threads but not Swift
  Concurrency links no Dispatch for it. There is no `wait(timeout:)` yet.
  `RWLock` now sleeps and wakes through two of these rather than through a
  waiting layer of its own; its behaviour and size are unchanged.
- Aggregate package traits `Sync` (`Atomic`, `Mutex`, `RWLock`, `Semaphore`)
  and `Async` (`AsyncMutex`, `AsyncSemaphore`), so a client can pick a family
  without naming each primitive. The default trait set is now spelled as these
  two.
- DocC catalogs for the umbrella module and for each primitive's module, so
  the documentation hosted on the Swift Package Index opens on an overview of
  the package — what each primitive is for, how the traits combine, and when
  to migrate to the standard library — instead of an empty page, and each
  module's page carries a summary of its own.

### Changed

- `RWLock` on Windows now takes the writer-preferring implementation the
  Apple and musl backends share — atomic reader counting, a `Mutex` for
  writers, and two `Semaphore`s for the handoff between readers and a writer —
  in place of the exclusive-mutex fallback, which had given up reader
  parallelism and writer preference for want of anything to block on. The
  fallback now remains only where there is no `Semaphore` to build on.

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

[unreleased]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.5...HEAD
[0.0.5]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/sinoru/swift-synchronization-kit/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/sinoru/swift-synchronization-kit/releases/tag/v0.0.1
