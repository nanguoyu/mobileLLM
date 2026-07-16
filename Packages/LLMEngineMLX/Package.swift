// swift-tools-version: 6.0
import PackageDescription

// The ONLY package that pulls in MLX — and specifically the PrismML 1-bit fork. Kept separate so
// AppUI / AppRuntime / LLMCore keep their fast MLX-free `swift test` loop. See docs/WIRING.md.
// Targets that use the MLXHuggingFace load macros build via `xcodebuild -skipMacroValidation` only.
let package = Package(
    name: "LLMEngineMLX",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LLMEngineMLX", targets: ["LLMEngineMLX"]),
        .executable(name: "llm-smoke", targets: ["LLMSmoke"]),
        .executable(name: "llm-decode", targets: ["LLMDecode"]),
    ],
    dependencies: [
        .package(path: "../LLMCore"),
        .package(url: "https://github.com/PrismML-Eng/mlx-swift",
                 revision: "e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230"),
        .package(url: "https://github.com/nanguoyu/mlx-swift-lm",
                 revision: "ab016139837f58646f1b984ebfbadd8bacf866d5"),
        // HF model loader: MLXHuggingFace's load macros expand to code using HuggingFace.HubClient
        // (swift-huggingface) + Tokenizers.AutoTokenizer (swift-transformers) — the consumer supplies them.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        // Match swift-syntax to the installed 6.2 toolchain (mlx-swift-lm's macros default to 603/6.3).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0" ..< "603.0.0"),
    ],
    targets: [
        .target(name: "LLMEngineMLX", dependencies: [
            .product(name: "LLMCore", package: "LLMCore"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXRandom", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
        ]),
        .executableTarget(name: "LLMSmoke", dependencies: ["LLMEngineMLX"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib"])]),
        .executableTarget(name: "LLMDecode", dependencies: ["LLMEngineMLX"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib"])]),
        // Pure, weight-free unit tests over the ChatTurn→Chat.Message mapping. Building this links MLX
        // (LLMEngineMLX pulls it in) but the tests never allocate an MLXArray or load a model.
        .testTarget(name: "LLMEngineMLXTests", dependencies: ["LLMEngineMLX"]),
    ]
)
