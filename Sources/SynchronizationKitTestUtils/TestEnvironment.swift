//
//  TestEnvironment.swift
//  SynchronizationKit
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Whether the types under test are this package's own rather than the
/// standard library's, re-exported.
///
/// The condition the Atomic and Mutex modules are themselves built under,
/// spelled once for the suites that turn on the distinction. Those suites ask
/// it at run time rather than with a `#if` of their own, so a case that does
/// not apply is reported as skipped instead of vanishing — and, more usefully,
/// so its body is type-checked against whichever implementation is present.
#if !canImport(Synchronization) || os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
public let implementationIsThisPackage = true
#else
public let implementationIsThisPackage = false
#endif

/// Whether a sanitizer runtime is loaded into this process, asked by looking
/// for the entry point that only it defines.
///
/// Asked of the runtime rather than of `__has_feature`, which would answer for
/// whichever compiler saw the file rather than for the process the tests run
/// in.
///
/// Windows has no `dlopen` to ask and no sanitizer to ask about, so it answers
/// without a loader. So does WASI, which has neither those nor the Dispatch
/// that every caller of this currently needs.
#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
private func sanitizerIsLoaded(entryPoint: String) -> Bool {
    guard let program = unsafe dlopen(nil, RTLD_LAZY) else {
        return false
    }
    return unsafe dlsym(program, entryPoint) != nil
}

/// Whether the ThreadSanitizer runtime is loaded into this process.
public let threadSanitizerIsLoaded = sanitizerIsLoaded(entryPoint: "__tsan_init")

/// Whether the AddressSanitizer runtime is loaded into this process.
public let addressSanitizerIsLoaded = sanitizerIsLoaded(entryPoint: "__asan_init")
#else
public let threadSanitizerIsLoaded = false
public let addressSanitizerIsLoaded = false
#endif
