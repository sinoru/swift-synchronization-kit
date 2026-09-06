//
//  SynchronizationKitTestUtils.swift
//  SynchronizationKit
//

// Helpers shared by the test targets. A `package` target rather than a test
// target because SwiftPM has no way for one test target to import another.
// What it reaches in the primitives is declared `package` for it.
//
// The synchronous suites take the environment globals; the asynchronous ones
// also take the gate, the polling loop, and the queue-watching extensions.
//
// A note that applies to every suite using these: spell out `@Sendable` on
// each `Task { }`. The lock under test is often a local `let`, and on Swift
// 6.2 and 6.3 the region checker treats a local of a `@_staticExclusiveOnly`
// type captured by a `sending` closure as though the closure carried the
// local off with it, so a second closure capturing the same lock is rejected
// as a concurrent access — the standard library's own `Mutex` gets the same
// diagnosis there. A `@Sendable` closure is checked by capture instead and
// passes; Swift 6.4 accepts both. Real code keeps such a lock in a class, an
// actor, or a global, which is unaffected.
