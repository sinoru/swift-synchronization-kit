//
//  ReaderBias.swift
//  SynchronizationKit
//

// Every backend but the fallback takes this: the two built here and the
// glibc/bionic one around `pthread_rwlock_t`. The fallback is an exclusive
// mutex on targets with nothing to block a thread on, has no reader path of
// its own to speed up, and no thread identity or clock to build this from; it
// declares the slot type uninhabited instead, in `RWLockHandle.swift`.
#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || canImport(wasi_pthread) || os(Windows)
// The thread identity is read on the inlined reader path, so the module
// providing it is on this one's interface.
#if canImport(Darwin)
public import Darwin
#elseif canImport(Glibc)
public import Glibc
#elseif canImport(Android)
public import Android
#elseif canImport(Musl)
public import Musl
#elseif os(Windows)
public import WinSDK
#else
// wasi-libc splits the pthread declarations off from the rest of libc into a
// module of their own, as the Semaphore backend notes.
public import wasi_pthread
public import WASILibc
#endif
// The word is a stored property of a `@usableFromInline` type, and the slot
// table is typed by the same atomic, so the module declaring it is on this
// one's interface.
public import SynchronizationKitAtomic

/// A slot in the shared table, holding the address of the lock whose reader
/// published itself there, or zero.
@usableFromInline
package typealias _ReaderSlot = UnsafeMutablePointer<SynchronizationKitAtomic.Atomic<UInt>>

