//
//  AtomicTests.swift
//  SynchronizationKit
//

// Matches the gate on the module under test. Where `Synchronization` is
// already available — every non-Apple platform on Swift 6 — the module
// compiles out entirely and there is nothing here to exercise.
#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
import Dispatch
import Testing

@testable import SynchronizationKitAtomic

@Suite("Atomic")
struct AtomicTests {
    // MARK: - Primitive operations

    @Test("load returns the initial value")
    func loadInitial() {
        let atomic = Atomic<Int>(42)
        #expect(atomic.load(ordering: .relaxed) == 42)
        #expect(atomic.load(ordering: .acquiring) == 42)
        #expect(atomic.load(ordering: .sequentiallyConsistent) == 42)
    }

    @Test("store replaces the value")
    func store() {
        let atomic = Atomic<Int>(1)
        atomic.store(2, ordering: .relaxed)
        #expect(atomic.load(ordering: .relaxed) == 2)
        atomic.store(3, ordering: .releasing)
        #expect(atomic.load(ordering: .relaxed) == 3)
        atomic.store(4, ordering: .sequentiallyConsistent)
        #expect(atomic.load(ordering: .relaxed) == 4)
    }

    @Test("exchange returns the previous value")
    func exchange() {
        let atomic = Atomic<Int>(10)
        #expect(atomic.exchange(20, ordering: .acquiringAndReleasing) == 10)
        #expect(atomic.load(ordering: .relaxed) == 20)
    }

    @Test("compareExchange swaps only on a match")
    func compareExchange() {
        let atomic = Atomic<Int>(1)

        let hit = atomic.compareExchange(
            expected: 1, desired: 2, ordering: .sequentiallyConsistent
        )
        #expect(hit.exchanged)
        #expect(hit.original == 1)

        let miss = atomic.compareExchange(
            expected: 1, desired: 3, ordering: .sequentiallyConsistent
        )
        #expect(!miss.exchanged)
        // On failure `original` reports what was actually there.
        #expect(miss.original == 2)
        #expect(atomic.load(ordering: .relaxed) == 2)
    }

    @Test("compareExchange accepts separate success and failure orderings")
    func compareExchangeSplitOrderings() {
        let atomic = Atomic<Int>(5)

        // `releasing` success with `acquiring` failure is the combination that
        // has to be strengthened to `acquiringAndReleasing` before it reaches
        // LLVM; if that mapping were wrong this would miscompile or trap.
        let result = atomic.compareExchange(
            expected: 5,
            desired: 6,
            successOrdering: .releasing,
            failureOrdering: .acquiring
        )

        #expect(result.exchanged)
        #expect(atomic.load(ordering: .relaxed) == 6)
    }

    @Test("weakCompareExchange eventually succeeds in a retry loop")
    func weakCompareExchange() {
        let atomic = Atomic<Int>(0)
        var expected = 0

        while true {
            let result = atomic.weakCompareExchange(
                expected: expected, desired: 1, ordering: .sequentiallyConsistent
            )
            if result.exchanged { break }
            expected = result.original
        }

        #expect(atomic.load(ordering: .relaxed) == 1)
    }

    // MARK: - Integer operations

    @Test("wrapping arithmetic wraps instead of trapping")
    func wrappingArithmetic() {
        let atomic = Atomic<UInt8>(250)

        let added = atomic.wrappingAdd(10, ordering: .relaxed)
        #expect(added.oldValue == 250)
        #expect(added.newValue == 4)
        #expect(atomic.load(ordering: .relaxed) == 4)

        let subtracted = atomic.wrappingSubtract(10, ordering: .relaxed)
        #expect(subtracted.oldValue == 4)
        #expect(subtracted.newValue == 250)
    }

    @Test("bitwise operations")
    func bitwise() {
        let atomic = Atomic<UInt32>(0b1100)

        #expect(atomic.bitwiseAnd(0b1010, ordering: .relaxed).newValue == 0b1000)
        #expect(atomic.bitwiseOr(0b0011, ordering: .relaxed).newValue == 0b1011)
        #expect(atomic.bitwiseXor(0b1111, ordering: .relaxed).newValue == 0b0100)
        #expect(atomic.load(ordering: .relaxed) == 0b0100)
    }

