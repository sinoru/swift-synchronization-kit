//
//  PrivacyManifest.swift
//  SynchronizationKit
//
//  Copyright (c) 2026 Kang Jaehong
//  SPDX-License-Identifier: Apache-2.0
//

// This target exists to carry `RWLock`'s `PrivacyInfo.xcprivacy` and holds
// no code. A target's resources cost it a generated `Bundle.module` accessor,
// which imports Foundation, so the manifest lives here rather than beside
// the code that needs it, and only builds for Apple platforms depend on this
// target; `Package.swift` says more.