/// How a reader takes the lock without writing to memory any other reader
/// writes to.
///
/// A reader-writer lock that counts its readers in one word has every reader
/// modify that word twice, and the cache line holding it migrates to whichever
/// core does so: with readers on several cores the line does nothing but move,
/// and the cost of a read lock climbs with the number of cores reading. Nothing
/// in the count is needed while no writer is around, which is the case a
/// reader-writer lock exists for. So while no writer is around, a reader
/// publishes itself somewhere else instead: a process-wide table of slots,
/// each on its own cache line, into which it writes the lock's address at a
/// position chosen by the lock and the thread, and clears on the way out. Two
/// readers on different threads land in different slots, and touch nothing in
/// common.
///
/// A writer turns the table off for its lock by driving `word` negative, then
/// scans the whole table and waits until no slot names the lock. Readers
/// check the word after publishing, and a writer scans after turning it off,
/// both sequentially consistent, so one of the two sees the other: a reader
/// that saw the word non-negative is seen by the writer's scan, and a reader
/// the scan missed sees the word negative, withdraws, and takes the counted
/// path — where the writer's announcement on the count is what it meets.
///
/// The scan is the writer's added price, and what it buys is spent readers
/// never touching a shared line, so its worth depends on how often writes
/// come. A write that scanned leaves the table off, with a deadline a
/// multiple of what the scan cost ahead; writes before the deadline find the
/// table off, skip the scan, and pay an atomic operation or two; and it is a
/// reader that turns the table back on, on finding it off and the deadline
/// past. So a lone write to a read-mostly value costs one scan and a few
/// counted reads, a run of writes costs one scan per deadline's worth of
/// them, and a writer never reads the clock unless it scans.
///
/// The word: non-negative while readers may publish, negative while they may
/// not. Off, the low bit says a writer holds the lock, which spares readers
/// asking their backend whether one does, and the bits above carry the
/// deadline, in the clock's own units. Turning the table back on is the one
/// step that needs the backend's writer-side exclusion, as `_turnOn` says.
///
/// The table is fixed in size and shared by every lock in the process, so a
/// lock costs one word more than it would, whatever the core count. A reader
/// whose slot, and the one after it, is taken by another thread's lock takes
/// the counted path for that acquisition and is no worse off than before.
@_staticExclusiveOnly
@usableFromInline
package struct _ReaderBias: ~Copyable {
    /// The number of slots in the table. A power of two, so a hash masks
    /// into it.
    ///
    /// The constants here are `@inline(always)` and `package`, as the entry
    /// points are, so that they fold into the reader path inlined into the
    /// client by guarantee rather than by the optimizer's cross-module
    /// discretion, which is all `@usableFromInline` would leave them to.
    @inline(always)
    package static var _slotCount: Int {
        256
    }

    /// The bytes between slots: one cache line at its largest, so that no two
    /// slots share one on any core the package runs on.
    @inline(always)
    package static var _slotStride: Int {
        128
    }

    /// How many consecutive slots a reader tries before taking the counted
    /// path.
    @inline(always)
    package static var _probes: Int {
        2
    }

    /// How many times what the scan cost the table stays off after a write
    /// that scanned.
    @inline(always)
    package static var _inhibitFactor: Int64 {
        9
    }

    /// The bit, in a negative word, saying a writer holds the lock.
    @inline(always)
    package static var _held: Int64 {
        1
    }

    /// Non-negative while readers may publish. See the type's note for the
    /// bits of a negative word.
    @usableFromInline
    internal let word = SynchronizationKitAtomic.Atomic<Int64>(0)

    @usableFromInline
    package init() {}

    /// What a published reader writes into its slot: this lock's address,
    /// which is fixed for the lock's lifetime and shared with no other.
    ///
    /// `withUnsafePointer(to:)` on a borrowed noncopyable value yields the
    /// address of that value's own storage: there is no copy it could be
    /// handed instead, and `@_staticExclusiveOnly` rules out the storage being
    /// reassigned or moved while a borrow is outstanding — the reasoning
    /// `Atomic._address` spells out.
    @inline(always)
    package var _identity: UInt {
        // Swift 6.4 treats the `withUnsafePointer` call itself as safe, and
        // warns that a marker on it covers nothing; 6.3 warns when the marker
        // is missing. Remove the `#else` branch, and this note, once the
        // package's minimum toolchain is 6.4.
        #if compiler(>=6.4)
        withUnsafePointer(to: self) { pointer in
            UInt(bitPattern: pointer)
        }
        #else
        unsafe withUnsafePointer(to: self) { pointer in
            UInt(bitPattern: pointer)
        }
        #endif
    }

    /// Where a reader of `lock` on `thread` publishes: the top bits of a
    /// Fibonacci hash of the two, so that the low bits both have in common —
    /// alignment, the thread structure's size — do not pile every reader into
    /// a few slots.
    @inline(always)
    package static func _slotIndex(lock: UInt, thread: UInt) -> Int {
        let golden = UInt(
            truncatingIfNeeded: UInt64(0x9E37_79B9_7F4A_7C15) >> (64 - UInt.bitWidth)
        )
        let mixed = (lock ^ (thread &* golden)) &* golden
        return Int(truncatingIfNeeded: mixed >> (UInt.bitWidth - _slotCount.trailingZeroBitCount))
    }

    /// The slot at `index`.
    @inline(always)
    package static func _slot(at index: Int) -> _ReaderSlot {
        unsafe _readerSlots.advanced(by: index &* _slotStride)
            .assumingMemoryBound(to: SynchronizationKitAtomic.Atomic<UInt>.self)
    }

    /// Publishes the calling thread as a reader of this lock, and returns
    /// where, or `nil` if a writer is about — or the slots it tried are in
    /// use — and the reader is to be counted instead.
    @inline(always)
    package borrowing func _enter() -> _ReaderSlot? {
        guard word.load(ordering: .relaxed) >= 0 else {
            return nil
        }
        let identity = _identity
        var index = Self._slotIndex(lock: identity, thread: _currentThreadToken())
        for _ in 0 ..< Self._probes {
            let slot = unsafe Self._slot(at: index)
            let exchanged = unsafe slot.pointee.compareExchange(
                expected: 0,
                desired: identity,
                ordering: .sequentiallyConsistent
            ).exchanged
            if exchanged {
                // Published. A writer that turned the table off before this
                // point will find the slot in its scan; one that does so after
                // will too. The one case left is a writer whose scan has
                // already passed, which is the case the re-check catches.
                if word.load(ordering: .sequentiallyConsistent) >= 0 {
                    return unsafe slot
                }
                unsafe slot.pointee.store(0, ordering: .relaxed)
                return nil
            }
            index = (index &+ 1) & (Self._slotCount &- 1)
        }
        return nil
    }

    /// Withdraws a reader published at `slot`.
    ///
    /// A release, so the reads it covered are complete before a writer's
    /// scan can observe the slot empty.
    @inline(always)
    package borrowing func _leave(_ slot: _ReaderSlot) {
        unsafe slot.pointee.store(0, ordering: .releasing)
    }

    /// The word, if the table is off, no writer is marked as holding the lock,
    /// and the deadline the last scan set has passed: what a reader about to
    /// be counted hands to `_turnOn` once its backend has ruled a writer out.
    @usableFromInline
    internal borrowing func _due() -> Int64? {
        let state = word.load(ordering: .acquiring)
        guard state < 0, state & Self._held == 0, _now() >= (state & Int64.max) >> 1 else {
            return nil
        }
        return state
    }

    /// Turns the table back on from `state`, as `_due` reported it.
    ///
    /// Called under writer-side exclusion, and only there. The held bit is a
    /// filter, not a guarantee: a writer's arrival and the bit it sets are not
    /// one operation with whatever count of writers a backend keeps, so the
    /// bit can be clear with a writer about. What rules a writer out is the
    /// backend holding what its writers hold, or having failed to take it.
    ///
    /// The exchange is a release, and the load in `_due` an acquire of the
    /// writer's release: a reader that then publishes on the strength of the
    /// word sees what the writer wrote.
    @usableFromInline
    internal borrowing func _turnOn(from state: Int64) {
        _ = word.compareExchange(expected: state, desired: 0, ordering: .sequentiallyConsistent)
    }

    /// Turns the table off for this lock and waits out the readers published
    /// in it — or, if `waiting` is false, reports whether there were any and
    /// leaves the table as it was if so.
    ///
    /// Called with writer-side exclusion held, and matched by `_restore`
    /// when it returns `true`.
    @usableFromInline
    internal borrowing func _revoke(waiting: Bool) -> Bool {
        let previous = word.exchange(Int64.min | Self._held, ordering: .sequentiallyConsistent)
        guard previous >= 0 else {
            // Off already, from a recent write; the exchange dropped its
            // deadline, which the readers to come are going to consult.
            word.store(previous | Self._held, ordering: .relaxed)
            return true
        }
        let identity = _identity
        let started = _now()
        guard Self._awaitPublished(identity, waiting: waiting) else {
            word.store(previous, ordering: .sequentiallyConsistent)
            return false
        }
        let ended = _now()
        let deadline = ended &+ (ended &- started) &* Self._inhibitFactor
        word.store(Int64.min | deadline << 1 | Self._held, ordering: .relaxed)
        return true
    }

    /// Ends the write `_revoke` began: the table stays off, and the readers
    /// to come may turn it on once the deadline passes.
    ///
    /// One compare-and-exchange rather than a store: where writers turn the
    /// table off before they hold the lock, a next writer may have set the bit
    /// again between the load and the store here, and the exchange leaves it
    /// alone as often as it can tell. Not always — the next writer may have
    /// left the word bit for bit as it was found — which is why the bit is a
    /// filter and `_turnOn` asks the backend. Sequentially consistent, as the
    /// store a reader's acquire meets on the way to turning the table on: what
    /// the writer changed has to be visible to a reader that publishes after
    /// that.
    @usableFromInline
    internal borrowing func _restore() {
        let held = word.load(ordering: .relaxed)
        _ = word.compareExchange(
            expected: held,
            desired: held & ~Self._held,
            ordering: .sequentiallyConsistent
        )
    }

    /// Scans the table for `identity`, waiting at each slot naming it until
    /// the reader there withdraws — or, if `waiting` is false, returning
    /// `false` at the first such slot.
    ///
    /// One pass suffices. A slot found empty cannot be taken for this lock
    /// afterwards: any reader publishing there re-checks the word, which is
    /// negative by now, and withdraws.
    ///
    /// The wait spins. A published reader has no shared word to signal, which
    /// is the point of publishing; a read section is expected to be short,
    /// and for the ones that are not the spin backs off as `_backOff` says,
    /// to the point of sleeping.
    @usableFromInline
    internal static func _awaitPublished(_ identity: UInt, waiting: Bool) -> Bool {
        for index in 0 ..< _slotCount {
            let slot = unsafe _slot(at: index)
            guard unsafe slot.pointee.load(ordering: .sequentiallyConsistent) == identity else {
                continue
            }
            guard waiting else {
                return false
            }
            var spins = 0
            while unsafe slot.pointee.load(ordering: .acquiring) == identity {
                spins &+= 1
                _backOff(after: spins)
            }
        }
        return true
    }
}

