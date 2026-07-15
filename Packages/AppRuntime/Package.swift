// swift-tools-version: 5.10
import PackageDescription

// AppRuntime — mobileLLM's MLX-free runtime substrate. The self-contained, dependency-light pieces
// memory + thermal governance, a resumable
// Hugging Face downloader, a durable atomic-write store, and the download progress meter. Foundation
// + CryptoKit only, so it compiles + tests with the plain SwiftPM CLI (no Metal toolchain).
let package = Package(
    name: "AppRuntime",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AppRuntime", targets: ["AppRuntime"]),
    ],
    targets: [
        .target(name: "AppRuntime"),
        .testTarget(name: "AppRuntimeTests", dependencies: ["AppRuntime"]),
    ]
)
