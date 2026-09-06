//
//  Deadline.swift
//  SynchronizationKit
//

// The asynchronous counterpart of `expectSignal`: a bound on how long a body
// may take, reported as a failure rather than waited out. Guarded on
// `Testing` for the reason `Threads.swift` gives.
#if canImport(Testing)
package import Testing

/// Runs `body`, failing rather than hanging if it has not returned within
/// `seconds`.
///
/// A lost wake in an asynchronous lock leaves a task suspended forever, and
/// a test that awaits that task hangs with it until the job timeout. `.timeLimit`
/// would bound this once for a whole suite, but it needs iOS 16 and watchOS 9
/// and this package deploys below both, so the bound is applied by hand.
///
/// The body runs in a task of its own and races a watchdog; whichever
/// finishes first decides the outcome, and the other is cancelled and never
/// awaited. Not a task group, whose scope waits for every child: a body
/// that cannot be freed even by cancellation — a waiter granted the lock and
/// then never resumed, say, which the cancellation handler rightly leaves
/// alone — would hold the run to the job timeout from inside one. Left
/// unawaited it holds a task until the process exits, and the failure is
/// reported. The body's own error, if it throws first, is rethrown.
package func expectCompletion(
    within seconds: Double = 120,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> Void
) async throws {
    enum Outcome: Sendable {
        case finished(Result<Void, any Error>)
        case timedOut
    }

    // A one-shot channel both sides write to; the first write is the one
    // read, and a second, if one ever arrives, sits in the buffer unread.
    let (outcomes, report) = AsyncStream<Outcome>.makeStream()

    let work = Task { @Sendable in
        do {
            try await body()
            report.yield(.finished(.success(())))
        } catch {
            report.yield(.finished(.failure(error)))
        }
    }
    let watchdog = Task { @Sendable in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if !Task.isCancelled {
            report.yield(.timedOut)
        }
    }

    var first: Outcome?
    for await outcome in outcomes {
        first = outcome
        break
    }

    switch first {
    case .finished(.success):
        watchdog.cancel()
    case .finished(.failure(let error)):
        watchdog.cancel()
        throw error
    case .timedOut, nil:
        work.cancel()
        Issue.record(
            comment ?? "timed out waiting for the body to complete",
            sourceLocation: sourceLocation
        )
    }
}

/// Runs `drive` and then awaits every one of `workers`, failing rather than
/// hanging if the lot has not finished within `seconds`.
///
/// For a stress test whose workers are unstructured tasks — so that some of
/// them can be cancelled one at a time, which a group's children cannot be.
/// Being unstructured, nothing cancels them when the deadline does, so this
/// does: a worker still suspended on the primitive under test then leaves
/// its queue and returns, and the failure is reported rather than waited
/// out. `drive` is where the test cancels workers of its own choosing.
package func expectCompletion(
    of workers: [Task<Void, any Error>],
    within seconds: Double = 120,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    driving drive: @escaping @Sendable () async throws -> Void = {}
) async throws {
    try await expectCompletion(within: seconds, comment, sourceLocation: sourceLocation) {
        try await withTaskCancellationHandler {
            try await drive()
            for worker in workers {
                try await worker.value
            }
        } onCancel: {
            for worker in workers {
                worker.cancel()
            }
        }
    }
}
#endif
