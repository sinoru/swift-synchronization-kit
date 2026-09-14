//
//  HoldRecord.swift
//  SynchronizationKit
//

// Where the calling code is built with assertions enabled, `RWLock` keeps a
// record of the locks each thread holds, and traps as soon as a thread asks
// for one it already holds, in either mode. That catches what the lock
// itself cannot: a read inside a read section, which waits forever only when
// a writer arrives in between, and a write inside one, which the lock cannot
// tell from any other writer waiting out its readers. In a debug build the
// mistake then shows the first time the code runs, rather than the first
// time it runs under contention.
//
// The locking methods ask `_isDebugAssertConfiguration()`, through the
// `_debug` helpers below, and the question is answered where they are
// inlined — in the caller's module, by the caller's build — so a release
// build compiles it, and the calls behind it, away. A hold recorded by one
// module and asked about from another is still found, and a hold taken by
// code built without the record is simply not on it: a lookup finds holds
// that are real, or finds nothing.
//
// The helpers ask it with a `switch` rather than an `if`, and that is
// measured, not taste. This module's own release build emits a copy of each
// method and helper, folds the question to false in it, and warns that the
// call behind an `if` or a `guard` will never be executed — in the helper, or
// at every locking method if the question is asked there. A `switch` over the
// same answer folds the same way and draws no warning, under Swift 6.3.3 and
// 6.4 alike. A client's module is warned about none of them: what it inlines
// from here carries no locations the warning is issued for.
//
// The record is C's thread-local storage, on the platforms where that is
// established here. The fallback backend's targets have none to offer, and
// WASI's, with or without threads, is not verified; there the methods below
// do nothing.
#if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows)
import CSynchronizationKitRWLock
#endif

/// How a thread holds an `RWLock`, as the record keeps it.
///
/// `package` for the `@inline(always)` helpers that take it, which are
/// `package` themselves, and `@usableFromInline` for the locking methods that
/// name its cases, which are public and inline into their callers.
@usableFromInline
package enum _HoldKind: Int32 {
    case read = 1
    case write = 2
}

extension RWLock where Value: ~Copyable {
    /// `_recordHoldChecking`, where the caller is built with assertions
    /// enabled.
    @inline(always)
    package borrowing func _debugRecordHoldChecking(_ kind: _HoldKind) {
        switch _isDebugAssertConfiguration() {
        case true:
            _recordHoldChecking(kind)
        case false:
            break
        }
    }

    /// `_recordHold`, where the caller is built with assertions enabled.
    @inline(always)
    package borrowing func _debugRecordHold(_ kind: _HoldKind) {
        switch _isDebugAssertConfiguration() {
        case true:
            _recordHold(kind)
        case false:
            break
        }
    }

    /// `_forgetHold`, where the caller is built with assertions enabled.
    @inline(always)
    package borrowing func _debugForgetHold() {
        switch _isDebugAssertConfiguration() {
        case true:
            _forgetHold()
        case false:
            break
        }
    }

    /// Traps if the calling thread holds this lock already, in either mode,
    /// and records it as holding the lock for `kind` otherwise.
    ///
    /// For the methods that wait. Called before the lock is taken, so that
    /// a thread about to wait on itself traps rather than waits.
    @usableFromInline
    internal borrowing func _recordHoldChecking(_ kind: _HoldKind) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows)
        let identity = handle.bias._identity
        switch _HoldKind(rawValue: sk_rwlock_hold_find(identity)) {
        case nil:
            break
        case .read:
            preconditionFailure(
                kind == .read
                    ? "RWLock read-locked again by the thread holding it for reading"
                    : "RWLock write-locked by the thread holding it for reading"
            )
        case .write:
            preconditionFailure(
                kind == .read
                    ? "RWLock read-locked by the thread holding it for writing"
                    : "RWLock write-locked again by the thread holding it for writing"
            )
        }
        sk_rwlock_hold_push(identity, kind.rawValue)
        #endif
    }

    /// Records the calling thread as holding this lock for `kind`, without
    /// asking whether it did already.
    ///
    /// For the methods that never wait, once they have the lock. One of
    /// those cannot wait on itself; a read taken this way inside a read
    /// section is let through, as the lock lets it through, and is recorded
    /// so that the balance of the record holds.
    @usableFromInline
    internal borrowing func _recordHold(_ kind: _HoldKind) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows)
        sk_rwlock_hold_push(handle.bias._identity, kind.rawValue)
        #endif
    }

    /// Forgets the hold the calling thread recorded last, which the section
    /// ending is the one to have recorded.
    @usableFromInline
    internal borrowing func _forgetHold() {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Android) || canImport(Musl) || os(Windows)
        sk_rwlock_hold_pop()
        #endif
    }
}
