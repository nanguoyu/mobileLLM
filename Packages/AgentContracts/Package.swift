// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentContracts",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentContracts", targets: ["AgentContracts"]),
    ],
    targets: [
        .target(name: "AgentContracts"),
        .testTarget(name: "AgentContractsTests", dependencies: ["AgentContracts"]),
    ]
)