/// The table every lock's published readers share: `_slotCount` slots,
/// `_slotStride` bytes apart, on lines of their own. Allocated on first use
/// and never freed, as a process-wide fixture.
@usableFromInline
nonisolated(unsafe) package let _readerSlots: UnsafeMutableRawPointer = {
    let stride = _ReaderBias._slotStride
    let base = UnsafeMutableRawPointer.allocate(
        byteCount: _ReaderBias._slotCount &* stride,
        alignment: stride
    )
    for index in 0 ..< _ReaderBias._slotCount {
        unsafe base.advanced(by: index &* stride)
            .bindMemory(to: SynchronizationKitAtomic.Atomic<UInt>.self, capacity: 1)
            .initialize(to: SynchronizationKitAtomic.Atomic<UInt>(0))
    }
    return unsafe base
}()

/// A number identifying the calling thread for as long as it runs, cheap to
/// read: the pthread structure's address, or the system's thread identifier.
@inline(always)
package func _currentThreadToken() -> UInt {
    #if canImport(Darwin)
    return unsafe UInt(bitPattern: pthread_self())
    #elseif canImport(Glibc)
    return UInt(pthread_self())
    #elseif canImport(Android)
    return UInt(bitPattern: pthread_self())
    #elseif os(Windows)
    return UInt(GetCurrentThreadId())
    #else
    // musl and wasi-libc: a pointer to the thread structure.
    return unsafe UInt(bitPattern: pthread_self())
    #endif
}

