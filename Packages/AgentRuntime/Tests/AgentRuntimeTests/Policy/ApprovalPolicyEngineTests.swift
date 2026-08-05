// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-AUTH-001
// TEST-ID: AHT-AUTH-003
// TEST-ID: AHT-TEST-002
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

    func testFullAccessAutoAuthorizesEveryOperation() throws {
        let engine = try makeApprovalEngine()
        for effect in AgentEffect.allCases {
            let fixture = try Fixture(effect: effect)
            let evaluation = engine.evaluate(
                prepared: fixture.prepared,
                trustedRunAuthority: fixture.trustedAuthority,
                interaction: .foregroundInteractive,
                candidateReceipts: [],
                at: fixture.now,
                approvalMode: .fullAccess
            )
            XCTAssertEqual(
                evaluation.authorization.decision,
                .authorizeLocalPolicy,
                "full access must auto-authorize \(effect.rawValue)"
            )
            XCTAssertEqual(evaluation.presentation.decision, .noPresentation)
            XCTAssertNil(evaluation.matchingReceipt)
        }
    }

    func testSafePresetAutoAuthorizesSafeOperationsAndAsksForUnsafe() throws {
        let engine = try makeApprovalEngine()
        for effect in [AgentEffect.localRead, .localWrite, .networkRead, .privateDataRead] {
            let fixture = try Fixture(effect: effect)
            let evaluation = engine.evaluate(
                prepared: fixture.prepared,
                trustedRunAuthority: fixture.trustedAuthority,
                interaction: .foregroundInteractive,
                candidateReceipts: [],
                at: fixture.now,
                approvalMode: .safePreset
            )
            XCTAssertEqual(
                evaluation.authorization.decision,
                .authorizeLocalPolicy,
                "safe preset must auto-authorize \(effect.rawValue)"
            )
        }

        // Online-model inference (externalCommunication to a model provider) is safe too.
        let modelFixture = try Fixture(
            effect: .externalCommunication,
            planKind: .modelProvider,
            destinationKind: .modelProvider,
            destinationIdentity: "openai.responses:svc-1:model-a"
        )
        let modelEvaluation = engine.evaluate(
            prepared: modelFixture.prepared,
            trustedRunAuthority: modelFixture.trustedAuthority,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: modelFixture.now,
            approvalMode: .safePreset
        )
        XCTAssertEqual(modelEvaluation.authorization.decision, .authorizeLocalPolicy)

        for effect in [AgentEffect.externalWrite, .unknownExternal, .destructive, .financial, .codeExecution] {
            let fixture = try Fixture(effect: effect)
            let evaluation = engine.evaluate(
                prepared: fixture.prepared,
                trustedRunAuthority: fixture.trustedAuthority,
                interaction: .foregroundInteractive,
                candidateReceipts: [],
                at: fixture.now,
                approvalMode: .safePreset
            )
            XCTAssertEqual(
                evaluation.authorization.decision,
                .requireApproval,
                "safe preset must still ask for \(effect.rawValue)"
            )
        }
    }

    func testAskModeFallsThroughToDefaultPolicy() throws {
        let fixture = try Fixture(effect: .networkRead)
        let engine = try makeApprovalEngine()
        let viaMode = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: fixture.trustedAuthority,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: fixture.now,
            approvalMode: .ask
        )
        let viaBase = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: fixture.trustedAuthority,
            feature: .enabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: fixture.now
        )
        XCTAssertEqual(viaMode.authorization.decision, viaBase.authorization.decision)
        XCTAssertEqual(viaMode.authorization.decision, .requireApproval)
    }

    /// Spec §15.2: a conversation-scoped ONLINE-MODEL receipt reuses across later messages in the same
    /// conversation (same service destination/data scope, different prompt payload), never across a
    /// different service or conversation.
    func testConversationScopedModelReceiptReusesAcrossMessages() throws {
        func modelFixture(
            offset: Int,
            conversationID: ConversationID? = nil,
            identity: String,
            suffix: String = ""
        ) throws -> Fixture {
            try Fixture(
                effect: .externalCommunication,
                runOffset: offset,
                conversationID: conversationID,
                planKind: .modelProvider,
                destinationKind: .modelProvider,
                destinationIdentity: identity,
                payloadSuffix: suffix
            )
        }

        let first = try modelFixture(offset: 0, identity: "openai.responses:svc-1:model-a")
        let engine = try makeApprovalEngine()
        let receipt = try ApprovalReceipt(
            id: first.approvalID,
            prepared: first.prepared,
            decision: .approved,
            scope: .conversation,
            policyVersion: 1,
            decidedAt: first.now,
            expiresAt: AgentTimestamp(rawValue: first.now.rawValue + 10_000)
        )
        // The receipt must survive a durable round trip (conversation + externalCommunication is legal
        // only for a modelProvider destination).
        let decoded = try JSONDecoder().decode(
            ApprovalReceipt.self,
            from: JSONEncoder().encode(receipt)
        )
        XCTAssertEqual(decoded.scope, .conversation)

        // Second message, different payload, same conversation + service: reuse without asking.
        let second = try modelFixture(
            offset: 100,
            conversationID: first.conversationID,
            identity: "openai.responses:svc-1:model-a",
            suffix: "-second-message"
        )
        let reused = engine.evaluate(
            prepared: second.prepared,
            trustedRunAuthority: second.trustedAuthority,
            interaction: .foregroundInteractive,
            candidateReceipts: [decoded],
            at: second.now,
            approvalMode: .ask
        )
        XCTAssertEqual(reused.authorization.decision, .authorizeMatchingReceipt)
        XCTAssertEqual(reused.matchingReceipt, decoded)

        // A different service destination must not inherit the receipt.
        let otherService = try modelFixture(
            offset: 200,
            conversationID: first.conversationID,
            identity: "openai.responses:svc-2:model-b"
        )
        let otherServiceEvaluation = engine.evaluate(
            prepared: otherService.prepared,
            trustedRunAuthority: otherService.trustedAuthority,
            interaction: .foregroundInteractive,
            candidateReceipts: [decoded],
            at: otherService.now,
            approvalMode: .ask
        )
        XCTAssertEqual(otherServiceEvaluation.authorization.decision, .requireApproval)

        // A different conversation must not inherit the receipt either.
        let otherConversation = try modelFixture(
            offset: 300,
            identity: "openai.responses:svc-1:model-a"
        )
        let otherConversationEvaluation = engine.evaluate(
            prepared: otherConversation.prepared,
            trustedRunAuthority: otherConversation.trustedAuthority,
            interaction: .foregroundInteractive,
            candidateReceipts: [decoded],
            at: otherConversation.now,
            approvalMode: .ask
        )
        XCTAssertEqual(otherConversationEvaluation.authorization.decision, .requireApproval)
    }

    /// Mode auto-approval must be BINDABLE for non-local effects (online model, network reads under
    /// fullAccess/safePreset): `bindLocalPolicy` intentionally stays local-only, so the mode path uses
    /// `bindApprovalMode`, which still records a durable exact-invocation authorization.
    func testApprovalModeBindingWorksForNonLocalEffects() async throws {
        let fixture = try Fixture(
            effect: .externalCommunication,
            planKind: .modelProvider,
            destinationKind: .modelProvider,
            destinationIdentity: "openai.responses:svc-1:model-a"
        )
        let engine = try makeApprovalEngine()

        do {
            _ = try await engine.bindLocalPolicy(
                prepared: fixture.prepared,
                approvalID: fixture.approvalID,
                trustedRunAuthority: fixture.trustedAuthority,
                at: fixture.now
            )
            XCTFail("bindLocalPolicy must reject non-local effects")
        } catch ApprovalPolicyEngineError.notLocallyAuthorizable {
            // Expected: local-policy binding is deliberately local-only.
        }

        let authorized = try await engine.bindApprovalMode(
            prepared: fixture.prepared,
            approvalID: fixture.approvalID,
            trustedRunAuthority: fixture.trustedAuthority,
            at: fixture.now
        )
        XCTAssertEqual(authorized.prepared, fixture.prepared)
        XCTAssertEqual(authorized.authorization.decision, .approved)
        XCTAssertEqual(authorized.authorization.scope, .exactInvocation)
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

    func testAuthorityValidityDistinguishesRunCeilingAndStepGrantFailures() throws {
        let first = try Fixture(effect: .networkRead)
        let otherRun = try Fixture(effect: .networkRead, runOffset: 500)
        let engine = try makeApprovalEngine()

        // Trusted authority belongs to another run.
        let crossRun = engine.evaluate(
            prepared: first.prepared,
            trustedRunAuthority: otherRun.trustedAuthority,
            feature: .enabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [],
            at: first.now
        )
        XCTAssertEqual(crossRun.authorization.decision, .deny)
        XCTAssertEqual(crossRun.authorization.diagnostic, .outsideRunCeiling)
    }

    func testBindRejectsForgedSanitizationAttestations() async throws {
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
        let forged = try SanitizedCanonicalJSON(
            value: fixture.prepared.payload.value,
            referencedSecretIDs: fixture.prepared.payload.referencedSecretIDs,
            redaction: fixture.prepared.payload.redaction,
            policyRevision: 1,
            attestationDigest: StableDigest.sha256(Data("forged".utf8))
        )
        let forgedPrepared = try PreparedExternalOperationRequest(
            requestID: fixture.prepared.requestID,
            runID: fixture.prepared.runID,
            conversationID: fixture.prepared.conversationID,
            stepID: fixture.prepared.stepID,
            invocationID: fixture.prepared.invocationID,
            plan: fixture.prepared.plan,
            payload: forged,
            capabilityGrant: fixture.prepared.capabilityGrant
        )
        do {
            _ = try await engine.bind(
                prepared: forgedPrepared,
                receipt: receipt,
                trustedRunAuthority: fixture.trustedAuthority,
                at: fixture.now
            )
            XCTFail("Expected forged attestation to be rejected")
        } catch let error as AgentContractError {
            XCTAssertEqual(error, .authorizationDenied)
        }
    }

    func testReceiptClassificationFallbacksRetainFirstMismatchAcrossCandidates() throws {
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
        let future = AgentTimestamp(rawValue: fixture.now.rawValue + 1)
        let past = AgentTimestamp(rawValue: fixture.now.rawValue - 1)
        let otherConversation = try receiptByReplacing(
            "conversationID",
            with: encodedJSONValue(ConversationID(rawValue: RuntimeTestFixtures.uuid(6_000))),
            in: receipt
        )
        let otherConversation2 = try receiptByReplacing(
            "conversationID",
            with: encodedJSONValue(ConversationID(rawValue: RuntimeTestFixtures.uuid(6_001))),
            in: receipt
        )
        let wrongPolicy = try receiptByReplacing("policyVersion", with: 2, in: receipt)
        let wrongPolicy2 = try receiptByReplacing("policyVersion", with: 3, in: receipt)
        let notYetValid = try receiptByReplacing(
            "decidedAt",
            with: encodedJSONValue(future),
            in: receipt
        )
        let notYetValid2 = try receiptByReplacing(
            "decidedAt",
            with: encodedJSONValue(AgentTimestamp(rawValue: future.rawValue + 1)),
            in: receipt
        )
        let expired = try ApprovalReceipt(
            id: fixture.approvalID,
            prepared: fixture.prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: past,
            expiresAt: past
        )
        let wrongRequest = try receiptByReplacing(
            "requestID",
            with: encodedJSONValue(AgentRequestID(rawValue: RuntimeTestFixtures.uuid(6_010))),
            in: receipt
        )
        let wrongRequest2 = try receiptByReplacing(
            "requestID",
            with: encodedJSONValue(AgentRequestID(rawValue: RuntimeTestFixtures.uuid(6_011))),
            in: receipt
        )

        let scenarios: [[ApprovalReceipt]] = [
            [otherConversation, otherConversation2],
            [wrongPolicy, wrongPolicy2],
            [notYetValid, notYetValid2],
            [expired, expired],
            [wrongRequest, wrongRequest2],
        ]
        for candidates in scenarios {
            let evaluation = engine.evaluate(
                prepared: fixture.prepared,
                trustedRunAuthority: fixture.trustedAuthority,
                feature: .enabled,
                interaction: .foregroundInteractive,
                candidateReceipts: candidates,
                at: fixture.now
            )
            XCTAssertEqual(evaluation.authorization.decision, .requireApproval)
            XCTAssertNil(evaluation.matchingReceipt)
        }
    }

    func testNonApprovedReceiptForAnotherRequestNeverAuthorizes() throws {
        let fixture = try Fixture(effect: .networkRead)
        let otherRequest = try Fixture(
            effect: .networkRead,
            runOffset: 700,
            conversationID: fixture.conversationID
        )
        let engine = try makeApprovalEngine()
        let denied = try ApprovalReceipt(
            id: ApprovalID(rawValue: RuntimeTestFixtures.uuid(6_100)),
            prepared: otherRequest.prepared,
            decision: .denied,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: fixture.now
        )
        let evaluation = engine.evaluate(
            prepared: fixture.prepared,
            trustedRunAuthority: fixture.trustedAuthority,
            feature: .enabled,
            interaction: .foregroundInteractive,
            candidateReceipts: [denied],
            at: fixture.now
        )
        XCTAssertEqual(evaluation.authorization.decision, .requireApproval)
        XCTAssertNil(evaluation.matchingReceipt)
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
        plan suppliedPlan: ExternalOperationPlan? = nil,
        planKind: ExternalOperationKind? = nil,
        destinationKind: ExternalDestination.Kind? = nil,
        destinationIdentity: String? = nil,
        payloadSuffix: String = ""
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
        let payloadValue = try CanonicalJSON(.object(["query": .string("example\(payloadSuffix)")]))
        let redaction = try RedactionMetadata(classification: .sensitive, policyVersion: 1)
        let payload = try testSanitizationAttestor.attest(
            value: payloadValue,
            redaction: redaction
        )
        let destination: ExternalDestination? = effect == .localPure
            ? nil
            : try ExternalDestination(
                kind: destinationKind ?? (effect == .privateDataRead ? .privateDataStore : .networkEndpoint),
                normalizedIdentity: destinationIdentity
                    ?? (effect == .privateDataRead ? "photos.library" : "https://example.com:443")
            )
        let capabilitySet = AgentCapabilitySet([effect.minimumCapability].compactMap { $0 })
        plan = try suppliedPlan ?? ExternalOperationPlan(
            kind: planKind
                ?? (effect == .localPure ? .localPure : (effect == .privateDataRead ? .privateData : .tool)),
            subjectID: "fixture.operation",
            destination: destination,
            payloadDigest: payload.fingerprint,
            effects: [effect],
            requiredCapabilities: capabilitySet,
            maximumRequestBytes: UInt64(max(4, payload.data.count)),
            maximumResponseBytes: 4_096,
            timeoutMilliseconds: 5_000,
            retryPolicy: .never,
            idempotency: [.localPure, .localRead, .networkRead, .privateDataRead].contains(effect)
                ? .pureRead
                : .nonIdempotent,
            userPreview: effect == .localPure
                ? ""
                : (effect == .externalCommunication ? "Send this conversation to model" : "Access example")
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
