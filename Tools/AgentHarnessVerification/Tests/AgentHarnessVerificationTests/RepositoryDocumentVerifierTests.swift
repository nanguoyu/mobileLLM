// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import AgentHarnessVerificationCore

final class RepositoryDocumentVerifierTests: XCTestCase {
    // TEST-ID: AHT-INFRA-001
    func testOfflineJSONSchemaValidatorCoversRepositoryDialect() {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "id", "values", "child"],
            "properties": [
                "kind": ["enum": ["strict", "relaxed"]],
                "id": ["type": "string", "format": "uuid"],
                "values": [
                    "type": "array", "minItems": 1, "uniqueItems": true,
                    "contains": ["const": "required"],
                    "items": ["type": "string", "minLength": 1, "maxLength": 20],
                ],
                "child": ["$ref": "#/$defs/child"],
            ],
            "allOf": [[
                "if": ["properties": ["kind": ["const": "strict"]]],
                "then": ["properties": ["child": ["properties": ["count": ["minimum": 2]]]]],
            ]],
            "$defs": [
                "child": [
                    "type": "object", "additionalProperties": false,
                    "required": ["count"],
                    "properties": ["count": ["type": "integer", "minimum": 0, "maximum": 5]],
                ],
            ],
        ]
        let valid: [String: Any] = [
            "kind": "strict", "id": "B32AE642-B9A9-4D0A-932E-6A3C24395F69",
            "values": ["required", "other"], "child": ["count": 2],
        ]

        XCTAssertTrue(RepositoryJSONSchemaValidator.validateSchema(schema, label: "schema").isEmpty)
        XCTAssertTrue(RepositoryJSONSchemaValidator.validate(
            instance: valid, against: schema, label: "instance"
        ).isEmpty)

        var invalid = valid
        invalid["extra"] = true
        invalid["values"] = ["duplicate", "duplicate"]
        invalid["child"] = ["count": 1.5]
        let messages = RepositoryJSONSchemaValidator.validate(
            instance: invalid, against: schema, label: "instance"
        ).map(\.message)
        XCTAssertTrue(messages.contains("additional property is not allowed"))
        XCTAssertTrue(messages.contains("item is duplicated"))
        XCTAssertTrue(messages.contains(where: { $0.contains("declared type integer") }))
    }

    func testSchemaDefinitionsRejectUnknownKeywordsAndExternalReferences() {
        let unknown = RepositoryJSONSchemaValidator.validateSchema(
            ["type": "string", "silentlyIgnoreMe": true], label: "schema"
        )
        XCTAssertEqual(unknown.map(\.message), ["unsupported schema keyword 'silentlyIgnoreMe'"])

        let external = RepositoryJSONSchemaValidator.validateSchema(
            ["$ref": "https://example.invalid/schema.json"], label: "schema"
        )
        XCTAssertEqual(external.map(\.message),
                       ["only local JSON Pointer references are supported"])

        let unresolved = RepositoryJSONSchemaValidator.validate(
            instance: 1, against: ["$ref": "#/$defs/missing"], label: "instance"
        )
        XCTAssertEqual(unresolved.map(\.message),
                       ["unresolved schema reference #/$defs/missing"])
    }

    // TEST-ID: AHT-INFRA-003
    func testCheckedInRegistriesAndFixturesPassSemanticVerification() {
        var diagnostics: [VerificationDiagnostic] = []
        RepositoryDocumentVerifier.verify(root: repositoryRoot(), diagnostics: &diagnostics)
        XCTAssertTrue(diagnostics.isEmpty, diagnostics.map {
            "\($0.location): [\($0.code)] \($0.message)"
        }.joined(separator: "\n"))
    }

    // TEST-ID: AHT-INFRA-004
    func testDeterministicFixtureFamiliesAreComplete() throws {
        let root = repositoryRoot()
        let modelDirectory = root.appending(
            path: "Verification/AgentHarness/ModelScripts", directoryHint: .isDirectory
        )
        let containerDirectory = root.appending(
            path: "Verification/AgentHarness/AppContainers", directoryHint: .isDirectory
        )
        let modelScenarios = try fixtureValues(in: modelDirectory, key: "scenario")
        XCTAssertEqual(modelScenarios, Set([
            "pureChat", "toolThenAnswer", "malformedRepair", "userInput",
        ]))
        let containerScenarios = try fixtureValues(in: containerDirectory, key: "scenario")
        XCTAssertEqual(containerScenarios, Set(["cleanInstall", "legacyUpgrade"]))
    }

    // TEST-ID: AHT-INFRA-005
    func testConditionalCoverageSchemaRejectsIncompletePolicy() throws {
        let root = repositoryRoot()
        let schemaURL = root.appending(
            path: "Verification/AgentHarness/Schemas/coverage-policy.schema.json"
        )
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL))
        let incomplete: [String: Any] = [
            "$schema": "../Schemas/coverage-policy.schema.json",
            "schemaVersion": 1,
            "documentID": "AH-COVERAGE-POLICY-V1",
            "documentType": "policy",
        ]
        let locations = RepositoryJSONSchemaValidator.validate(
            instance: incomplete, against: schema, label: "policy"
        ).map(\.location)
        XCTAssertTrue(locations.contains("policy.floors"))
        XCTAssertTrue(locations.contains("policy.semanticGates"))
        XCTAssertTrue(locations.contains("policy.mutationGates"))
        XCTAssertTrue(locations.contains("policy.collection"))
    }

    // TEST-ID: AHT-INFRA-007
    func testMissingRepositoryEvidenceFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "agent-harness-empty-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var diagnostics: [VerificationDiagnostic] = []
        RepositoryDocumentVerifier.verify(root: root, diagnostics: &diagnostics)
        XCTAssertTrue(diagnostics.contains { $0.code == "AHV-JSON-MISSING" })
        XCTAssertTrue(diagnostics.contains { $0.code == "AHV-DISCOVERY-EMPTY" })
        XCTAssertTrue(diagnostics.contains { $0.code == "AHV-TESTPLAN-PROJECT" })
    }

    // TEST-ID: AHT-INFRA-003
    func testSemanticDecisionRegistriesRejectGapsConflictsDeadRulesAndUnknownDomains() throws {
        let gap = try diagnosticsAfterRegistryMutation("run-transitions.v1.json") { object in
            var entries = object["entries"] as! [[String: Any]]
            entries.removeAll { $0["id"] as? String == "AH-TRANSITION-ADMISSION-008" }
            object["entries"] = entries
        }
        XCTAssertTrue(gap.contains { $0.code == "AHV-REGISTRY-GAP" })

        let conflict = try diagnosticsAfterRegistryMutation("run-transitions.v1.json") { object in
            var entries = object["entries"] as! [[String: Any]]
            var duplicate = entries.first {
                $0["id"] as? String == "AH-TRANSITION-ADMISSION-008"
            }!
            duplicate["id"] = "AH-TRANSITION-ADMISSION-CONFLICT"
            entries.append(duplicate)
            object["entries"] = entries
        }
        XCTAssertTrue(conflict.contains { $0.code == "AHV-REGISTRY-PRIORITY-CONFLICT" })

        let deadRule = try diagnosticsAfterRegistryMutation("run-transitions.v1.json") { object in
            var entries = object["entries"] as! [[String: Any]]
            var shadowed = entries.first {
                $0["id"] as? String == "AH-TRANSITION-ADMISSION-001"
            }!
            shadowed["id"] = "AH-TRANSITION-ADMISSION-SHADOWED"
            shadowed["priority"] = 1
            entries.append(shadowed)
            object["entries"] = entries
        }
        XCTAssertTrue(deadRule.contains { $0.code == "AHV-REGISTRY-DEAD-RULE" })

        let unknownAxis = try diagnosticsAfterRegistryMutation("run-transitions.v1.json") { object in
            var entries = object["entries"] as! [[String: Any]]
            let index = entries.firstIndex {
                $0["id"] as? String == "AH-TRANSITION-ADMISSION-001"
            }!
            entries[index]["conditions"] = ["wireValiditty": "malformed"]
            object["entries"] = entries
        }
        XCTAssertTrue(unknownAxis.contains { $0.code == "AHV-REGISTRY-RULE-AXIS" })

        let unknownValue = try diagnosticsAfterRegistryMutation("run-transitions.v1.json") { object in
            var entries = object["entries"] as! [[String: Any]]
            let index = entries.firstIndex {
                $0["id"] as? String == "AH-TRANSITION-ADMISSION-001"
            }!
            entries[index]["conditions"] = ["wireValidity": "almostValid"]
            object["entries"] = entries
        }
        XCTAssertTrue(unknownValue.contains { $0.code == "AHV-REGISTRY-RULE-VALUE" })

        let missingValue = try diagnosticsAfterRegistryMutation("approval-decisions.v1.json") { object in
            var domains = object["domains"] as! [[String: Any]]
            let index = domains.firstIndex {
                $0["table"] as? String == "authorization" && $0["name"] as? String == "authority"
            }!
            domains[index]["values"] = ["valid", "missingStepGrant", "outsideRunCeiling",
                                         "planOutsideStepGrant"]
            object["domains"] = domains
        }
        XCTAssertTrue(missingValue.contains { $0.code == "AHV-REGISTRY-DOMAIN-COVERAGE" })
    }

    // TEST-ID: AHT-INFRA-003
    func testSemanticDecisionRegistriesRejectCommandAndApprovalSecurityDrift() throws {
        let commandDrift = try diagnosticsAfterRegistryMutation("run-states.v1.json") { object in
            var entries = object["entries"] as! [[String: Any]]
            let index = entries.firstIndex { $0["name"] as? String == "created" }!
            entries[index]["allowedUserCommands"] = ["cancel", "resume"]
            object["entries"] = entries
        }
        XCTAssertTrue(commandDrift.contains { $0.code == "AHV-REGISTRY-COMMAND-DRIFT" })

        let authorityExpansion = try diagnosticsAfterRegistryMutation("approval-decisions.v1.json") {
            object in
            var entries = object["entries"] as! [[String: Any]]
            let index = entries.firstIndex {
                $0["id"] as? String == "AH-APPROVAL-AUTHORITY-001"
            }!
            var outcome = entries[index]["outcome"] as! [String: Any]
            outcome["decision"] = "authorizeLocalPolicy"
            entries[index]["outcome"] = outcome
            object["entries"] = entries
        }
        XCTAssertTrue(authorityExpansion.contains { $0.code == "AHV-REGISTRY-SECURITY" })

        let backgroundPresentation = try diagnosticsAfterRegistryMutation(
            "approval-decisions.v1.json"
        ) { object in
            var entries = object["entries"] as! [[String: Any]]
            let index = entries.firstIndex {
                $0["id"] as? String == "AH-APPROVAL-PRESENTATION-002"
            }!
            var outcome = entries[index]["outcome"] as! [String: Any]
            outcome["runState"] = "waitingForForeground"
            entries[index]["outcome"] = outcome
            object["entries"] = entries
        }
        XCTAssertTrue(backgroundPresentation.contains { $0.code == "AHV-REGISTRY-SECURITY" })

        let conversationWrite = try diagnosticsAfterRegistryMutation("approval-decisions.v1.json") {
            object in
            var entries = object["entries"] as! [[String: Any]]
            let index = entries.firstIndex {
                $0["id"] as? String == "AH-APPROVAL-AUTHORITY-018"
            }!
            var outcome = entries[index]["outcome"] as! [String: Any]
            outcome["grantScope"] = "boundedConversationWrite"
            entries[index]["outcome"] = outcome
            object["entries"] = entries
        }
        XCTAssertTrue(conversationWrite.contains { $0.code == "AHV-REGISTRY-SECURITY" })
    }

    // TEST-ID: AHT-INFRA-003
    func testSemanticDecisionRegistryOrderingIsIrrelevantAndEvidenceMatchesExpansion() throws {
        let reordered = try diagnosticsAfterRegistryMutation("run-transitions.v1.json") { object in
            object["domains"] = Array((object["domains"] as! [[String: Any]]).reversed())
            object["entries"] = Array((object["entries"] as! [[String: Any]]).reversed())
            object["enumerationEvidence"] = Array(
                (object["enumerationEvidence"] as! [[String: Any]]).reversed()
            )
        }
        XCTAssertTrue(reordered.isEmpty, reordered.map {
            "\($0.location): [\($0.code)] \($0.message)"
        }.joined(separator: "\n"))

        let tamperedEvidence = try diagnosticsAfterRegistryMutation("run-transitions.v1.json") {
            object in
            var evidence = object["enumerationEvidence"] as! [[String: Any]]
            evidence[0]["winningRuleCount"] = 999
            object["enumerationEvidence"] = evidence
        }
        XCTAssertTrue(tamperedEvidence.contains { $0.code == "AHV-REGISTRY-EVIDENCE" })
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.standardizedFileURL
    }

    private func fixtureValues(in directory: URL, key: String) throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        return try Set(files.map { file in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            return object[key] as! String
        })
    }

    private func diagnosticsAfterRegistryMutation(
        _ fileName: String, mutate: (inout [String: Any]) throws -> Void
    ) throws -> [VerificationDiagnostic] {
        let sourceRoot = repositoryRoot()
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "agent-harness-registry-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let verificationRoot = temporaryRoot.appending(
            path: "Verification/AgentHarness", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: verificationRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceRoot.appending(path: "Verification/AgentHarness/Registries"),
            to: verificationRoot.appending(path: "Registries")
        )
        for manifest in ["requirements.v1.json", "tests.v1.json"] {
            try FileManager.default.copyItem(
                at: sourceRoot.appending(path: "Verification/AgentHarness/\(manifest)"),
                to: verificationRoot.appending(path: manifest)
            )
        }
        let target = verificationRoot.appending(path: "Registries/\(fileName)")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: target))
            as! [String: Any]
        try mutate(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: target, options: .atomic)
        var diagnostics: [VerificationDiagnostic] = []
        SemanticRegistryVerifier.verify(root: temporaryRoot, diagnostics: &diagnostics)
        return diagnostics
    }
}
