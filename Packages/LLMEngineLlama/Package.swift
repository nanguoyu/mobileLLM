// swift-tools-version: 6.0
import PackageDescription

// The llama.cpp engine package — sibling to LLMEngineMLX. It vendors a prebuilt `llama.xcframework`
// (mainline llama.cpp, Metal embedded — no .metallib to ship) as a binary target and exposes a
// `LlamaEngine` actor conforming to `LLMCore.LLMEngine`. Unlike the MLX package there is NO fork and NO
// build macros, so it needs neither `-skipMacroValidation` nor a special toolchain.
//
// The xcframework is produced by `llama.cpp/build-xcframework.sh` then trimmed to the iOS + macOS
// slices and copied to `Vendor/llama.xcframework` (see docs/WIRING.md). It is gitignored — a fresh
// checkout regenerates it with `scripts/build-llama-xcframework.sh`.
let package = Package(
    name: "LLMEngineLlama",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LLMEngineLlama", targets: ["LLMEngineLlama"]),
        .executable(name: "llama-smoke", targets: ["LlamaSmoke"]),
    ],
    dependencies: [
        .package(path: "../LLMCore"),
    ],
    targets: [
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .target(name: "LLMEngineLlama", dependencies: [
            .product(name: "LLMCore", package: "LLMCore"),
            "llama",
        ], path: "Sources/LLMEngineLlama"),
        .executableTarget(name: "LlamaSmoke", dependencies: ["LLMEngineLlama"],
            path: "Sources/LlamaSmoke",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib"])]),
        .testTarget(name: "LLMEngineLlamaTests", dependencies: ["LLMEngineLlama"],
            path: "Tests/LLMEngineLlamaTests",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib"])]),
    ]
)
