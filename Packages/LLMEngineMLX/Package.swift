// swift-tools-version: 6.0
import PackageDescription

// The ONLY package that pulls in MLX — and specifically the PrismML 1-bit fork (via the repointed
// nanguoyu/mlx-swift-lm). Kept separate so AppUI / AppRuntime / LLMCore keep their fast MLX-free
// `swift test` loop. See docs/WIRING.md. Build with xcodebuild once the Metal is in the graph.
let package = Package(
    name: "LLMEngineMLX",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LLMEngineMLX", targets: ["LLMEngineMLX"]),
        .executable(name: "llm-smoke", targets: ["LLMSmoke"]),
    ],
    dependencies: [
        .package(path: "../LLMCore"),
        // Fork of mlx-swift-lm whose one repointed line pulls PrismML mlx-swift @ v0.31.6_prism
        // (adds the bits=1 affine Metal kernel). Revision-pinned for reproducibility.
        .package(url: "https://github.com/nanguoyu/mlx-swift-lm",
                 revision: "ab016139837f58646f1b984ebfbadd8bacf866d5"),
    ],
    targets: [
        .target(name: "LLMEngineMLX", dependencies: [
            .product(name: "LLMCore", package: "LLMCore"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
        .executableTarget(name: "LLMSmoke", dependencies: ["LLMEngineMLX"],
            // MLX's Cmlx links libc++ via @rpath/libc++.1.dylib; `swift run` on Xcode 26 / Swift 6.2
            // embeds rpaths that omit the system lib dir, so add /usr/lib (libc++ lives in the shared
            // cache there). xcodebuild handles this itself. Matches the sibling MLX packages.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib"])]),
    ]
)
