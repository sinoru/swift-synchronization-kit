// Everything this target exposes is an always-inline function defined in the
// header, bar the two sanitizer annotations below, which have to be compiled
// here — see the header for why. On non-Apple platforms the header is empty and
// so is this file, which SwiftPM needs anyway to have one translation unit.

#include "CSynchronizationKitRWLock.h"

#if defined(__APPLE__)

#if __has_feature(thread_sanitizer)
#include <sanitizer/tsan_interface.h>
#endif

void sk_rwlock_tsan_release(void *token) {
#if __has_feature(thread_sanitizer)
    __tsan_release(token);
#else
    (void)token;
#endif
}

void sk_rwlock_tsan_acquire(void *token) {
#if __has_feature(thread_sanitizer)
    __tsan_acquire(token);
#else
    (void)token;
#endif
}

#endif // defined(__APPLE__)
