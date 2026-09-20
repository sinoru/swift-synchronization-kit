//
//  ReaderBias.swift
//  SynchronizationKit
//

// Every backend but the fallback takes this: the two built here and the
// glibc/bionic one around `pthread_rwlock_t`. The fallback is an exclusive
// mutex on targets with nothing to block a thread on, has no reader path of
// its own to speed up, and no thread identity or clock to build this from; it
// declares the slot type uninhabited instead, in `RWLockHandle.swift`.
//
// WASI is on the list only with threads: without them wasi-libc has no
// semaphore to build the gates from, and the fallback is taken.
#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows) || (os(WASI) && _runtime(_multithreaded))
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
// module of their own, as the Semaphore backend notes; the thread identity is
// all this file reads from libc directly. The clock comes through the C
// target, for the reason `_now()` gives.
public import wasi_pthread
import CSynchronizationKitRWLock
#endif
// The word is a stored property of a `@usableFromInline` type, and the slot
// table is typed by the same atomic, so the module declaring it is on this
// one's interface.
public import SynchronizationKitAtomic

/// A slot in the shared table, holding the address of the lock whose reader
/// published itself there, or zero.
@usableFromInline
package typealias _ReaderSlotAddress = UnsafeMutablePointer<SynchronizationKitAtomic.Atomic<UInt>>

