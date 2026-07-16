// swift-tools-version: 5.10
import PackageDescription

// MobileLLMUI — the product UI layer for mobileLLM: the SwiftUI chat surface, model manager, and
// settings, plus the @Observable stores that drive them. MLX-FREE: it codes against the
// `LLMCore.LLMEngine` protocol and is exercised by `LLMCore.MockLLMEngine` in previews + tests, so
// the real fork-linked MLX engine injects at app-assembly time. Builds + tests with the plain SwiftPM
// CLI (no Metal toolchain).
let package = Package(
    name: "MobileLLMUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MobileLLMUI", targets: ["MobileLLMUI"]),
    ],
    dependencies: [
        .package(path: "../AppUI"),
        .package(path: "../AppRuntime"),
        .package(path: "../LLMCore"),
    ],
    targets: [
        .target(
            name: "MobileLLMUI",
            dependencies: [
                .product(name: "AppUI", package: "AppUI"),
                .product(name: "AppRuntime", package: "AppRuntime"),
                .product(name: "LLMCore", package: "LLMCore"),
            ]
        ),
        // The captured live-feed fixture is read source-relative (via #filePath) rather than from a
        // bundle — declare it so SwiftPM doesn't warn about an unhandled file.
        .testTarget(name: "MobileLLMUITests", dependencies: ["MobileLLMUI"],
                    resources: [.copy("live-feed-fixture.xml")]),
    ]
)
