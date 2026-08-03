// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

/// Exercises the fail-closed decoding paths that protect persisted and adapter-controlled values.
///
/// These tests intentionally start from valid encoded contracts and then tamper with one field. That
/// keeps each assertion focused on a cross-field invariant instead of merely feeding malformed JSON.
final class CriticalFailClosedWireTests: XCTestCase {
    func testFirstReleaseBudgetDefaultsFreezeEveryHardDimension() throws {
        let budget = try AgentBudget.firstReleaseDefaults(
            contextTokensPerAttempt: 4_096,
            outputTokens: 1_024,
            peakMemoryBytes: 512 * 1_024 * 1_024
        )

        XCTAssertEqual(budget.limits[.modelAttempts], 6)
        XCTAssertEqual(budget.limits[.toolInvocations], 3)
        XCTAssertEqual(budget.limits[.structuredRepairs], 1)
        XCTAssertEqual(budget.limits[.repeatedCallsPerFingerprint], 1)
        XCTAssertEqual(budget.limits[.consecutiveNoProgressActions], 2)
        XCTAssertEqual(budget.limits[.activeMilliseconds], 15 * 60 * 1_000)
        XCTAssertEqual(budget.limits[.inputTokens], 24_576)
        XCTAssertEqual(budget.limits[.outputTokens], 6_144,
                       "output budget is a run total sized for six model passes, each up to the ceiling")
        XCTAssertEqual(budget.limits[.contextTokensPerAttempt], 4_096)
        XCTAssertEqual(budget.limits[.networkRequestBytes], 8 * 1_024 * 1_024)
        XCTAssertEqual(budget.limits[.networkResponseBytesPerOperation], 2 * 1_024 * 1_024)
        XCTAssertEqual(budget.limits[.networkResponseBytesTotal], 8 * 1_024 * 1_024)
        XCTAssertEqual(budget.limits[.generatedArtifactBytes], 32 * 1_024 * 1_024)
        XCTAssertEqual(budget.limits[.persistedOutputBytes], 32 * 1_024 * 1_024)
        XCTAssertEqual(budget.limits[.peakMemoryBytes], 512 * 1_024 * 1_024)
        XCTAssertEqual(budget.maximumThermalState, .fair)
        XCTAssertEqual(budget.memoryPressureResponse, .pause)
    }

    func testAuthorityWireTamperingIsRejectedAtDecodeBoundary() throws {
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(AgentCapability.self, from: Data(#""Local.Read""#.utf8))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(
                AgentCapabilitySet.self,
                from: Data(#"["network.read","local.read"]"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(
                AgentAuthorityConstraint.self,
                from: Data(#"{"allowedValues":["z","a"],"key":"filesystem.paths"}"#.utf8)
            )
        )

        let first = TestValues.destination("a")
        let second = TestValues.destination("b")
        let scope = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            destinations: [first, second]
        )
        let noncanonicalScope = try reversingArrayField(in: encodedJSON(scope), key: "destinations")
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(AgentAuthorityScope.self, from: noncanonicalScope)
        )

        let ceiling = RunCapabilityCeiling(capabilities: AgentCapabilitySet([.localRead]))
        let grant = try StepCapabilityGrant(
            runCeiling: ceiling,
            capabilities: AgentCapabilitySet([.localRead])
        )
        let escalatedGrant = try replacingJSONField(
            in: encodedJSON(grant),
            path: ["authority", "capabilities"],
            with: [AgentCapability.networkRead.rawValue]
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(StepCapabilityGrant.self, from: escalatedGrant)
        )
    }

    func testArtifactAndFailureWireTamperingIsRejectedAtDecodeBoundary() throws {
        let locator = try ArtifactLocator(kind: .managedRelativePath, value: "runs/output.txt")
        let escapingLocator = try replacingJSONField(
            in: encodedJSON(locator), path: ["value"], with: "../outside"
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ArtifactLocator.self, from: escapingLocator)
        )