    @Test("min and max respect signedness")
    func signedMinMax() {
        // The whole point of routing signed types through the signed shim: with
        // an unsigned comparison, -1 would read as the largest value and both
        // of these would come out backwards.
        let signed = Atomic<Int32>(-1)
        #expect(signed.min(1, ordering: .relaxed).newValue == -1)
        #expect(signed.load(ordering: .relaxed) == -1)

        let signedMax = Atomic<Int32>(-1)
        #expect(signedMax.max(1, ordering: .relaxed).newValue == 1)
        #expect(signedMax.load(ordering: .relaxed) == 1)
    }

    @Test("min and max on unsigned values compare as unsigned")
    func unsignedMinMax() {
        let atomic = Atomic<UInt32>(.max)
        #expect(atomic.min(1, ordering: .relaxed).newValue == 1)
        #expect(atomic.load(ordering: .relaxed) == 1)

        let other = Atomic<UInt32>(1)
        #expect(other.max(.max, ordering: .relaxed).newValue == .max)
    }

    @Test("checked add and subtract report old and new values")
    func checkedArithmetic() {
        let atomic = Atomic<Int>(10)

        let added = atomic.add(5, ordering: .sequentiallyConsistent)
        #expect(added.oldValue == 10)
        #expect(added.newValue == 15)

        let subtracted = atomic.subtract(3, ordering: .sequentiallyConsistent)
        #expect(subtracted.oldValue == 15)
        #expect(subtracted.newValue == 12)
        #expect(atomic.load(ordering: .relaxed) == 12)
    }

    // MARK: - Other representations

    @Test("Bool logical operations")
    func boolLogical() {
        let atomic = Atomic<Bool>(true)

        #expect(atomic.logicalAnd(false, ordering: .relaxed).newValue == false)
        #expect(atomic.logicalOr(true, ordering: .relaxed).newValue == true)
        #expect(atomic.logicalXor(true, ordering: .relaxed).newValue == false)
        #expect(atomic.load(ordering: .relaxed) == false)
    }

    @Test("RawRepresentable enums conform for free")
    func rawRepresentable() {
        enum TrafficLight: UInt8, AtomicRepresentable {
            case red, yellow, green
        }

        let atomic = Atomic<TrafficLight>(.red)
        #expect(atomic.load(ordering: .relaxed) == .red)

        atomic.store(.green, ordering: .relaxed)
        #expect(atomic.load(ordering: .relaxed) == .green)

        let result = atomic.compareExchange(
            expected: .green, desired: .yellow, ordering: .relaxed
        )
        #expect(result.exchanged)
        #expect(atomic.load(ordering: .relaxed) == .yellow)
    }

    @Test("pointers round-trip through atomic storage")
    func pointers() {
        let buffer = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        defer { unsafe buffer.deallocate() }
        unsafe buffer.initialize(repeating: 0, count: 2)

        let atomic = unsafe Atomic<UnsafeMutablePointer<Int>>(buffer)
        #expect(unsafe atomic.load(ordering: .relaxed) == buffer)

        let next = unsafe buffer.advanced(by: 1)
        unsafe atomic.store(next, ordering: .relaxed)
        #expect(unsafe atomic.load(ordering: .relaxed) == next)
    }

    @Test("optional pointers round-trip, nil included")
    func optionalPointers() {
        let buffer = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { unsafe buffer.deallocate() }
        unsafe buffer.initialize(to: 0)

        let atomic = unsafe Atomic<UnsafeMutablePointer<Int>?>(nil)
        #expect(unsafe atomic.load(ordering: .relaxed) == nil)

        unsafe atomic.store(buffer, ordering: .relaxed)
        #expect(unsafe atomic.load(ordering: .relaxed) == buffer)

        // Back to nil: the zero pattern has to decode as absence, not as a
        // pointer to address zero.
        unsafe atomic.store(nil, ordering: .relaxed)
        #expect(unsafe atomic.load(ordering: .relaxed) == nil)
    }

    @Test("an optional atomic claims an empty slot exactly once")
    func optionalPointerClaim() {
        let buffer = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { unsafe buffer.deallocate() }
        unsafe buffer.initialize(to: 0)

        // The idiom the optional conformance exists for: a slot that starts
        // empty, which exactly one writer gets to fill.
        let slot = unsafe Atomic<UnsafeMutablePointer<Int>?>(nil)

        let first = unsafe slot.compareExchange(
            expected: nil, desired: buffer, ordering: .acquiringAndReleasing
        )
        #expect(unsafe first.exchanged)
        #expect(unsafe first.original == nil)

        let second = unsafe slot.compareExchange(
            expected: nil, desired: buffer, ordering: .acquiringAndReleasing
        )
        #expect(unsafe !second.exchanged)
        #expect(unsafe second.original == buffer)
    }

