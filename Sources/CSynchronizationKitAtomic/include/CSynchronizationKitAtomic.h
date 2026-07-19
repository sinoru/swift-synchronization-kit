// Atomic operations for `Atomic`.
//
// The standard library reaches for `Builtin.atomicrmw_*` here, which is only
// available to the stdlib itself. This shim reaches the same LLVM instructions
// through Clang's `__atomic_*` builtins instead.
//
// Two things make that a faithful substitute rather than a compromise:
//
// 1. The builtins accept a *runtime* memory ordering. Whenever the caller's
//    ordering is a compile-time constant — which it is at every ordinary call
//    site — Clang folds the operation down to a single instruction, matching
//    what the stdlib's constant-ordering-only builtins emit. So the Swift side
//    needs no per-ordering dispatch at all; it forwards its ordering's raw
//    value, which is defined to be the matching `__ATOMIC_*` constant.
//
// 2. Signedness of the operand selects `min`/`max` versus `umin`/`umax`, the
//    same mapping the stdlib spells out by hand in `atomicOperationName()`.
//
// Pointers arrive as `void *` so the Clang importer never has to render an
// `_Atomic`-qualified type into Swift. Callers guarantee suitable alignment;
// on the Swift side that comes from `@_rawLayout(like:)`.

#ifndef C_SYNCHRONIZATION_KIT_ATOMIC_H
#define C_SYNCHRONIZATION_KIT_ATOMIC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

// Every width below must lower to a real instruction. If a target ever fails
// this, the operation would silently degrade to a libatomic lock, which would
// make `Atomic` neither lock-free nor usable from a signal handler.
_Static_assert(__atomic_always_lock_free(1, 0), "1-byte atomics are not lock-free");
_Static_assert(__atomic_always_lock_free(2, 0), "2-byte atomics are not lock-free");
_Static_assert(__atomic_always_lock_free(4, 0), "4-byte atomics are not lock-free");
_Static_assert(__atomic_always_lock_free(8, 0), "8-byte atomics are not lock-free");

#define SK_SHIM static inline __attribute__((always_inline))

/// Operations whose result is independent of how the operand's bits are
/// interpreted, so one unsigned-typed entry point serves both signednesses.
#define SK_ATOMIC_COMMON_OPS(suffix, type)                                     \
    SK_SHIM type sk_atomic_load_##suffix(void *ptr, int ordering) {            \
        return __atomic_load_n((type *)ptr, ordering);                         \
    }                                                                          \
                                                                               \
    SK_SHIM void sk_atomic_store_##suffix(                                     \
        void *ptr, type desired, int ordering                                  \
    ) {                                                                        \
        __atomic_store_n((type *)ptr, desired, ordering);                      \
    }                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_exchange_##suffix(                                  \
        void *ptr, type desired, int ordering                                  \
    ) {                                                                        \
        return __atomic_exchange_n((type *)ptr, desired, ordering);            \
    }                                                                          \
                                                                               \
    SK_SHIM bool sk_atomic_compare_exchange_##suffix(                          \
        void *ptr, type *expected, type desired, bool weak,                    \
        int successOrdering, int failureOrdering                               \
    ) {                                                                        \
        return __atomic_compare_exchange_n(                                    \
            (type *)ptr, expected, desired, weak,                              \
            successOrdering, failureOrdering                                   \
        );                                                                     \
    }                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_add_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) {                                                                        \
        return __atomic_fetch_add((type *)ptr, operand, ordering);             \
    }                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_sub_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) {                                                                        \
        return __atomic_fetch_sub((type *)ptr, operand, ordering);             \
    }                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_and_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) {                                                                        \
        return __atomic_fetch_and((type *)ptr, operand, ordering);             \
    }                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_or_##suffix(                                  \
        void *ptr, type operand, int ordering                                  \
    ) {                                                                        \
        return __atomic_fetch_or((type *)ptr, operand, ordering);              \
    }                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_xor_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) {                                                                        \
        return __atomic_fetch_xor((type *)ptr, operand, ordering);             \
    }

/// Minimum and maximum are the only operations that read the operand's sign,
/// so they need one entry point per signedness.
#define SK_ATOMIC_MINMAX_OPS(suffix, type)                                     \
    SK_SHIM type sk_atomic_fetch_min_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) {                                                                        \
        return __atomic_fetch_min((type *)ptr, operand, ordering);             \
    }                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_max_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) {                                                                        \
        return __atomic_fetch_max((type *)ptr, operand, ordering);             \
    }

SK_ATOMIC_COMMON_OPS(u8, uint8_t)
SK_ATOMIC_COMMON_OPS(u16, uint16_t)
SK_ATOMIC_COMMON_OPS(u32, uint32_t)
SK_ATOMIC_COMMON_OPS(u64, uint64_t)

SK_ATOMIC_MINMAX_OPS(u8, uint8_t)
SK_ATOMIC_MINMAX_OPS(u16, uint16_t)
SK_ATOMIC_MINMAX_OPS(u32, uint32_t)
SK_ATOMIC_MINMAX_OPS(u64, uint64_t)

SK_ATOMIC_MINMAX_OPS(i8, int8_t)
SK_ATOMIC_MINMAX_OPS(i16, int16_t)
SK_ATOMIC_MINMAX_OPS(i32, int32_t)
SK_ATOMIC_MINMAX_OPS(i64, int64_t)

#undef SK_ATOMIC_COMMON_OPS
#undef SK_ATOMIC_MINMAX_OPS
#undef SK_SHIM

#pragma clang assume_nonnull end

#endif // C_SYNCHRONIZATION_KIT_ATOMIC_H
