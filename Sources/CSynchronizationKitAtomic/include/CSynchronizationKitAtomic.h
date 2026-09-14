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
// 2. Signedness of the operand selects `min`/`max` versus `umin`/`umax`, which
//    is what SE-0410 defines those operations to mean. The stdlib's generator
//    writes that same mapping and never reaches it — it tests one spelling of
//    the operation name and is handed another — so it emits the signed form for
//    unsigned types too. Faithful to the proposal, then, and deliberately not
//    to that. See swiftlang/swift#91176.
//
// Pointers arrive as `void *` so the Clang importer never has to render an
// `_Atomic`-qualified type into Swift. Callers guarantee suitable alignment;
// on the Swift side that comes from `@_rawLayout(like:)`.

#ifndef C_SYNCHRONIZATION_KIT_ATOMIC_H
#define C_SYNCHRONIZATION_KIT_ATOMIC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// How each entry point below is spelled, which is decided once for the whole
// header.
//
// Ordinarily every one is an always-inline definition, so that Swift emits it
// at the call site for the client's own deployment target. Swift 6.3 has one
// build in which that is unsafe: under compilation caching, the Clang module
// this header becomes is built for the SDK's triple rather than the deployment
// target — which is intended, and why `__ARM_FEATURE_ATOMICS` below reads as
// set — but IRGen then takes that module's CPU for the code it emits from it
// too, which is the bug. On an iPhone or Apple TV that SDK CPU has the
// single-instruction atomics while the oldest supported devices do not, so an
// inlined operation traps on them. Swift 6.4 builds the code for the
// deployment target again; see swiftlang/swift#90380.
//
// Nothing tells a header that caching is on, but its precondition is visible
// here: a Swift import for an iPhone or Apple TV device whose Clang module
// claims the instructions. Where that holds under a Swift older than 6.4, the
// entry points are only declared, and `shim.c` defines them — compiled by
// Clang for the package's own minimum deployment target, which no device
// predates. The precondition is broader than the bug. Explicitly built
// modules, which Xcode uses whether or not caching is on, build the Clang
// module for the SDK's triple too, and emit correct code from it, but the
// header sees the same macros either way and cannot tell the two apart. So
// under 6.3 every such build pays a call per operation, as does a deployment
// target whose devices all have the instructions. A Swift that does not report
// its version is taken to be an affected one. Prerelease 6.4 compilers from
// before the fix count as fixed.
//
// Remove the second branch, `SK_ATOMIC_OUTLINE_PLATFORM`, and the definitions
// in `shim.c` once the package's minimum toolchain is 6.4.
#if defined(__APPLE__) && __has_include(<TargetConditionals.h>)
#include <TargetConditionals.h>
#define SK_ATOMIC_OUTLINE_PLATFORM                                             \
    ((TARGET_OS_IOS || TARGET_OS_TV)                                           \
     && !TARGET_OS_MACCATALYST && !TARGET_OS_SIMULATOR)
#else
#define SK_ATOMIC_OUTLINE_PLATFORM 0
#endif

#if defined(SK_ATOMIC_DEFINE_OUTLINED) && SK_ATOMIC_OUTLINE_PLATFORM
// `shim.c`: the out-of-line definitions.
#define SK_SHIM
#define SK_BODY(...) { __VA_ARGS__ }
#elif defined(__swift__) && SK_ATOMIC_OUTLINE_PLATFORM                         \
    && defined(__ARM_FEATURE_ATOMICS)                                          \
    && (!defined(__SWIFT_COMPILER_VERSION)                                     \
        || __SWIFT_COMPILER_VERSION < 6004000000000LL)
// A Swift import that would miscompile an inline body: declarations only.
#define SK_SHIM extern
#define SK_BODY(...) ;
#else
#define SK_SHIM static inline __attribute__((always_inline))
#define SK_BODY(...) { __VA_ARGS__ }
#endif

// C linkage even when the importer parses this as C++, as Swift's C++
// interoperability does. The inline definitions would not care, but the
// declarations above are satisfied by `shim.c`, which is compiled as C.
#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

// Every width below must lower to a real instruction. If a target ever fails
// this, the operation would silently degrade to a libatomic lock, which would
// make `Atomic` neither lock-free nor usable from a signal handler.
_Static_assert(__atomic_always_lock_free(1, 0), "1-byte atomics are not lock-free");
_Static_assert(__atomic_always_lock_free(2, 0), "2-byte atomics are not lock-free");
_Static_assert(__atomic_always_lock_free(4, 0), "4-byte atomics are not lock-free");
_Static_assert(__atomic_always_lock_free(8, 0), "8-byte atomics are not lock-free");

/// Operations whose result is independent of how the operand's bits are
/// interpreted, so one unsigned-typed entry point serves both signednesses.
#define SK_ATOMIC_COMMON_OPS(suffix, type)                                     \
    SK_SHIM type sk_atomic_load_##suffix(void *ptr, int ordering) SK_BODY(     \
        return __atomic_load_n((type *)ptr, ordering);                         \
    )                                                                          \
                                                                               \
    SK_SHIM void sk_atomic_store_##suffix(                                     \
        void *ptr, type desired, int ordering                                  \
    ) SK_BODY(                                                                 \
        __atomic_store_n((type *)ptr, desired, ordering);                      \
    )                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_exchange_##suffix(                                  \
        void *ptr, type desired, int ordering                                  \
    ) SK_BODY(                                                                 \
        return __atomic_exchange_n((type *)ptr, desired, ordering);            \
    )                                                                          \
                                                                               \
    SK_SHIM bool sk_atomic_compare_exchange_##suffix(                          \
        void *ptr, type *expected, type desired, bool weak,                    \
        int successOrdering, int failureOrdering                               \
    ) SK_BODY(                                                                 \
        return __atomic_compare_exchange_n(                                    \
            (type *)ptr, expected, desired, weak,                              \
            successOrdering, failureOrdering                                   \
        );                                                                     \
    )                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_add_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) SK_BODY(                                                                 \
        return __atomic_fetch_add((type *)ptr, operand, ordering);             \
    )                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_sub_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) SK_BODY(                                                                 \
        return __atomic_fetch_sub((type *)ptr, operand, ordering);             \
    )                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_and_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) SK_BODY(                                                                 \
        return __atomic_fetch_and((type *)ptr, operand, ordering);             \
    )                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_or_##suffix(                                  \
        void *ptr, type operand, int ordering                                  \
    ) SK_BODY(                                                                 \
        return __atomic_fetch_or((type *)ptr, operand, ordering);              \
    )                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_xor_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) SK_BODY(                                                                 \
        return __atomic_fetch_xor((type *)ptr, operand, ordering);             \
    )

/// Minimum and maximum are the only operations that read the operand's sign,
/// so they need one entry point per signedness.
#define SK_ATOMIC_MINMAX_OPS(suffix, type)                                     \
    SK_SHIM type sk_atomic_fetch_min_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) SK_BODY(                                                                 \
        return __atomic_fetch_min((type *)ptr, operand, ordering);             \
    )                                                                          \
                                                                               \
    SK_SHIM type sk_atomic_fetch_max_##suffix(                                 \
        void *ptr, type operand, int ordering                                  \
    ) SK_BODY(                                                                 \
        return __atomic_fetch_max((type *)ptr, operand, ordering);             \
    )

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
#undef SK_BODY
#undef SK_ATOMIC_OUTLINE_PLATFORM

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif // C_SYNCHRONIZATION_KIT_ATOMIC_H
