// swift-tools-version: 6.0
import PackageDescription

// The ONLY package that pulls in MLX — and specifically the PrismML 1-bit fork. Kept separate so
// AppUI / AppRuntime / LLMCore keep their fast MLX-free `swift test` loop. See docs/WIRING.md.
let package = Package(
    name: "LLMEngineMLX",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LLMEngineMLX", targets: ["LLMEngineMLX"]),
        .executable(name: "llm-smoke", targets: ["LLMSmoke"]),
    ],
    dependencies: [
        .package(path: "../LLMCore"),
        // The fork's MLX core (adds the bits=1 affine Metal kernel), pinned by revision. Same URL
        // identity ("mlx-swift") as what nanguoyu/mlx-swift-lm resolves → one mlx-swift in the graph.
        .package(url: "https://github.com/PrismML-Eng/mlx-swift",
                 revision: "e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230"),
        .package(url: "https://github.com/nanguoyu/mlx-swift-lm",
                 revision: "ab016139837f58646f1b984ebfbadd8bacf866d5"),
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
        ]),
        .executableTarget(name: "LLMSmoke", dependencies: ["LLMEngineMLX"],
            // MLX's Cmlx links libc++ via @rpath/libc++.1.dylib; `swift run` on Xcode 26 / Swift 6.2
            // omits the system lib dir from rpath, so add /usr/lib (libc++ is in the shared cache).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib"])]),
    ]
)
