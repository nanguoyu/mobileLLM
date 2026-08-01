// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import AgentHarnessVerificationCore

final class AgentHarnessVerificationTests: XCTestCase {
    // TEST-ID: AHT-INFRA-001
    func testRequirementsManifest() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.verify(.static).succeeded)
        XCTAssertTrue(fixture.verify(.release).succeeded)

        try fixture.changeRequirements { document in
            var source = document["sourceSpecification"] as! [String: Any]
            source["sha256"] = String(repeating: "0", count: 64)
            document["sourceSpecification"] = source
            var requirements = document["requirements"] as! [[String: Any]]
            requirements[0]["id"] = "bad-id"
            requirements[0]["specAnchors"] = [[
                "section": "99", "heading": "Missing", "lineStart": 1, "lineEnd": 2,
            ]]
            document["requirements"] = requirements
        }
        let codes = Set(fixture.verify(.static).diagnostics.map(\.code))
        XCTAssertTrue(codes.contains("AHV-SPEC-HASH-MISMATCH"))
        XCTAssertTrue(codes.contains("AHV-REQUIREMENT-ID"))

        let badAnchor = try Fixture()
        try badAnchor.changeRequirements { document in
            var requirements = document["requirements"] as! [[String: Any]]
            requirements[0]["specAnchors"] = [[
                "section": "99", "heading": "Missing", "lineStart": 1, "lineEnd": 2,
            ]]
            document["requirements"] = requirements
        }
        XCTAssertTrue(badAnchor.verify(.static).diagnostics.contains {
            $0.code == "AHV-SOURCE-ANCHOR"
        })
    }

    // TEST-ID: AHT-INFRA-002
    func testBidirectionalTraceability() throws {
        let fixture = try Fixture()
        try fixture.changeTests { document in
            var tests = document["tests"] as! [[String: Any]]
            tests[0]["requirementIDs"] = ["AH-OTHER-001"]
            document["tests"] = tests
        }
        let diagnostics = fixture.verify(.static).diagnostics
        XCTAssertTrue(diagnostics.contains { $0.code == "AHV-TRACEABILITY-ASYMMETRIC" })
        XCTAssertTrue(diagnostics.contains { $0.code == "AHV-UNKNOWN-REQUIREMENT" })

        let planned = try Fixture()
        try planned.changeTests { document in
            var tests = document["tests"] as! [[String: Any]]
            tests[0]["status"] = "planned"
            tests[0]["selectors"] = []
            document["tests"] = tests
        }
        XCTAssertTrue(planned.verify(.static).diagnostics.contains {
            $0.code == "AHV-ACTIVE-PLANNED-TEST"
        })
        XCTAssertTrue(planned.verify(.release).diagnostics.contains {
            $0.code == "AHV-RELEASE-TEST-STATUS"
        })
    }

    // TEST-ID: AHT-INFRA-006
    func testQuarantinePolicy() throws {
        let fixture = try Fixture()
        try fixture.changeQuarantine { document in
            document["entries"] = [[
                "testID": "AHT-INFRA-001",
                "owner": "runtime-team",
                "reason": "reproducing a failure",
                "createdAtUTC": "2026-08-01T00:00:00Z",
                "expiresAtUTC": "2026-08-09T00:00:01Z",
                "replacementCoverageTestIDs": ["AHT-INFRA-001"],
            ]]
        }
        let codes = Set(fixture.verify(.static).diagnostics.map(\.code))
        XCTAssertTrue(codes.contains("AHV-QUARANTINE-WINDOW"))
        XCTAssertTrue(codes.contains("AHV-FORBIDDEN-QUARANTINE"))
    }

    func testActiveSelectorRequiresMarkerAndSymbol() throws {
        let fixture = try Fixture()
        try Data("func testRequirementsManifest() {}\n".utf8)
            .write(to: fixture.root.appending(path: "VerifierTests.swift"))
        let diagnostics = fixture.verify(.static).diagnostics
        XCTAssertTrue(diagnostics.contains { $0.code == "AHV-ACTIVE-SOURCE-MISSING" })
    }

    func testDiagnosticsHaveStableOrdering() throws {
        let fixture = try Fixture()
        try fixture.changeRequirements { document in
            var requirements = document["requirements"] as! [[String: Any]]
            requirements[0]["platforms"] = ["unsupported", "unsupported"]
            requirements[0]["verificationTiers"] = []
            document["requirements"] = requirements
        }
        let diagnostics = fixture.verify(.static).diagnostics
        XCTAssertEqual(diagnostics, diagnostics.sorted())
    }
}

