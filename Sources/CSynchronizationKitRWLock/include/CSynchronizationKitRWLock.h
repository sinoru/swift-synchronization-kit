// The record of which `RWLock`s the calling thread holds, kept for builds
// with assertions enabled.
//
// It is thread-local, and has to be C's: Swift has no thread-local storage of
// its own, and a task local is no substitute. A task created inside a locked
// section inherits a copy of the section's bindings, and would carry its
// holds into code that runs on another thread after the section has ended.
//
// A hold is recorded on the way into a section and forgotten on the way out,
// by the same inlined body, so the record is a stack: sections nest, and
// `RWLock`'s closures cannot suspend and resume on another thread in between.
//
// On a target without thread-local storage the functions do nothing, and
// report no holds; `shim.c` asks the compiler which targets those are.

#ifndef C_SYNCHRONIZATION_KIT_RWLOCK_H
#define C_SYNCHRONIZATION_KIT_RWLOCK_H

#include <stdint.h>

/// Records that the calling thread has taken `lock` as `kind`, a nonzero value
/// of the caller's choosing.
extern void sk_rwlock_hold_push(uintptr_t lock, int kind);

/// Forgets the hold the calling thread recorded last.
extern void sk_rwlock_hold_pop(void);

/// The kind of the calling thread's most recently recorded hold of `lock`, or
/// zero if it has none on record.
extern int sk_rwlock_hold_find(uintptr_t lock);

#if defined(__wasi__)
/// The monotonic clock, in nanoseconds, for the reader bias's deadlines.
///
/// wasi-libc defines `CLOCK_MONOTONIC` as the address of a constant of a
/// type it never completes, which Swift cannot import; C can name it.
extern int64_t sk_rwlock_monotonic_now(void);
#endif

#endif // C_SYNCHRONIZATION_KIT_RWLOCK_H
