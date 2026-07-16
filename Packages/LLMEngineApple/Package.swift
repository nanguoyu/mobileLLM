// swift-tools-version: 6.0
import PackageDescription

// LLMEngineApple — the third engine behind `LLMCore.LLMEngine`: Apple's own on-device model, reached
// through the FoundationModels system framework. No MLX, no third-party dependencies, and no weights —
// the OS owns the model and runs it out of process. Builds + tests with the plain SwiftPM CLI.
//
// PLATFORMS: FoundationModels is iOS 26 / macOS 26, but this package deliberately declares the SAME
// deployment targets as the rest of the repo. A package cannot be consumed by one with a LOWER target
// ("the library 'X' requires macos 14.0, but depends on the product 'Y' which requires macos 26.0"), so
// declaring 26 here would leave the app — iOS 17 / macOS 14 — unable to link it at all. Instead every
// use of the framework sits behind `#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26, *)`.
// The framework then auto-weak-links (verified: `otool -L` marks it `weak`), so a binary built this way
// still LAUNCHES on an older OS, where the engine honestly reports `.unavailable(.unsupportedOS)` instead
// of being absent or dying in dyld.
let package = Package(
    name: "LLMEngineApple",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LLMEngineApple", targets: ["LLMEngineApple"]),
    ],
    dependencies: [
        .package(path: "../LLMCore"),
    ],
    targets: [
        .target(
            name: "LLMEngineApple",
            dependencies: [
                .product(name: "LLMCore", package: "LLMCore"),
            ]
        ),
        // Pure, framework-free unit tests: they run on ANY OS (including one with no FoundationModels)
        // because every decision the engine makes is factored into plain functions over plain types.
        .testTarget(name: "LLMEngineAppleTests", dependencies: ["LLMEngineApple"]),
    ]
)
