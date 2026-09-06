# ``SynchronizationKitAtomic``

Lock-free atomic storage for booleans, integers, pointers, and any type that
maps onto a machine word, with explicit memory orderings.

## Overview

``Atomic`` holds a single value that several threads may read and update at
once without tearing or losing writes. Every operation names the memory
ordering it applies, which controls what a *neighbouring* access is allowed to
observe; the atomicity of the access itself is never in question.

```swift
let counter = Atomic<Int>(0)

counter.add(1, ordering: .relaxed)
let current = counter.load(ordering: .relaxed)
```

The value is stored inline, so an `Atomic<Int64>` occupies eight bytes and
performs no allocation. A type of your own becomes atomic by adopting
``AtomicRepresentable``, which asks only how to convert it to and from one of
the fixed widths the hardware can address atomically.

This module matches the standard library's `Synchronization` module name for
name. Once your deployment target reaches the OS versions that ship it, the
types here are deprecated in favour of the standard library's, and migrating is
a matter of changing an import. On non-Apple platforms they already are the
standard library's own, re-exported.

## Topics

### Atomic Storage

- ``Atomic``

### Memory Orderings

- ``AtomicLoadOrdering``
- ``AtomicStoreOrdering``
- ``AtomicUpdateOrdering``

### Making a Type Atomic

- ``AtomicRepresentable``
- ``AtomicOptionalRepresentable``