/// A monotonic reading of the platform's cheapest clock, in whatever units it
/// counts in. Only ever compared with, and added to, its own readings.
///
/// On Apple platforms that is `mach_absolute_time`, in ticks, which App Store
/// submission requires a reason for; the package's privacy manifest gives
/// it. Apple's documentation offers `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`
/// as the equivalent, which needs no reason, and it reads the same clock at
/// twice the cost: about 10 ns against 5. That is paid by every counted read
/// while the table is off, which on the shortest read sections is a tenth of
/// the turn, measured; so the manifest is the price paid instead.
@usableFromInline
internal func _now() -> Int64 {
    #if canImport(Darwin)
    return Int64(truncatingIfNeeded: mach_absolute_time())
    #elseif os(Windows)
    var counter = LARGE_INTEGER()
    _ = QueryPerformanceCounter(&counter)
    return counter.QuadPart
    #else
    var time = timespec()
    _ = unsafe clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) &* 1_000_000_000 &+ Int64(time.tv_nsec)
    #endif
}

/// What a writer does between looks at a slot still naming its lock, having
/// looked `spins` times: nothing for the first few dozen, then it gives up
/// the processor, and past a thousand it sleeps, for twice as long each time
/// up to a millisecond.
///
/// The sleep is what keeps the wait from starving the reader it waits for.
/// Under a strict-priority scheduler — `SCHED_FIFO` on Linux — a thread that
/// only yields hands the core to threads of its own priority, and a reader of
/// lower priority pinned to that core never runs, and never leaves; a thread
/// asleep holds no core, whatever its priority. A read section is expected
/// to be over long before the sleeping starts.
@usableFromInline
internal func _backOff(after spins: Int) {
    if spins < 64 {
        return
    }
    if spins < 1024 {
        if spins & 63 == 0 {
            _yieldThread()
        }
        return
    }
    _sleepThread(nanoseconds: 1_000 << min(spins &- 1024, 10))
}

/// Blocks the calling thread for about `nanoseconds`, or the platform's
/// nearest longer unit.
@usableFromInline
internal func _sleepThread(nanoseconds: Int) {
    #if os(Windows)
    Sleep(DWORD(max(1, nanoseconds / 1_000_000)))
    #elseif os(WASI)
    // Where wasi-libc gives a module one thread, there is nobody to sleep
    // for; where it gives more, there is no priority for a sleep to undo.
    _yieldThread()
    #else
    var duration = timespec(tv_sec: 0, tv_nsec: nanoseconds)
    _ = unsafe nanosleep(&duration, nil)
    #endif
}

/// Gives up the processor for a moment, for a writer spinning on a reader
/// that is taking its time.
@usableFromInline
internal func _yieldThread() {
    #if os(Windows)
    _ = SwitchToThread()
    #elseif os(WASI)
    // No scheduler to yield to on the one thread wasi-libc gives a module;
    // a second thread, where threads exist, spins on.
    #else
    _ = sched_yield()
    #endif
}
#endif
