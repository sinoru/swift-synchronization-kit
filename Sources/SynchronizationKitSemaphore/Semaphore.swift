//
//  Semaphore.swift
//  SynchronizationKit
//

#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || canImport(wasi_pthread) || os(Windows)
/// A counting semaphore that blocks the calling thread while it waits for a
/// signal.
///
/// This is `DispatchSemaphore` without Dispatch: `wait()` decrements the
/// count, blocking until a signal arrives if it is zero, and `signal()`
/// increments it, waking a waiting thread if there is one. What it leaves
/// behind is the library. A program that uses threads but not Swift
/// Concurrency links no Dispatch on Linux with this, where `DispatchSemaphore`
/// would bring `libdispatch` and its runtime in for one type; and where there
/// is no Dispatch at all, this is the semaphore there is.
///
///     final class WorkerPool {
///         private let slots = Semaphore(value: 4)
///
///         func run(_ job: Job) {
///             slots.wait()
///             defer { slots.signal() }
///             job.perform()
///         }
///     }
///
/// A semaphore is a count, not a lock: the thread that signals need not be the
/// one that waited, which is what makes it fit for handing work between
/// threads or bounding how many of them run at once. For protecting a value,
/// use `Mutex`, which owns the value and releases it from the thread that took
/// it.
///
/// The semaphore is stored inline, so it can be a `let` on a class or a
/// global with no allocation of its own. On Darwin it is one atomic word that
/// threads wait on by address; on releases predating that call — below macOS
/// 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4 and visionOS 1.1 — the word names
/// a Mach semaphore instead, created with the count if that is positive and
/// otherwise the first time a thread has to block or signal. Elsewhere it is
/// the platform's own: an unnamed POSIX semaphore on Linux, Android and WASI,
/// and on Windows a kernel semaphore object, created on the same terms as the
/// Mach one.
///
/// ## Waiting, and where it is allowed
///
/// `wait()` blocks a thread, and is therefore unavailable from asynchronous
/// contexts, as `DispatchSemaphore.wait()` is: a task that blocks its thread
/// holds a slot in the cooperative pool hostage, and the signal it waits for
/// may need that very slot to run. Tasks wait on `AsyncSemaphore`, which
/// suspends them instead.
///
/// Waiting threads are woken in no particular order. A `wait()` that returns
/// has taken a permit; which of several waiters takes a given permit is the
/// kernel's choice. There is no `wait(timeout:)` in this version.
///
/// ## The name
///
/// The platform overlays — `Darwin`, `Glibc`, `Musl`, `Android` — declare a
/// `Semaphore` of their own, a typealias for the pointer `sem_open` returns,
/// and `Foundation` re-exports the overlay. A file that imports none of those
/// sees only this type. One that does sees both, and there the bare name is
/// ambiguous where a type is named — a declared property type, a generic
/// argument — though not in a call, since only this type has an
/// `init(value:)`, nor in a property whose type is inferred from one. Such a
/// file names the type through its module, `SynchronizationKit::Semaphore`,
/// or `SynchronizationKit.Semaphore`, where it names it at all.
///
/// - Precondition: A semaphore must not be deallocated while its count is
///   below the value it was created with. Every wait still outstanding would
///   be parked on freed memory, and `DispatchSemaphore` traps on the same
///   condition. Where the backend can read its count, so does this.
///
/// - Precondition: The count must not overflow: `UInt32.max` on Darwin,
///   `SEM_VALUE_MAX` on POSIX, `Int32.max` on Windows. A `signal()` that would
///   take it past that traps rather than losing the permits — except on the
///   Mach path, whose count lives in the kernel where nothing here can read
///   it.
@_staticExclusiveOnly
public struct Semaphore: ~Copyable {
    @usableFromInline
    internal let handle: _SemaphoreHandle

    /// The count this semaphore started at, which `deinit` checks it has not
    /// fallen below.
    @usableFromInline
    internal let initialValue: Int32

    /// Creates a semaphore whose count starts at `value`.
    ///
    /// - Parameter value: How many waits can succeed before one has to block.
    ///   Must not be negative.
    @inline(always)
    public init(value: Int) {
        handle = _SemaphoreHandle(value: value)
        initialValue = Int32(value)
    }

    deinit {
        // What `DispatchSemaphore` checks too: a count below where it started
        // means a wait is still outstanding somewhere, and the thread in it
        // would be parked on freed memory.
        handle._checkNotInUse(since: initialValue)
    }
}

// The count is the only state, every operation on it is atomic or a kernel
// call, and there is no protected value to leak, so the type is safe to share
// for the same reason `DispatchSemaphore` is.
extension Semaphore: @unchecked Sendable {}

// MARK: - Waiting and signaling

extension Semaphore {
    /// Decrements the count, blocking until a signal arrives if it is zero.
    ///
    /// This blocks the calling thread, which is why it is unavailable from
    /// asynchronous contexts. Use `AsyncSemaphore` from a task.
    @available(*, noasync, message: "Blocks the thread; await an AsyncSemaphore instead")
    @inline(always)
    public borrowing func wait() {
        handle._wait()
    }

    /// Increments the count, waking a waiting thread if there is one.
    ///
    /// Unlike `DispatchSemaphore.signal()`, this does not report whether a
    /// thread was woken: not every backend can say, and a count that no
    /// backend can promise is not one to build on.
    @inline(always)
    public borrowing func signal() {
        handle._signal(1)
    }
}
#endif
