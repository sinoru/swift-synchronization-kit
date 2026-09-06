//
//  Stress.swift
//  SynchronizationKit
//

// What the stress suites agree about: how hard to push, how many workers to
// push with, and where their randomness comes from.
//
// A stress suite differs from the rest in what it is looking for. The other
// suites each set up one interleaving and check what the primitive does with
// it; a stress suite sets up as many interleavings as it can and checks that
// an invariant survives every one of them. Its value is therefore in how many
// it gets through, which is a dial rather than a fact, and the dial is here.

/// How many times over the stress suites repeat their work.
///
/// One under a plain `swift test`: enough to exercise every path, quick
/// enough that a local run is not slowed by it. Building with
/// `-Xswiftc -DSYNCHRONIZATIONKIT_LONG_TESTS` raises it fiftyfold, to where
/// the stress suites take some ten seconds on a four-core runner, which is
/// what CI does on every push: what these find, a wake lost in one
/// interleaving out of many, is what a change to a lock's wait or wake path
/// most needs found before it merges. Fifty rather than more because the
/// cost is not even across platforms: a handoff through a Linux futex on a
/// runner's four cores takes tens of microseconds, and the same factor that
/// costs seconds on macOS cost minutes there.
///
/// A compile-time flag rather than an environment variable, as swift-atomics
/// does with `SWIFT_ATOMICS_LONG_TESTS`: it costs nothing to read, and it
/// needs no `ProcessInfo` on the platforms that build this target without a
/// full Foundation.
///
/// Under ThreadSanitizer the long factor is a tenth of that. The sanitizer
/// slows every operation by about that much on its own, so the two take the
/// same time on the clock; and what it is there to find — an access it can
/// see is unordered — it finds in the first few thousand interleavings or
/// not at all.
#if SYNCHRONIZATIONKIT_LONG_TESTS
public let stressScale = threadSanitizerIsLoaded ? 5 : 50
#else
public let stressScale = 1
#endif

/// The worker counts the stress suites run their matrix over: one, so the
/// uncontended path is covered too, then doubling past the core count of any
/// CI runner, so the last rows always have more workers than places to run.
public let stressWorkerCounts = [1, 2, 4, 8, 16]

/// A seeded generator, so a run that fails can be run again.
///
/// The stress suites randomize dwell times, which operation to try, and when
/// to cancel. `SystemRandomNumberGenerator` would give each run a different
/// sequence and a failure no way back to the one that produced it; this gives
/// each worker its own reproducible stream from a seed the test picks.
///
/// SplitMix64: a 64-bit state, one addition, three xor-shift-multiply
/// rounds. Not a quality the tests depend on, only a sequence they can
/// replay.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