private final class Fixture {
    let root: URL
    private let requirementsURL: URL
    private let testsURL: URL
    private let quarantineURL: URL
    private let now = ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "agent-harness-verifier-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        requirementsURL = root.appending(path: "requirements.v1.json")
        testsURL = root.appending(path: "tests.v1.json")
        quarantineURL = root.appending(path: "quarantine.v1.json")

        let spec = Data("# 27. `Test strategy`\nNormative body.\n".utf8)
        try spec.write(to: root.appending(path: "spec.md"))
        try Data("// TEST-ID: AHT-INFRA-001\nfunc testRequirementsManifest() {}\n".utf8)
            .write(to: root.appending(path: "VerifierTests.swift"))
        try write([
            "schemaVersion": 1,
            "documentID": "AH-REQUIREMENTS-V1",
            "sourceSpecification": [
                "path": "spec.md",
                "sha256": AgentHarnessManifestVerifier.sha256Hex(of: spec),
                "capturedAtUTC": "2026-08-01T00:00:00Z",
            ],
            "requirements": [[
                "id": "AH-INFRA-001", "area": "infrastructure", "title": "Pinned spec",
                "statement": "The specification is pinned.", "status": "active", "riskTier": "P0",
                "specAnchors": [[
                    "section": "27", "heading": "Test strategy", "lineStart": 1, "lineEnd": 2,
                ]],
                "platforms": ["all"], "verificationTiers": ["every-change"],
                "testIDs": ["AHT-INFRA-001"], "requiredEvidence": ["verifier output"],
            ]],
        ], to: requirementsURL)
        try write([
            "schemaVersion": 1,
            "documentID": "AHT-TESTS-V1",
            "tests": [[
                "id": "AHT-INFRA-001", "title": "Manifest verification", "status": "active",
                "kind": "manifest", "riskTier": "P0", "requirementIDs": ["AH-INFRA-001"],
                "selectors": [[
                    "kind": "swift-test",
                    "value": "AgentHarnessVerificationTests/testRequirementsManifest",
                ]],
                "platforms": ["swiftpm"], "verificationTiers": ["every-change"],
                "requiredEvidence": ["XCTest result"],
                "determinism": ["fixedSeedRequired": false, "rotatingSeedRequired": false],
            ]],
        ], to: testsURL)
        try write([
            "schemaVersion": 1,
            "documentID": "AH-QUARANTINE-V1",
            "policy": [
                "maximumDays": 7, "forbiddenRiskTiers": ["P0"],
                "forbiddenAreas": ["security-privacy"], "expiredEntryFailsVerification": true,
            ],
            "entries": [],
        ], to: quarantineURL)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func verify(_ mode: VerificationMode) -> VerificationReport {
        AgentHarnessManifestVerifier.verify(.init(
            mode: mode, repositoryRoot: root,
            requirementsURL: requirementsURL, testsURL: testsURL,
            quarantineURL: quarantineURL, now: now
        ))
    }

    func changeRequirements(_ mutation: (inout [String: Any]) -> Void) throws {
        try mutate(requirementsURL, mutation)
    }

    func changeTests(_ mutation: (inout [String: Any]) -> Void) throws {
        try mutate(testsURL, mutation)
    }

    func changeQuarantine(_ mutation: (inout [String: Any]) -> Void) throws {
        try mutate(quarantineURL, mutation)
    }

    private func mutate(_ url: URL, _ mutation: (inout [String: Any]) -> Void) throws {
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        mutation(&document)
        try write(document, to: url)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
