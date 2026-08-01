// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import AgentHarnessVerificationCore

final class ArchitectureBoundaryVerifierTests: XCTestCase {
    // TEST-ID: AHT-ARCH-001
    func testPackageBoundariesAcceptOnlyApprovedDependenciesAndImports() throws {
        let fixture = try ArchitectureFixture()

        // Future packages remain planned: their absence is not reported as implementation evidence.
        XCTAssertTrue(fixture.verify().isEmpty)

        try fixture.writePackage(
            name: "AgentContracts",
            packageDependencies: "",
            targetDependencies: "",
            source: "import Foundation\nimport CryptoKit\npublic struct AgentRequest {}\n"
        )
        try fixture.writePackage(
            name: "AgentSandboxAPI",
            packageDependencies: #".package(path: "../AgentContracts")"#,
            targetDependencies: #""AgentContracts""#,
            source: "import Foundation\nimport AgentContracts\npublic protocol AgentSandboxProvider {}\n"
        )
        try fixture.writePackage(
            name: "AgentRuntime",
            packageDependencies: [
                #".package(path: "../AgentContracts")"#,
                #".package(path: "../AgentSandboxAPI")"#,
                #".package(path: "../LLMCore")"#,
                #".package(path: "../AppRuntime")"#,
            ].joined(separator: ",\n"),
            targetDependencies: #""AgentContracts", "AgentSandboxAPI", "LLMCore", "AppRuntime""#,
            source: "import Foundation\nimport AgentContracts\nimport AgentSandboxAPI\n"
                + "import LLMCore\nimport AppRuntime\npublic protocol AgentModelProvider {}\n"
        )
        XCTAssertTrue(fixture.verify().isEmpty)

        try fixture.writePackage(
            name: "AgentContracts",
            packageDependencies: #".package(path: "../LLMCore")"#,
            targetDependencies: #""LLMCore""#,
            source: "import SwiftUI\nimport LLMEngineMLX\npublic struct AgentRequest {}\n"
        )
        try fixture.writePackage(
            name: "AgentSandboxAPI",
            packageDependencies: #".package(path: "../AgentRuntime")"#,
            targetDependencies: #""AgentRuntime""#,
            source: "import AgentRuntime\npublic protocol AgentSandboxProvider {}\n"
        )
        try fixture.writePackage(
            name: "AgentRuntime",
            packageDependencies: #".package(path: "../MobileLLMUI")"#,
            targetDependencies: #".product(name: "MobileLLMUI", package: "MobileLLMUI")"#,
            source: "import SwiftUI\nimport CoreLocation\nimport PrivateAgentSandboxRuntime\n"
        )

        let codes = Set(fixture.verify().map(\.code))
        XCTAssertTrue(codes.contains("AHV-ARCH-PACKAGE-DEPENDENCY"))
        XCTAssertTrue(codes.contains("AHV-ARCH-TARGET-DEPENDENCY"))
        XCTAssertTrue(codes.contains("AHV-ARCH-IMPORT"))
    }

    // TEST-ID: AHT-ARCH-002
    func testDeferredImplementationsAndShellEntryPointsAreRejected() throws {
        let fixture = try ArchitectureFixture()
        try fixture.writeProductionSource(
            "Compatibility.swift",
            contents: """
            public protocol SubagentSpawner {}
            public protocol AgentSandboxProvider {}
            public struct WorkflowReference {}
            public struct SandboxExecutionRequest {}
            """
        )
        XCTAssertTrue(fixture.verify().isEmpty)

        try fixture.writeProductionSource(
            "Forbidden.swift",
            contents: """
            struct WorkflowInterpreter {}
            actor DAGScheduler {}
            struct LocalSubagentSpawner {}
            struct PlaceholderSandbox: AgentSandboxProvider {}
            final class OpenAIModelProvider {}
            struct ShellExecutor {}
            func executeShell() {
                let process = Process()
                _ = system("true")
            }
            """
        )

        let diagnostics = fixture.verify()
        let codes = Set(diagnostics.map(\.code))
        XCTAssertTrue(codes.contains("AHV-DEFERRED-WORKFLOW"))
        XCTAssertTrue(codes.contains("AHV-DEFERRED-SUBAGENT"))
        XCTAssertTrue(codes.contains("AHV-DEFERRED-SANDBOX"))
        XCTAssertTrue(codes.contains("AHV-DEFERRED-ONLINE-MODEL"))
        XCTAssertTrue(codes.contains("AHV-DEFERRED-SHELL"))
        XCTAssertEqual(diagnostics, diagnostics.sorted())
    }
}

private final class ArchitectureFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "agent-harness-architecture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func verify() -> [VerificationDiagnostic] {
        var diagnostics: [VerificationDiagnostic] = []
        ArchitectureBoundaryVerifier.verify(root: root, diagnostics: &diagnostics)
        return diagnostics.sorted()
    }

    func writePackage(
        name: String,
        packageDependencies: String,
        targetDependencies: String,
        source: String
    ) throws {
        let package = root.appending(path: "Packages/\(name)", directoryHint: .isDirectory)
        let sources = package.appending(path: "Sources/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(name)",
            products: [.library(name: "\(name)", targets: ["\(name)"])],
            dependencies: [\(packageDependencies)],
            targets: [
                .target(name: "\(name)", dependencies: [\(targetDependencies)]),
                .testTarget(name: "\(name)Tests", dependencies: ["\(name)"])
            ]
        )
        """
        try Data(manifest.utf8).write(to: package.appending(path: "Package.swift"))
        try Data(source.utf8).write(to: sources.appending(path: "Source.swift"))
    }

    func writeProductionSource(_ name: String, contents: String) throws {
        let directory = root.appending(path: "App", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: directory.appending(path: name))
    }
}
