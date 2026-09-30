//
//  shim.c
//  SynchronizationKit
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

// Everything this target exposes is an always-inline function defined in the
// header, so this file has nothing to compile. SwiftPM needs it anyway to
// have one translation unit.

#include "CSynchronizationKitSemaphore.h"