/// A reader's claim on a slot, from the acquisition that published it there
/// to the release that clears it.
///
/// A token rather than the address it wraps. `~Escapable` ties it to the
/// borrow of the lock that issued it, so that keeping it past the read
/// section — storing it in a property or a global, handing it to an escaping
/// closure, returning it — is a compile error rather than a pointer into a
/// slot some other reader has taken since. `~Copyable` leaves exactly one of
/// it, which is what the unlock the token is handed back to expects.
///
/// Neither costs anything at runtime: the token is the address, and an
/// optional one is still a single word, with the null address for `nil`.
///
/// `@unsafe` for what the type cannot check — that the address is one this
/// table handed out, and that the lock it names is the lock being unlocked —
/// which is the obligation the pointer this replaces carried in its type.
@unsafe
@usableFromInline
package struct _ReaderSlot: ~Copyable, ~Escapable {
    /// The slot this reader published itself in.
    @usableFromInline
    package let _address: _ReaderSlotAddress

    /// Names `bias` so the token's lifetime is tied to it: the slot names
    /// that lock, and clearing it is that lock's business.
    @inline(always)
    @_lifetime(borrow bias)
    package init(_ address: _ReaderSlotAddress, publishedIn bias: borrowing _ReaderBias) {
        unsafe self._address = address
    }
}

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
    internal init() {}

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
    /// Fibonacci hash of the two.
    ///
    /// Of their sum, where a thread is named by the address of its thread
    /// structure. Those addresses are evenly spaced — each sits at the same
    /// place in a stack mapping of the same size — and a Fibonacci hash
    /// spreads an arithmetic progression as evenly as the table allows,
    /// whatever lock is added to it: the threads reading one lock start at
    /// slots of their own. Two that started at the same slot would hand its
    /// line back and forth on every read, which is the cost publishing
    /// exists to avoid. Mixing the two further loses that, and leaves each
    /// pair one chance in `_slotCount` of sharing, per lock.
    ///
    /// Windows names a thread by an identifier drawn from a table the whole
    /// system shares, in no order, and nothing spreads those by construction.
    /// There the two are mixed, so that a pair which collides does so on one
    /// lock in `_slotCount` rather than on every lock in the process.
    @inline(always)
    package static func _slotIndex(lock: UInt, thread: UInt) -> Int {
        let golden = UInt(
            truncatingIfNeeded: UInt64(0x9E37_79B9_7F4A_7C15) >> (64 - UInt.bitWidth)
        )
        #if os(Windows)
        let mixed = (lock ^ (thread &* golden)) &* golden
        #else
        let mixed = (lock &+ thread) &* golden
        #endif
        return Int(truncatingIfNeeded: mixed >> (UInt.bitWidth - _slotCount.trailingZeroBitCount))
    }

    /// The slot at `index`.
    @inline(always)
    package static func _slot(at index: Int) -> _ReaderSlotAddress {
        unsafe _slot(at: index, in: _readerSlots)
    }

    /// The slot at `index` of the table at `slots`.
    ///
    /// For `_enter`, which inlines into its caller's module and probes more
    /// than one slot. There, each read of `_readerSlots` is a call to the
    /// global's accessor, which the compiler does not move past the
    /// compare-and-exchange between two probes; reading the address once
    /// before them leaves one call where a probe that missed made two.
    @inline(always)
    package static func _slot(at index: Int, in slots: UnsafeMutableRawPointer) -> _ReaderSlotAddress {
        unsafe slots.advanced(by: index &* _slotStride)
            .assumingMemoryBound(to: SynchronizationKitAtomic.Atomic<UInt>.self)
    }

    /// Publishes the calling thread as a reader of this lock, and returns
    /// where, or `nil` if a writer is about — or the slots it tried are in
    /// use — and the reader is to be counted instead.
    @inline(always)
    @_lifetime(borrow self)
    package borrowing func _enter() -> _ReaderSlot? {
        guard word.load(ordering: .relaxed) >= 0 else {
            return nil
        }
        let identity = _identity
        var index = Self._slotIndex(lock: identity, thread: _currentThreadToken())
        let slots = unsafe _readerSlots
        for _ in 0 ..< Self._probes {
            let address = unsafe Self._slot(at: index, in: slots)
            let exchanged = unsafe address.pointee.compareExchange(
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
                    return unsafe _ReaderSlot(address, publishedIn: self)
                }
                unsafe address.pointee.store(0, ordering: .relaxed)
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
    ///
    /// An exchange rather than a store, though nothing reads the old value.
    /// Swift's reference-counting optimizer takes any store for one that
    /// cannot release an object, and moves a retain down past it; an atomic
    /// release store is no exception. A reader that copies a reference out —
    /// `withReadLock { $0 }` — then retains it after this line rather than
    /// before, with the slot already empty, and a writer that frees the old
    /// value in between leaves the reader retaining freed memory. Measured in
    /// the client's code under both Swift 6.3 and 6.4, and reproduced as a
    /// crash. A read-modify-write stops the retain where it is, as the counted
    /// path's decrement always has.
    @inline(always)
    package borrowing func _leave(_ slot: borrowing _ReaderSlot) {
        _ = unsafe slot._address.pointee.exchange(0, ordering: .releasing)
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
            let address = unsafe _slot(at: index)
            guard unsafe address.pointee.load(ordering: .sequentiallyConsistent) == identity else {
                continue
            }
            guard waiting else {
                return false
            }
            var spins = 0
            while unsafe address.pointee.load(ordering: .acquiring) == identity {
                spins &+= 1
                _backOff(after: spins)
            }
        }
        return true
    }
}

