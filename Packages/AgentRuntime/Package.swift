// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentRuntime",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
    ],
    dependencies: [
        .package(path: "../AgentContracts"),
        .package(path: "../LLMCore"),
    ],
    targets: [
        .target(
            name: "AgentRuntime",
            dependencies: [
                "AgentContracts",
                .product(name: "LLMCore", package: "LLMCore"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime", "AgentContracts", "LLMCore"]
        ),
    ]
)
