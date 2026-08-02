// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import AgentContracts
import AgentSandboxAPI

final class PublicContractInventoryTests: XCTestCase {
    func testInventoryExactlyMapsEveryPublicSemanticCaseToExistingTests() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "public-contract-inventory.v1",
                withExtension: "json"
            )
        )
        let inventory = try AgentWireDecoder.decode(
            Inventory.self,
            from: Data(contentsOf: url),
            limits: .contractEnvelope
        )
        XCTAssertEqual(inventory.schemaVersion, 1)
        XCTAssertEqual(inventory.documentID, "AgentSandboxAPI-public-contract-inventory")
        XCTAssertEqual(inventory.documentType, "semantic-public-contract-inventory")

        XCTAssertEqual(Set(inventory.families.map(\.id)).count, inventory.families.count)
        var actual: [String: Set<String>] = [:]
        for family in inventory.families {
            XCTAssertFalse(family.id.isEmpty)
            XCTAssertEqual(Set(family.cases.map(\.id)).count, family.cases.count)
            for semanticCase in family.cases {
                let id = "\(family.id).\(semanticCase.id)"
                XCTAssertNil(actual[id], "Duplicate semantic inventory case: \(id)")
                XCTAssertFalse(semanticCase.testSelectors.isEmpty, "Missing test selector for \(id)")
                XCTAssertEqual(
                    Set(semanticCase.testSelectors).count,
                    semanticCase.testSelectors.count,
                    "Duplicate test selector for \(id)"
                )
                actual[id] = Set(semanticCase.testSelectors)
            }
        }

        let expected = expectedInventory()
        XCTAssertEqual(Set(actual.keys), Set(expected.keys))
        XCTAssertEqual(actual.count, expected.count)
        for (id, selector) in expected {
            XCTAssertEqual(actual[id], Set([selector]), "Incorrect semantic evidence for \(id)")
        }

        for selector in Set(actual.values.flatMap { $0 }) {
            try assertTestSelectorExists(selector)
        }
    }

    func testAllPayloadSchemasAreNamespacedAndUnique() {
        let schemas = [
            AgentSandboxProviderDescriptor.schemaID,
            SandboxCapabilities.schemaID,
            RegisteredSandboxProviderPolicy.schemaID,
            NegotiatedSandboxCapabilities.schemaID,
            SandboxExecutionRequest.schemaID,
            SandboxExecutionStatus.schemaID,
            SandboxExecutionResult.schemaID,
            SandboxCommand.schemaID,
            SandboxCommandReceipt.schemaID,
            SandboxEventRecord.schemaID,
        ]
        XCTAssertEqual(Set(schemas).count, schemas.count)
        XCTAssertTrue(schemas.allSatisfy { $0.hasPrefix("com.mobilellm.agent.sandbox.") })
    }

    private func expectedInventory() -> [String: String] {
        let providerEnums = selector(
            ProviderContractTests.self,
            "testAllPublicProviderEnumsAndErrorsRemainExhaustivelyRepresentable"
        )
        let providerRoundTrip = selector(
            ProviderContractTests.self,
            "testProviderValuesRoundTripAndUseNamespacedSchemas"
        )
        let negotiation = selector(
            ProviderContractTests.self,
            "testNegotiationIsExactLocalAndReportedIntersection"
        )
        let identity = selector(
            ProviderContractTests.self,
            "testIdentityFingerprintTrustAndProtocolTamperingFailClosed"
        )
        let protocolVersion = selector(
            ProviderContractTests.self,
            "testDescriptorAndCapabilityReportMustUseTheSameProtocol"
        )
        let memoryPressure = selector(
            ProviderContractTests.self,
            "testMemoryPressureBehaviorMustBeSupportedByBothPolicyAndProvider"
        )
        let missingConstraint = selector(
            ProviderContractTests.self,
            "testMissingConstraintKeyProducesNoAuthorityForThatDimension"
        )
        let downgrade = selector(
            ProviderContractTests.self,
            "testProviderCanDowngradeButCannotExpandLocalPolicy"
        )
        let canonicalFingerprint = selector(
            ProviderContractTests.self,
            "testFingerprintUsesCanonicalJSONAcrossInsertionAndNumberRepresentations"
        )
        let boundedFingerprint = selector(
            ProviderContractTests.self,
            "testFingerprintRejectsBoundedNonFiniteAndNonIJSONInputs"
        )
        let throwingFingerprint = selector(
            ProviderContractTests.self,
            "testFingerprintEncodingFailurePropagatesWithoutTrap"
        )
        let requestRoundTrip = selector(
            ExecutionAndEventContractTests.self,
            "testRequestRoundTripAndImmutableAuthorityBudgetBindings"
        )
        let requestExpansion = selector(
            ExecutionAndEventContractTests.self,
            "testRequestRejectsCapabilityAndBudgetExpansion"
        )
        let requestReferences = selector(
            ExecutionAndEventContractTests.self,
            "testRequestRejectsUnscopedArtifactAndSecretReferences"
        )
        let authorization = selector(
            ExecutionAndEventContractTests.self,
            "testAuthorizationReferenceCannotBeRebound"
        )
        let statusAndReceipt = selector(
            ExecutionAndEventContractTests.self,
            "testEveryStatusCommandAndReceiptCaseIsValidatedAndRoundTrips"
        )
        let result = selector(
            ExecutionAndEventContractTests.self,
            "testTerminalResultsAreStatusBoundAndTamperEvident"
        )
        let eventCases = selector(
            ExecutionAndEventContractTests.self,
            "testEveryEventCaseBuildsAContinuousHashChainAndReplaysFromCursor"
        )
        let eventFailures = selector(
            ExecutionAndEventContractTests.self,
            "testEventDigestSequenceAndTerminalPlacementFailClosed"
        )
        let collectionCases = selector(
            ExecutionAndEventContractTests.self,
            "testPublicContractInventoryExercisesCollectionAndCursorSemantics"
        )
        let start = selector(
            ProviderBehaviorTests.self,
            "testStartIsIdempotentAndConflictingReuseFails"
        )
        let observers = selector(
            ProviderBehaviorTests.self,
            "testMultipleObserversReceiveIdenticalEventsAndTerminalResultIsStable"
        )
        let detach = selector(
            ProviderBehaviorTests.self,
            "testDetachDoesNotCancelAndReattachReplaysAfterCursor"
        )
        let invalidCursor = selector(
            ProviderBehaviorTests.self,
            "testInvalidCursorFailsInsideStreamWithoutMutatingExecution"
        )
        let command = selector(
            ProviderBehaviorTests.self,
            "testCASIdempotentCommandsAndExplicitCancellation"
        )
        let failure = selector(
            ProviderBehaviorTests.self,
            "testFailureProducesOneConsistentTerminalEventStatusAndResult"
        )
        let schemaIDs = selector(
            PublicContractInventoryTests.self,
            "testAllPayloadSchemasAreNamespacedAndUnique"
        )

        var cases: [String: String] = [:]
        func add(_ ids: [String], selector: String) {
            for id in ids { cases[id] = selector }
        }

        add(SandboxFeature.allCases.map { "feature.\($0.rawValue)" }, selector: providerEnums)
        add(SandboxExecutionState.allCases.map { "status.\($0.rawValue)" }, selector: statusAndReceipt)
        add(SandboxCommandAction.allCases.map { "command.action.\($0.rawValue)" }, selector: statusAndReceipt)
        add(
            SandboxCommandDisposition.allCases.map { "command.disposition.\($0.rawValue)" },
            selector: statusAndReceipt
        )
        add(
            [
                "error.invalidValue", "error.providerIdentityMismatch",
                "error.descriptorFingerprintMismatch", "error.trustRevisionMismatch",
                "error.incompatibleProtocol", "error.capabilityReportBindingMismatch",
                "error.negotiatedCapabilityMismatch", "error.authorityOrBudgetExpansion",
                "error.requestBindingMismatch", "error.idempotencyConflict",
                "error.executionNotFound", "error.staleCommand", "error.invalidCursor",
                "error.invalidEventChain", "error.terminalExecution",
            ],
            selector: providerEnums
        )
        add(
            BudgetDimension.allCases.map { "attenuation.budget.\($0.rawValue)" },
            selector: negotiation
        )

        add(
            [
                "request.valid-round-trip", "request.protocol-version-binding",
                "request.unavailable-feature-rejected", "request.fingerprint-tamper-rejected",
                "request.derived-start-key",
            ],
            selector: requestRoundTrip
        )
        add(["request.authorization-binding"], selector: authorization)
        add(
            ["request.authority-expansion-rejected", "request.budget-expansion-rejected"],
            selector: requestExpansion
        )
        add(
            ["request.unscoped-artifact-rejected", "request.unscoped-secret-rejected"],
            selector: requestReferences
        )
        add(
            [
                "request.required-feature-derivation", "request.artifact-ordering",
                "request.raw-start-key",
            ],
            selector: collectionCases
        )

        add(
            [
                "command.target-binding", "command.expected-state-cas",
                "command.idempotent-duplicate", "command.idempotency-conflict",
                "command.protocol-binding", "command.explicit-cancellation",
                "command.terminal-rejection",
            ],
            selector: command
        )
        add(
            ["command.receipt-status-binding", "command.receipt-fingerprint-tamper-rejected"],
            selector: statusAndReceipt
        )

        add(
            [
                "event.case.accepted", "event.case.started", "event.case.progress",
                "event.case.audit", "event.case.artifactProduced",
                "event.case.checkpointCreated", "event.case.commandProcessed",
                "event.case.terminal", "event.agent-cursor",
            ],
            selector: eventCases
        )
        add(["event.sandbox-cursor"], selector: collectionCases)
        add(["event.invalid-cursor"], selector: invalidCursor)
        add(
            [
                "event.hash-chain", "event.sequence-continuity", "event.protocol-binding",
                "event.terminal-placement", "event.cumulative-usage-monotonic",
            ],
            selector: eventFailures
        )
        add(["event.terminal-result-binding"], selector: result)
        add(
            ["event.multiple-observers", "event.observation-ends-at-terminal"],
            selector: observers
        )
        add(
            ["event.detach-does-not-cancel", "event.reattach-from-cursor"],
            selector: detach
        )

        add(["result.completed", "result.stable-query"], selector: observers)
        add(["result.failed"], selector: failure)
        add(["result.cancelled"], selector: command)
        add(
            [
                "result.status-binding", "result.usage-binding",
                "result.fingerprint-tamper-rejected",
            ],
            selector: result
        )
        add(["result.artifact-ordering"], selector: collectionCases)

        add(["attenuation.protocol-version"], selector: protocolVersion)
        add(
            [
                "attenuation.provider-identity", "attenuation.descriptor-fingerprint",
                "attenuation.trust-revision", "attenuation.capability-report-binding",
            ],
            selector: identity
        )
        add(
            [
                "attenuation.features", "attenuation.maximum-concurrency",
                "attenuation.authority.capabilities", "attenuation.authority.destinations",
                "attenuation.authority.data-categories", "attenuation.authority.artifacts",
                "attenuation.authority.secrets", "attenuation.authority.workspaces",
                "attenuation.authority.checkpoints", "attenuation.authority.constraints",
                "attenuation.maximum-thermal-state",
            ],
            selector: negotiation
        )
        add(["attenuation.authority.missing-constraint-denies"], selector: missingConstraint)
        add(["attenuation.memory-pressure-response"], selector: memoryPressure)
        add(["attenuation.provider-downgrade-without-expansion"], selector: downgrade)

        add(["provider.descriptor"], selector: providerRoundTrip)
        add(
            [
                "provider.capabilities", "provider.start-idempotent", "provider.start-conflict",
                "provider.attach-missing",
            ],
            selector: start
        )
        add(["provider.attach-existing", "provider.handle.status"], selector: detach)
        add(["provider.handle.result", "provider.handle.events"], selector: observers)
        add(["provider.handle.send"], selector: command)

        add(["fingerprint.canonical-json"], selector: canonicalFingerprint)
        add(
            [
                "fingerprint.bounded-wire-preflight",
                "fingerprint.non-finite-and-non-ijson-rejected",
            ],
            selector: boundedFingerprint
        )
        add(["fingerprint.encoding-error-propagated"], selector: throwingFingerprint)
        add(["wire.namespaced-unique-schema-ids"], selector: schemaIDs)
        return cases
    }

    private func selector(_ type: Any.Type, _ method: String) -> String {
        "AgentSandboxAPITests.\(String(describing: type))/\(method)"
    }

    private func assertTestSelectorExists(_ selector: String) throws {
        let components = selector.split(separator: "/", omittingEmptySubsequences: false)
        XCTAssertEqual(components.count, 2, "Malformed test selector: \(selector)")
        guard components.count == 2,
              let suite = components[0].split(separator: ".").last,
              !components[1].isEmpty
        else { return }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("\(suite).swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("func \(components[1])("),
            "Inventory selector does not name an existing test: \(selector)"
        )
    }
}

private struct Inventory: Decodable {
    let schemaVersion: Int
    let documentID: String
    let documentType: String
    let families: [InventoryFamily]
}

private struct InventoryFamily: Decodable {
    let id: String
    let cases: [InventoryCase]
}

private struct InventoryCase: Decodable {
    let id: String
    let testSelectors: [String]
}