/// One slot's worth of the table: the word a reader publishes itself in,
/// followed by the padding that keeps the next slot off this one's line.
///
/// Sixteen words rather than one word and a `_slotStride`-wide alignment,
/// because a type's alignment in Swift stops at 16 bytes. Nothing is lost:
/// what keeps two slots off one line is the stride between them, not where
/// the table begins. A slot's word is the first eight bytes of its own
/// stride, and the stride is a line.
@usableFromInline
package struct _ReaderSlotLine: Sendable {
    @usableFromInline
    package var words: (
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
        UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    @usableFromInline
    package init() {}
}

/// Spelled short because the table's type names it `_slotCount` times.
@usableFromInline
package typealias _Line = _ReaderSlotLine

/// The table every lock's published readers share: `_slotCount` slots,
/// `_slotStride` bytes apart, on lines of their own.
///
/// A process-wide fixture that lives in the binary rather than on the heap.
/// Every word is zero, which is a slot's empty value, so the loader's
/// zero-filled pages are the table already set up: nothing allocates it, and
/// nothing runs to initialize it. That second part is the point — a lazily
/// initialized global is reached through an accessor that checks whether its
/// initializer has run, and this table is reached on the inlined reader path,
/// so that check was a call on every published read.
///
/// Three things about how it is written are load-bearing, and each was
/// measured against the alternative rather than chosen:
///
/// - A tuple rather than a struct wrapping one. The compiler folds a constant
///   initializer into static storage only while the global's own type is the
///   aggregate; wrapped in a struct, the `swift_once` comes back.
/// - `_slotCount` elements spelled out rather than an `InlineArray`, which
///   is unavailable below macOS 26. Once the package's deployment target
///   reaches that, the type and its value collapse to
///   `[_slotCount of _ReaderSlotLine](repeating: _ReaderSlotLine())` and
///   nothing else here changes; `UUID` keeps its storage that way.
/// - `@exclusivity(unchecked)`, because taking the table's address is a formal
///   access to a global, and two readers doing it at once would be two
///   overlapping accesses. There is nothing for the check to protect: the
///   slots are only ever read and written atomically, through the pointer,
///   which the runtime does not see either way. Without it a published read
///   calls `swift_beginAccess`, which is the call this exists to remove.
///   The tidier way to lose such a check is to move the state out of
///   whatever forces it, as one would lift a property out of a class; there
///   is no outside to move this to, one table serving every lock in the
///   process being the design rather than an accident of where it sits.
/// The table's type, named so that the layout test can ask for its size
/// without a value of it — `UUID` names its own byte tuple the same way.
@usableFromInline
package typealias _ReaderSlotTableStorage = (
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line,
    _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line, _Line
)

@exclusivity(unchecked)
@usableFromInline
nonisolated(unsafe) package var _readerSlotTable: _ReaderSlotTableStorage = (
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(),
    _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line(), _Line()
)

/// Where that table begins.
///
/// The pointer outlives the call, which is sound for this global: it is
/// statically initialized, so `&` on it yields the address of its place in
/// the binary rather than a temporary's, and that storage is the program's
/// for as long as the program runs. The language documents such a pointer as
/// one that need not be temporary, not as one that never is; a way to ask
/// for a global's address outright is proposed and not yet there, and this
/// is where it would go.
///
/// Through a pointer parameter rather than `withUnsafeMutablePointer(to:)`.
/// The two compile to the same address, but ThreadSanitizer is told of every
/// `inout` argument as a write to the whole variable, and two readers taking
/// the table's address at once were reported as racing — in a client's
/// process as much as in this package's tests. The conversion to a pointer
/// is not reported, and nothing is lost with it: the slots are reached
/// through atomic operations, which the sanitizer follows on its own.
@_transparent
@usableFromInline
package var _readerSlots: UnsafeMutableRawPointer {
    unsafe _address(ofGlobal: &_readerSlotTable)
}

/// The pointer it is given: what turns `&` on a global into its address.
@_transparent
@usableFromInline
package func _address(ofGlobal pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    unsafe pointer
}

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
///
/// wasi-libc spells `CLOCK_MONOTONIC` as the address of a constant whose
/// type it never completes, which Swift cannot import; the C target reads
/// the clock there.
@usableFromInline
internal func _now() -> Int64 {
    #if canImport(Darwin)
    return Int64(truncatingIfNeeded: mach_absolute_time())
    #elseif os(Windows)
    var counter = LARGE_INTEGER()
    _ = unsafe QueryPerformanceCounter(&counter)
    return unsafe counter.QuadPart
    #elseif os(WASI)
    return sk_rwlock_monotonic_now()
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
    #else
    _ = sched_yield()
    #endif
}
#endif
