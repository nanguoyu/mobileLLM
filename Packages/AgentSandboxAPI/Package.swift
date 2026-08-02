// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSandboxAPI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentSandboxAPI", targets: ["AgentSandboxAPI"]),
    ],
    dependencies: [
        .package(path: "../AgentContracts"),
    ],
    targets: [
        .target(
            name: "AgentSandboxAPI",
            dependencies: ["AgentContracts"]
        ),
        .testTarget(
            name: "AgentSandboxAPITests",
            dependencies: ["AgentSandboxAPI", "AgentContracts"],
            resources: [.process("Fixtures")]
        ),
    ]
)
