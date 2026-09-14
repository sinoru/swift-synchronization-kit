// Every entry point in this target is an always-inline function defined in the
// header, with one exception the header describes: an iPhone or Apple TV build
// under a Swift older than 6.4 may import them as declarations only, and this
// file is where those are defined. It is compiled by Clang for the package's
// minimum deployment target, so the code here runs on every device that
// target supports. Elsewhere the header defines nothing here, and this file
// is only the one translation unit SwiftPM requires a target to have.

#define SK_ATOMIC_DEFINE_OUTLINED
#include "CSynchronizationKitAtomic.h"
