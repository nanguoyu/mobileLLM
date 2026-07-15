// swift-tools-version: 5.10
import PackageDescription

// LLMCore — the pure-Swift model layer for mobileLLM: the extensible model catalog + schema, the
// resident-only memory governor, the `<think>` stream splitter, sampling defaults, and the
// `LLMEngine` protocol with a deterministic mock. NO MLX yet — the real fork-linked engine is a
// later step, so this package stays MLX-free and testable with the plain SwiftPM CLI. Depends only
// on AppRuntime (for `DeviceTier`).
let package = Package(
    name: "LLMCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LLMCore", targets: ["LLMCore"]),
    ],
    dependencies: [
        .package(path: "../AppRuntime"),
    ],
    targets: [
        .target(
            name: "LLMCore",
            dependencies: [
                .product(name: "AppRuntime", package: "AppRuntime"),
            ]
        ),
        .testTarget(name: "LLMCoreTests", dependencies: ["LLMCore"]),
    ]
)
