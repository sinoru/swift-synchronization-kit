//
//  UmbrellaTests.swift
//  SynchronizationKit
//

import Testing

import SynchronizationKit

// The only place a client's view of the sole product is compiled. Drop
// `@_exported` from the umbrella and the package still builds — the re-exports
// are for consumers, and the package has no other consumer of its own — while
// a client can no longer see any of the types it advertises.
//
// The compiler does say something in that case: three "public import ... was
// not used" warnings, since the umbrella declares nothing of its own. But that
// only catches losing the re-export outright. Narrowing one to a scope that
// omits a type — which is the shape these imports take a level down — leaves
// no warning behind, and this file is what would notice.
//
// Gated on traits rather than on platform: a trait drops the umbrella's
// dependency on the target, so with `Mutex` off there is no `Mutex` to name,
// whereas platform is what this file must not be gated on.
@Suite("Umbrella")
struct UmbrellaTests {
    @Test("the enabled traits' types arrive through the umbrella")
    func typesArrive() {
        // Compiling is the assertion; there is nothing to check at run time
        // that the per-module suites do not already check. Each line names a
        // type and calls a member, because those travel by different rules and
        // only the second has ever broken here — a type alias carried the name
        // across and left `withLock` behind. Off Apple this is also the longest
        // chain in the package: umbrella, then the module, then a scoped
        // re-export of the standard library's own.
        #if Atomic
        _ = Atomic<Int>(0).load(ordering: .relaxed)
        #endif
        #if Mutex
        _ = Mutex(0).withLock { $0 }
        #endif
        #if RWLock
        _ = RWLock(0).withReadLock { $0 }
        #endif
    }
}