        let provenance = try ArtifactProvenance(
            runID: TestValues.id(AgentRunIDDomain.self, 1),
            stepID: TestValues.id(AgentStepIDDomain.self, 2)
        )
        let orphanedProvenance = try removingJSONField(in: encodedJSON(provenance), key: "runID")
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ArtifactProvenance.self, from: orphanedProvenance)
        )

        let invalidRetry = try replacingJSONField(
            in: encodedJSON(AgentRetryAdvice.never),
            path: ["automaticallyRetryable"],
            with: true
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(AgentRetryAdvice.self, from: invalidRetry)
        )

        let invalidFailure = try replacingJSONField(
            in: encodedJSON(TestValues.failure()), path: ["code"], with: "Not Namespaced"
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(AgentFailure.self, from: invalidFailure)
        )
    }

    func testCanonicalValueBoundariesRejectTamperedOrUnboundedRepresentations() throws {
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(StableDigest.self, from: Data(#""ABC""#.utf8))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(
                CanonicalJSON.self,
                from: encodedJSON(#"{"b":1,"a":2}"#)
            )
        )
        XCTAssertThrowsError(try encodedJSON(JSONValue.number(.infinity)))
        XCTAssertThrowsError(try AgentTimestamp(Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(
            try CanonicalJSON(.unsignedInteger(9_007_199_254_740_992))
        )

        let oversizedString = String(repeating: "x", count: CanonicalJSON.maximumBytes)
        XCTAssertThrowsError(try CanonicalJSON(.string(oversizedString)))
        XCTAssertThrowsError(
            try CanonicalJSON(canonicalData: Data(repeating: 0x20, count: CanonicalJSON.maximumBytes + 1))
        )
        XCTAssertEqual(try CanonicalJSON(.number(1.23e-5)).string, "0.0000123")

        let firstSecret = TestValues.id(SecretReferenceIDDomain.self, 3)
        let secondSecret = TestValues.id(SecretReferenceIDDomain.self, 4)
        let sanitized = try SanitizedCanonicalJSON(
            value: CanonicalJSON(.object(["ok": .bool(true)])),
            referencedSecretIDs: [firstSecret, secondSecret],
            redaction: RedactionMetadata(
                classification: .secret,
                redactedFieldPaths: ["$.credential"],
                omittedByteCount: 1,
                policyVersion: 1
            ),
            policyRevision: 1,
            attestationDigest: TestValues.digest("a")
        )
        let noncanonicalSecrets = try reversingArrayField(
            in: encodedJSON(sanitized), key: "referencedSecretIDs"
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(SanitizedCanonicalJSON.self, from: noncanonicalSecrets)
        )
    }

    func testExternalOperationTamperingCannotWidenPreparedAuthority() throws {
        let invalidDestination = try replacingJSONField(
            in: encodedJSON(TestValues.destination()),
            path: ["normalizedIdentity"],
            with: "\n"
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ExternalDestination.self, from: invalidDestination)
        )

        let invalidRetry = try replacingJSONField(
            in: encodedJSON(ExternalRetryPolicy.never),
            path: ["maximumAttempts"],
            with: 2
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ExternalRetryPolicy.self, from: invalidRetry)
        )

        let redirects = [TestValues.destination("redirect-a"), TestValues.destination("redirect-b")]
        let prepared = try TestValues.preparedRead(redirects: redirects)
        let reorderedPlan = try reversingArrayField(
            in: encodedJSON(prepared.plan), key: "allowedRedirects"
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ExternalOperationPlan.self, from: reorderedPlan)
        )

        let forgedPlan = try replacingJSONField(
            in: encodedJSON(prepared.plan),
            path: ["fingerprint"],
            with: TestValues.digest("f").rawValue
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ExternalOperationPlan.self, from: forgedPlan)
        )

        let forgedPayload = try replacingJSONField(
            in: encodedJSON(prepared), path: ["payload", "value"], with: #"{"query":"changed"}"#
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(PreparedExternalOperationRequest.self, from: forgedPayload)
        )
    }

    func testApprovalReceiptDecoderRejectsNoncanonicalExpiredAndUnsafeGrants() throws {
        let prepared = try TestValues.preparedRead(
            redirects: [TestValues.destination("redirect-a"), TestValues.destination("redirect-b")]
        )
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, 10),
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 100),
            expiresAt: AgentTimestamp(rawValue: 200)
        )

        let noncanonical = try reversingArrayField(
            in: encodedJSON(receipt), key: "allowedRedirects"
        )
        XCTAssertThrowsError(try AgentWireDecoder.decode(ApprovalReceipt.self, from: noncanonical))

        let expiredBeforeDecision = try replacingJSONField(
            in: encodedJSON(receipt),
            path: ["expiresAt"],
            with: 99
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ApprovalReceipt.self, from: expiredBeforeDecision)
        )

        var unsafeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedJSON(receipt)) as? [String: Any]
        )
        unsafeObject["scope"] = ApprovalScope.conversation.rawValue
        unsafeObject["effects"] = [AgentEffect.externalWrite.rawValue]
        let unsafeConversation = try JSONSerialization.data(
            withJSONObject: unsafeObject, options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ApprovalReceipt.self, from: unsafeConversation)
        )
    }

    func testSchemaAndToolBoundariesRejectForgedValues() throws {
        let numericSchema = try JSONSchemaDocument(root: .object([
            "type": .string("number"),
            "multipleOf": .number(0.5),
        ]))
        XCTAssertTrue(try numericSchema.validates(instance: .number(1.5)))
        XCTAssertFalse(try numericSchema.validates(instance: .number(1.6)))

        let logicalID = try AgentToolLogicalID(providerID: "local", name: "search")
        let invalidLogicalID = try replacingJSONField(
            in: encodedJSON(logicalID), path: ["name"], with: " "
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(AgentToolLogicalID.self, from: invalidLogicalID)
        )

        let descriptorID = try AgentToolDescriptorID(
            logicalID: logicalID,
            version: try XCTUnwrap(SemanticVersion("1.0.0")),
            schemaDigest: numericSchema.digest,
            trustRevision: "local-1"
        )
        let invalidDescriptorID = try replacingJSONField(
            in: encodedJSON(descriptorID), path: ["trustRevision"], with: ""
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(AgentToolDescriptorID.self, from: invalidDescriptorID)
        )

        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ToolTimeoutPolicy.self, from: Data("0".utf8))
        )

        let link = try ToolResourceLink(url: "https://example.invalid/result")
        let credentialedLink = try replacingJSONField(
            in: encodedJSON(link), path: ["url"], with: "https://user@example.invalid/result"
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ToolResourceLink.self, from: credentialedLink)
        )

        let progress = try ToolExecutionProgress(completedUnits: 1, totalUnits: 2)
        let regressedProgress = try replacingJSONField(
            in: encodedJSON(progress), path: ["totalUnits"], with: 0
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ToolExecutionProgress.self, from: regressedProgress)
        )
    }

    func testToolInlineResultLimitsAreReappliedDuringDecode() throws {
        let oversized = String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)
        XCTAssertThrowsError(try ToolTextResult(oversized))
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ToolTextResult.self, from: encodedJSON(oversized))
        )

        let structuredValue = try CanonicalJSON(.string(oversized))
        XCTAssertThrowsError(try ToolStructuredResult(structuredValue))
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(ToolStructuredResult.self, from: encodedJSON(structuredValue))
        )

        let half = String(repeating: "y", count: 1_100_000)
        let first = try ToolTextResult(half)
        let second = try ToolTextResult(half)
        XCTAssertThrowsError(
            try ToolResultCollection([.text(first), .text(second)])
        )
    }

    func testWirePreflightRejectsAmbiguousAndUnboundedStructures() throws {
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data([0xFF]))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data([0x22, 0x01, 0x22]))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data(#""unterminated"#.utf8))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data(#""key":1"#.utf8))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data(#"{"a":1,"a":2}"#.utf8))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data("}".utf8))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data("]".utf8))
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data("{".utf8))
        )

        let tinyLimits = try AgentWireDecodingLimits(
            maximumBytes: 32,
            maximumNestingDepth: 1,
            maximumCollectionItems: 1,
            maximumStringBytes: 2
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data("[[0]]".utf8), limits: tinyLimits)
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data("[0,1]".utf8), limits: tinyLimits)
        )
        XCTAssertThrowsError(
            try AgentWireDecoder.decode(JSONValue.self, from: Data(#""long""#.utf8), limits: tinyLimits)
        )
    }
}

private func reversingArrayField(in data: Data, key: String) throws -> Data {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let values = try XCTUnwrap(object[key] as? [Any])
    object[key] = Array(values.reversed())
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func removingJSONField(in data: Data, key: String) throws -> Data {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: key)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
