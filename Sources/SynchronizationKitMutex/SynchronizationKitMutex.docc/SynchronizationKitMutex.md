# ``SynchronizationKitMutex``

A lock that owns the value it protects, back-deployed from the standard
library's `Synchronization` module.

## Overview

``Mutex`` grants exclusive access to its value through `withLock`, and its
non-blocking variant `withLockIfAvailable`. The value is reachable only from
inside those methods, so there is no way to touch it without holding the lock.

```swift
let counters = Mutex<[String: Int]>([:])

counters.withLock { $0["requests", default: 0] += 1 }
```

The lock and the value are stored inline, so a `Mutex` can be a `let` on a
class or a global with no allocation of its own. On Darwin it is backed by
`os_unfair_lock`, matching the standard library's implementation down to the
primitive.

This module matches the standard library's `Mutex` name for name, so once your
deployment target reaches the OS versions that ship `Synchronization`,
migrating is a matter of changing an import. On non-Apple platforms it already
is the standard library's own, re-exported.

## Topics

### Locks

- ``Mutex``
