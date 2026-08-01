// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentHarnessVerification",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "AgentHarnessVerificationCore",
            targets: ["AgentHarnessVerificationCore"]
        ),
        .executable(
            name: "agent-harness-verify",
            targets: ["AgentHarnessVerifyCLI"]
        ),
    ],
    targets: [
        .target(name: "AgentHarnessVerificationCore"),
        .executableTarget(
            name: "AgentHarnessVerifyCLI",
            dependencies: ["AgentHarnessVerificationCore"]
        ),
        .testTarget(
            name: "AgentHarnessVerificationTests",
            dependencies: ["AgentHarnessVerificationCore"]
        ),
    ]
)
