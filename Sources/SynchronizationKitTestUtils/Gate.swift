//
//  Gate.swift
//  SynchronizationKit
//

/// A one-shot signal: `wait()` suspends until `open()` has been called.
///
/// Built on `AsyncStream` rather than on one of the package's own primitives,
/// so the tests of those primitives do not lean on what they test.
package struct Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    package init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    package func open() {
        continuation.yield(())
        continuation.finish()
    }

    package func wait() async {
        for await _ in stream {
            return
        }
    }
}
