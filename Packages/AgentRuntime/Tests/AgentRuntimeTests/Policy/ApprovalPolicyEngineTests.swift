// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class ApprovalPolicyEngineTests: XCTestCase {
    func testLocalPolicyAuthorizesWithoutUserPresentation() async throws {
        let fixture = try Fixture(effect: .localPure)
        let engine = try makeApprovalEngine()
        let evaluation = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: fixture.trustedAuthority,
            feature: .notApplicable,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: fixture.now
        )
        XCTAssertEqual(evaluation.authorization.decision, .authorizeLocalPolicy)
        XCTAssertEqual(evaluation.presentation.decision, .noPresentation)
        XCTAssertNil(evaluation.matchingReceipt)

        let authorized = try await engine.bindLocalPolicy(
            prepared: fixture.prepared,
            approvalID: fixture.approvalID,
            trustedRunAuthority: fixture.trustedAuthority,
            at: fixture.now
        )
        XCTAssertEqual(authorized.prepared, fixture.prepared)
        XCTAssertEqual(authorized.authorization.decision, .approved)
    }

    func testExternalReadRequiresApprovalThenReusesBoundConversationReceipt() async throws {
        let first = try Fixture(effect: .networkRead)
        let engine = try makeApprovalEngine()
        let initial = engine.evaluate(
            prepared: first.prepared,
            trustedRunAuthority: first.trustedAuthority,
            feature: .enabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: first.now
        )
        XCTAssertEqual(initial.authorization.decision, .requireApproval)
        XCTAssertEqual(initial.authorization.grantScope, .boundedConversationRead)
        XCTAssertEqual(initial.presentation.decision, .presentApproval)

        let receipt = try ApprovalReceipt(
            id: first.approvalID,
            prepared: first.prepared,
            decision: .approved,
            scope: .conversation,
            policyVersion: 1,
            decidedAt: first.now,
            expiresAt: AgentTimestamp(rawValue: first.now.rawValue + 10_000)
        )
        let second = try Fixture(
            effect: .networkRead,
            runOffset: 100,
            conversationID: first.conversationID,
            plan: first.plan
        )
        let reused = engine.evaluate(
            prepared: second.prepared,
            trustedRunAuthority: second.trustedAuthority,
            feature: .enabled,
            interaction: .background,
            candidateReceipts: [receipt],
            at: second.now
        )
        XCTAssertEqual(reused.authorization.decision, .authorizeMatchingReceipt)
        XCTAssertEqual(reused.authorization.grantScope, .boundedConversationRead)
        XCTAssertEqual(reused.matchingReceipt, receipt)
        XCTAssertEqual(reused.presentation.decision, .noPresentation)
        _ = try await engine.bind(
            prepared: second.prepared,
            receipt: receipt,
            trustedRunAuthority: second.trustedAuthority,
            at: second.now
        )
    }

    func testExactWriteReceiptCannotAuthorizeAnotherInvocationOrChangedPlan() throws {
        let fixture = try Fixture(effect: .externalWrite)
        let engine = try makeApprovalEngine()
        let receipt = try ApprovalReceipt(
            id: fixture.approvalID,
            prepared: fixture.prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: fixture.now
        )
        let other = try Fixture(
            effect: .externalWrite,
            runOffset: 200,
            conversationID: fixture.conversationID,
            plan: fixture.plan
        )
        let evaluation = engine.evaluate(
            prepared: other.prepared,
            trustedRunAuthority: other.trustedAuthority,
            feature: .enabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [receipt],
            at: other.now
        )
        XCTAssertEqual(evaluation.authorization.decision, .requireApproval)
        XCTAssertNil(evaluation.matchingReceipt)
        XCTAssertEqual(evaluation.authorization.grantScope, .exactInvocation)
    }

    func testDeniedAndCancelledCurrentRequestFailClosed() throws {
        for decision in [ApprovalDecision.denied, .cancelled] {
            let fixture = try Fixture(effect: .networkRead)
            let engine = try makeApprovalEngine()
            let receipt = try ApprovalReceipt(
                id: fixture.approvalID,
                prepared: fixture.prepared,
                decision: decision,
                scope: .exactInvocation,
                policyVersion: 1,
                decidedAt: fixture.now
            )
            let evaluation = engine.evaluate(
                prepared: fixture.prepared,
                trustedRunAuthority: fixture.trustedAuthority,
                feature: .enabled,
                interaction: .foregroundInteractive,
                candidateReceipts: [receipt],
                at: fixture.now
            )
            XCTAssertEqual(evaluation.authorization.decision, .deny)
            XCTAssertEqual(
                evaluation.authorization.diagnostic,
                decision == .denied ? .approvalDenied : .approvalCancelled
            )
        }
    }

    func testExpiredWrongPolicyAndMissingTrustNeverAuthorize() throws {
        let fixture = try Fixture(effect: .networkRead)
        let engine = try makeApprovalEngine()
        let expired = try ApprovalReceipt(
            id: fixture.approvalID,
            prepared: fixture.prepared,
            decision: .approved,
            scope: .conversation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 1),
            expiresAt: AgentTimestamp(rawValue: 2)
        )
        let expiredEvaluation = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: fixture.trustedAuthority,
            feature: .enabled,
            interaction: .background,
            candidateReceipts: [expired],
            at: fixture.now
        )
        XCTAssertEqual(expiredEvaluation.authorization.decision, .requireApproval)
        XCTAssertEqual(expiredEvaluation.presentation.decision, .deferApproval)

        let noTrust = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: nil,
            feature: .enabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: fixture.now
        )
        XCTAssertEqual(noTrust.authorization.decision, .deny)
        XCTAssertEqual(noTrust.authorization.diagnostic, .missingStepGrant)

        let revoked = try TrustedRunAuthority(
            runID: fixture.runID,
            ceiling: fixture.ceiling,
            policyRevision: 2
        )
        let revokedEvaluation = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: revoked,
            feature: .enabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: fixture.now
        )
        XCTAssertEqual(revokedEvaluation.authorization.decision, .deny)
        XCTAssertEqual(revokedEvaluation.authorization.diagnostic, .policyUnavailable)
    }

    func testFeatureGatePrecedesReceipts() throws {
        let fixture = try Fixture(effect: .localWrite)
        let engine = try makeApprovalEngine()
        let evaluation = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: fixture.trustedAuthority,
            feature: .disabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: fixture.now
        )
        XCTAssertEqual(evaluation.authorization.decision, .deny)
        XCTAssertEqual(evaluation.authorization.diagnostic, .featureDisabled)
    }

    func testBindRejectsExpiredReceiptAndExternalLocalPolicyBypass() async throws {
        let external = try Fixture(effect: .networkRead)
        let engine = try makeApprovalEngine()
        let expired = try ApprovalReceipt(
            id: external.approvalID,
            prepared: external.prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 1),
            expiresAt: AgentTimestamp(rawValue: 2)
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await engine.bind(
                prepared: external.prepared,
                receipt: expired,
                trustedRunAuthority: external.trustedAuthority,
                at: external.now
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await engine.bindLocalPolicy(
                prepared: external.prepared,
                approvalID: external.approvalID,
                trustedRunAuthority: external.trustedAuthority,
                at: external.now
            )
        }
        XCTAssertThrowsError(
            try DefaultApprovalPolicyEngine(
                policyVersion: 0,
                sanitizationValidator: testSanitizationAttestor
            )
        )
    }

    func testSystemPermissionAndAgentApprovalRemainIndependent() throws {
        let fixture = try Fixture(effect: .privateDataRead)
        let engine = try makeApprovalEngine()
        let appApproval = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: fixture.trustedAuthority,
            feature: .enabled,
            interaction: .background,
            candidateReceipts: [],
            at: fixture.now
        )
        XCTAssertEqual(appApproval.authorization.decision, .requireApproval)
        XCTAssertEqual(appApproval.presentation.decision, .deferApproval)
        XCTAssertEqual(
            ApprovalDecisionTables.systemAccess(.granted, interaction: .background).decision,
            .continue
        )
        XCTAssertEqual(
            ApprovalDecisionTables.systemAccess(.promptRequired, interaction: .background).decision,
            .waitForForeground
        )
        XCTAssertEqual(
            ApprovalDecisionTables.systemAccess(.denied, interaction: .foregroundInteractive).decision,
            .deny
        )
    }

    func testEveryReceiptBindingFieldFailsClosedWhenItDiffersFromPreparedOperation() throws {
        let fixture = try Fixture(effect: .networkRead)
        let engine = try makeApprovalEngine()
        let receipt = try ApprovalReceipt(
            id: fixture.approvalID,
            prepared: fixture.prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: fixture.now
        )
        let otherDestination = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://different.example:443"
        )
        let otherDigest = StableDigest.sha256(Data("different".utf8))
        let mismatches: [(String, Any)] = [
            // Run identity is enforced by the authorization contract even though the detailed
            // classifier deliberately reports the conservative plan-fingerprint fallback.
            ("runID", try encodedJSONValue(AgentRunID())),
            ("requestID", try encodedJSONValue(AgentRequestID())),
            ("invocationID", try encodedJSONValue(ToolInvocationID())),
            ("previewDigest", try encodedJSONValue(otherDigest)),
            ("argumentsDigest", try encodedJSONValue(otherDigest)),
            ("destination", try encodedJSONValue(otherDestination)),
            ("allowedRedirects", try encodedJSONValue([otherDestination])),
            ("allowedFallbacks", try encodedJSONValue([otherDestination])),
            ("dataCategories", try encodedJSONValue([
                AgentDataCategory(rawValue: "different.data")
            ])),
            ("artifactIDs", try encodedJSONValue([ArtifactID()])),
            ("workspaceID", try encodedJSONValue(SandboxWorkspaceHandleID())),
            ("authorityConstraints", try encodedJSONValue([
                AgentAuthorityConstraint(key: "different.constraint", allowedValues: ["value"])
            ])),
            ("effects", try encodedJSONValue([AgentEffect.externalWrite])),
            ("payloadDigest", try encodedJSONValue(otherDigest)),
            ("executionConstraintDigest", try encodedJSONValue(otherDigest)),
            ("descriptorID", "different.descriptor@1"),
            ("schemaDigest", try encodedJSONValue(otherDigest)),
            ("trustRevision", "different-trust"),
            ("idempotencyKey", try encodedJSONValue(
                ExternalIdempotencyKey.derive(components: [Data("different-key".utf8)])
            )),
            ("credentialReference", try encodedJSONValue(SecretReference(
                id: SecretReferenceID(),
                purpose: "different credential",
                providerID: "test"
            ))),
            ("planFingerprint", try encodedJSONValue(otherDigest)),
            ("preparedRequestFingerprint", try encodedJSONValue(otherDigest)),
            ("stepCapabilityGrantFingerprint", try encodedJSONValue(otherDigest)),
            ("runCapabilityCeilingFingerprint", try encodedJSONValue(otherDigest)),
        ]

        for (field, value) in mismatches {
            let candidate = try receiptByReplacing(field, with: value, in: receipt)
            let evaluation = engine.evaluate(
                prepared: fixture.prepared,
                trustedRunAuthority: fixture.trustedAuthority,
                feature: .enabled,
                interaction: .foregroundInteractive,
                candidateReceipts: [candidate],
                at: fixture.now
            )
            XCTAssertEqual(
                evaluation.authorization.decision,
                .requireApproval,
                "A receipt with mismatched \(field) must not authorize"
            )
            XCTAssertNil(evaluation.matchingReceipt, "Mismatched field: \(field)")
        }
    }

    func testReceiptClassificationRejectsConversationPolicyAndFutureDecisionMismatches() throws {
        let fixture = try Fixture(effect: .networkRead)
        let engine = try makeApprovalEngine()
        let receipt = try ApprovalReceipt(
            id: fixture.approvalID,
            prepared: fixture.prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: fixture.now
        )
        let candidates = try [
            receiptByReplacing("conversationID", with: encodedJSONValue(ConversationID()), in: receipt),
            receiptByReplacing("policyVersion", with: 2, in: receipt),
            receiptByReplacing(
                "decidedAt",
                with: encodedJSONValue(AgentTimestamp(rawValue: fixture.now.rawValue + 1)),
                in: receipt
            ),
        ]

        for candidate in candidates {
            let evaluation = engine.evaluate(
                prepared: fixture.prepared,
                trustedRunAuthority: fixture.trustedAuthority,
                feature: .enabled,
                interaction: .foregroundInteractive,
                candidateReceipts: [candidate],
                at: fixture.now
            )
            XCTAssertEqual(evaluation.authorization.decision, .requireApproval)
            XCTAssertNil(evaluation.matchingReceipt)
        }
    }

    func testUnknownExternalEffectUsesMostConservativeApprovalRule() throws {
        let fixture = try Fixture(effect: .unknownExternal)
        let evaluation = try makeApprovalEngine().evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: fixture.trustedAuthority,
            feature: .enabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: fixture.now
        )

        XCTAssertEqual(evaluation.authorization.decision, .requireApproval)
        XCTAssertEqual(evaluation.authorization.grantScope, .exactInvocation)
        XCTAssertTrue(evaluation.authorization.uncertainOnTransportLoss)
        XCTAssertEqual(evaluation.authorization.matchedRuleID, "AH-APPROVAL-AUTHORITY-021")
    }
}