    @Test("optional object identifiers and unmanaged references round-trip")
    func optionalReferences() {
        final class Box {}
        let box = Box()

        let identifier = Atomic<ObjectIdentifier?>(nil)
        #expect(identifier.load(ordering: .relaxed) == nil)
        identifier.store(ObjectIdentifier(box), ordering: .relaxed)
        #expect(identifier.load(ordering: .relaxed) == ObjectIdentifier(box))

        let unmanaged = unsafe Atomic<Unmanaged<Box>?>(nil)
        #expect(unsafe unmanaged.load(ordering: .relaxed) == nil)
        unsafe unmanaged.store(.passUnretained(box), ordering: .relaxed)
        #expect(
            unsafe unmanaged.load(ordering: .relaxed)?.takeUnretainedValue()
                === box
        )
    }

    @Test("optional opaque pointers round-trip")
    func optionalOpaquePointers() {
        let buffer = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { unsafe buffer.deallocate() }
        unsafe buffer.initialize(to: 0)

        let atomic = unsafe Atomic<OpaquePointer?>(nil)
        #expect(unsafe atomic.load(ordering: .relaxed) == nil)

        let pointer = OpaquePointer(buffer)
        unsafe atomic.store(pointer, ordering: .relaxed)
        #expect(unsafe atomic.load(ordering: .relaxed) == pointer)
    }

    @Test("every integer width round-trips its extremes")
    func integerWidths() {
        #expect(Atomic<Int8>(.min).load(ordering: .relaxed) == .min)
        #expect(Atomic<Int16>(.min).load(ordering: .relaxed) == .min)
        #expect(Atomic<Int32>(.min).load(ordering: .relaxed) == .min)
        #expect(Atomic<Int64>(.min).load(ordering: .relaxed) == .min)
        #expect(Atomic<Int>(.min).load(ordering: .relaxed) == .min)

        #expect(Atomic<UInt8>(.max).load(ordering: .relaxed) == .max)
        #expect(Atomic<UInt16>(.max).load(ordering: .relaxed) == .max)
        #expect(Atomic<UInt32>(.max).load(ordering: .relaxed) == .max)
        #expect(Atomic<UInt64>(.max).load(ordering: .relaxed) == .max)
        #expect(Atomic<UInt>(.max).load(ordering: .relaxed) == .max)
    }

    // MARK: - Layout and concurrency

    @Test("stores its value inline rather than in a heap box")
    func inlineStorage() {
        #expect(MemoryLayout<Atomic<Int8>>.size == 1)
        #expect(MemoryLayout<Atomic<Int16>>.size == 2)
        #expect(MemoryLayout<Atomic<Int32>>.size == 4)
        #expect(MemoryLayout<Atomic<Int64>>.size == 8)
        #expect(MemoryLayout<Atomic<Int64>>.alignment == 8)
        #expect(MemoryLayout<Atomic<Int>>.size == MemoryLayout<Int>.size)
    }

    @Test("an optional value costs no more storage than a non-optional one")
    func optionalInlineStorage() {
        // `nil` rides in the null bit pattern rather than in a separate tag
        // byte, so wrapping in `Optional` has to leave the width alone.
        #expect(
            unsafe MemoryLayout<Atomic<UnsafeMutableRawPointer?>>.size
                == MemoryLayout<Atomic<UnsafeMutableRawPointer>>.size
        )
        #expect(
            unsafe MemoryLayout<Atomic<UnsafeMutableRawPointer?>>.size
                == MemoryLayout<UnsafeMutableRawPointer>.size
        )
    }

    @Test("wrappingAdd is atomic under contention")
    func contendedIncrement() {
        let counter = Atomic<Int>(0)
        let iterations = 50_000
        let threads = 8

        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0 ..< iterations {
                counter.wrappingAdd(1, ordering: .relaxed)
            }
        }

        #expect(counter.load(ordering: .sequentiallyConsistent) == iterations * threads)
    }

    @Test("compareExchange is atomic under contention")
    func contendedCompareExchange() {
        let counter = Atomic<Int>(0)
        let iterations = 20_000
        let threads = 8

        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0 ..< iterations {
                var current = counter.load(ordering: .relaxed)
                while true {
                    let result = counter.compareExchange(
                        expected: current,
                        desired: current + 1,
                        ordering: .acquiringAndReleasing
                    )
                    if result.exchanged { break }
                    current = result.original
                }
            }
        }

        #expect(counter.load(ordering: .sequentiallyConsistent) == iterations * threads)
    }
}
#endif
