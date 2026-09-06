// The two sanitizer annotations, compiled here so that `__has_feature` is
// answered by the compiler building this target — see the header for why.

#include "CSynchronizationKitCore.h"

#if __has_feature(thread_sanitizer)
#include <sanitizer/tsan_interface.h>
#endif

void sk_tsan_release(void *token) {
#if __has_feature(thread_sanitizer)
    __tsan_release(token);
#else
    (void)token;
#endif
}

void sk_tsan_acquire(void *token) {
#if __has_feature(thread_sanitizer)
    __tsan_acquire(token);
#else
    (void)token;
#endif
}