private struct Fixture {
    let runID: AgentRunID
    let conversationID: ConversationID
    let approvalID: ApprovalID
    let plan: ExternalOperationPlan
    let prepared: PreparedExternalOperationRequest
    let ceiling: RunCapabilityCeiling
    let trustedAuthority: TrustedRunAuthority
    let now = AgentTimestamp(rawValue: 1_000)

    init(
        effect: AgentEffect,
        runOffset: Int = 0,
        conversationID: ConversationID? = nil,
        plan suppliedPlan: ExternalOperationPlan? = nil
    ) throws {
        func id<Domain>(_ value: Int, as: Domain.Type) -> AgentIdentifier<Domain>
            where Domain: AgentIdentifierDomain
        {
            AgentIdentifier<Domain>(
                rawValue: UUID(
                    uuidString: String(format: "00000000-0000-0000-0000-%012x", value + runOffset)
                )!
            )
        }
        runID = id(1, as: AgentRunIDDomain.self)
        self.conversationID = conversationID ?? id(2, as: ConversationIDDomain.self)
        approvalID = id(3, as: ApprovalIDDomain.self)
        let requestID = id(4, as: AgentRequestIDDomain.self)
        let stepID = id(5, as: AgentStepIDDomain.self)
        let invocationID = id(6, as: ToolInvocationIDDomain.self)
        let payloadValue = try CanonicalJSON(.object(["query": .string("example")]))
        let redaction = try RedactionMetadata(classification: .sensitive, policyVersion: 1)
        let payload = try testSanitizationAttestor.attest(
            value: payloadValue,
            redaction: redaction
        )
        let destination: ExternalDestination? = effect == .localPure
            ? nil
            : try ExternalDestination(
                kind: effect == .privateDataRead ? .privateDataStore : .networkEndpoint,
                normalizedIdentity: effect == .privateDataRead ? "photos.library" : "https://example.com:443"
            )
        let capabilitySet = AgentCapabilitySet([effect.minimumCapability].compactMap { $0 })
        plan = try suppliedPlan ?? ExternalOperationPlan(
            kind: effect == .localPure ? .localPure : (effect == .privateDataRead ? .privateData : .tool),
            subjectID: "fixture.operation",
            destination: destination,
            payloadDigest: payload.fingerprint,
            effects: [effect],
            requiredCapabilities: capabilitySet,
            maximumRequestBytes: UInt64(max(4, payload.data.count)),
            maximumResponseBytes: 4_096,
            timeoutMilliseconds: 5_000,
            retryPolicy: .never,
            idempotency: effect == .externalWrite || effect == .localWrite || effect == .unknownExternal
                ? .nonIdempotent
                : .pureRead,
            userPreview: effect == .localPure ? "" : "Access example"
        )
        let authorityScope = try AgentAuthorityScope(
            capabilities: plan.requiredCapabilities,
            destinations: [plan.destination].compactMap { $0 },
            dataCategories: plan.dataCategories,
            artifactIDs: plan.artifactIDs,
            secretReferenceIDs: [plan.credentialReference?.id].compactMap { $0 },
            workspaceIDs: [plan.workspaceID].compactMap { $0 },
            constraints: plan.authorityConstraints
        )
        ceiling = RunCapabilityCeiling(authority: authorityScope)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: authorityScope)
        prepared = try PreparedExternalOperationRequest(
            requestID: requestID,
            runID: runID,
            conversationID: self.conversationID,
            stepID: stepID,
            invocationID: invocationID,
            plan: plan,
            payload: payload,
            capabilityGrant: grant
        )
        trustedAuthority = try TrustedRunAuthority(
            runID: runID,
            ceiling: ceiling,
            policyRevision: 1
        )
    }
}

private let testSanitizationAttestor = try! LocalSanitizationAttestor(
    key: Data(repeating: 0xa7, count: 32),
    policyRevision: 1
)

private func makeApprovalEngine() throws -> DefaultApprovalPolicyEngine {
    try DefaultApprovalPolicyEngine(
        policyVersion: 1,
        sanitizationValidator: testSanitizationAttestor
    )
}

private func encodedJSONValue<Value: Encodable>(_ value: Value) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}

private func receiptByReplacing(
    _ field: String,
    with value: Any,
    in receipt: ApprovalReceipt
) throws -> ApprovalReceipt {
    let encoded = try JSONEncoder().encode(receipt)
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object[field] = value
    return try JSONDecoder().decode(
        ApprovalReceipt.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {}
}
