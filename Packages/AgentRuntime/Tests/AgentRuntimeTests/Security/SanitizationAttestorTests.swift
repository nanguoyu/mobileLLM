// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class SanitizationAttestorTests: XCTestCase {
    func testAttestationMatchesIndependentHMACVectorAndValidates() throws {
        let attestor = try LocalSanitizationAttestor(
            key: Data(repeating: 0x0b, count: 32),
            policyRevision: 7
        )
        let redaction = try RedactionMetadata(
            classification: .publicMetadata,
            redactedFieldPaths: ["$.token", "$.password"],
            omittedByteCount: 17,
            policyVersion: 3,
            omittedContentDigest: StableDigest.sha256(Data("secret".utf8))
        )

        let first = try attestor.attest(
            value: CanonicalJSON(.object(["query": .string("example")])),
            redaction: redaction
        )
        let second = try attestor.attest(value: first.value, redaction: redaction)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.attestationDigest.rawValue,
            "41974ae87ffeea0bbd1f841aaa08ba2a1a96bed6fdc9a86ab1a85d4f7001ebd8"
        )
        XCTAssertNoThrow(try attestor.validate(first))
    }

    func testInitializerRejectsUnsafeKeyLengthsAndPolicyRevision() throws {
        XCTAssertThrowsError(
            try LocalSanitizationAttestor(key: Data(repeating: 1, count: 31), policyRevision: 1)
        ) { XCTAssertEqual($0 as? SanitizationAttestationError, .invalidKey) }
        XCTAssertThrowsError(
            try LocalSanitizationAttestor(key: Data(repeating: 1, count: 4_097), policyRevision: 1)
        ) { XCTAssertEqual($0 as? SanitizationAttestationError, .invalidKey) }
        XCTAssertThrowsError(
            try LocalSanitizationAttestor(key: Data(repeating: 1, count: 32), policyRevision: 0)
        ) { XCTAssertEqual($0 as? SanitizationAttestationError, .invalidPolicyRevision) }
    }

    func testValidationRejectsDifferentKeyPolicyAndAttestation() throws {
        let fixture = try AttestationFixture()
        let otherKey = try LocalSanitizationAttestor(
            key: Data(repeating: 0x24, count: 32),
            policyRevision: 7
        )
        XCTAssertThrowsError(try otherKey.validate(fixture.signed)) {
            XCTAssertEqual($0 as? SanitizationAttestationError, .invalidAttestation)
        }

        let otherPolicy = try LocalSanitizationAttestor(
            key: fixture.key,
            policyRevision: 8
        )
        XCTAssertThrowsError(try otherPolicy.validate(fixture.signed)) {
            XCTAssertEqual($0 as? SanitizationAttestationError, .policyRevisionMismatch)
        }

        let forgedDigest = try fixture.copy(
            attestationDigest: StableDigest.sha256(Data("forged".utf8))
        )
        XCTAssertThrowsError(try fixture.attestor.validate(forgedDigest)) {
            XCTAssertEqual($0 as? SanitizationAttestationError, .invalidAttestation)
        }
    }

    func testAttestationBindsEverySanitizationField() throws {
        let fixture = try AttestationFixture()
        let changedRedactions = [
            try RedactionMetadata(
                classification: .internalMetadata,
                redactedFieldPaths: fixture.signed.redaction.redactedFieldPaths,
                omittedByteCount: fixture.signed.redaction.omittedByteCount,
                policyVersion: fixture.signed.redaction.policyVersion,
                omittedContentDigest: fixture.signed.redaction.omittedContentDigest
            ),
            try RedactionMetadata(
                classification: .publicMetadata,
                redactedFieldPaths: ["$.different"],
                omittedByteCount: fixture.signed.redaction.omittedByteCount,
                policyVersion: fixture.signed.redaction.policyVersion,
                omittedContentDigest: fixture.signed.redaction.omittedContentDigest
            ),
            try RedactionMetadata(
                classification: .publicMetadata,
                redactedFieldPaths: fixture.signed.redaction.redactedFieldPaths,
                omittedByteCount: 18,
                policyVersion: fixture.signed.redaction.policyVersion,
                omittedContentDigest: fixture.signed.redaction.omittedContentDigest
            ),
            try RedactionMetadata(
                classification: .publicMetadata,
                redactedFieldPaths: fixture.signed.redaction.redactedFieldPaths,
                omittedByteCount: fixture.signed.redaction.omittedByteCount,
                policyVersion: 4,
                omittedContentDigest: fixture.signed.redaction.omittedContentDigest
            ),
            try RedactionMetadata(
                classification: .publicMetadata,
                redactedFieldPaths: fixture.signed.redaction.redactedFieldPaths,
                omittedByteCount: fixture.signed.redaction.omittedByteCount,
                policyVersion: fixture.signed.redaction.policyVersion,
                omittedContentDigest: StableDigest.sha256(Data("different".utf8))
            ),
        ]
        let changedValues = [
            try fixture.copy(value: CanonicalJSON(.object(["query": .string("changed")]))),
            try fixture.copy(policyRevision: 8),
        ] + changedRedactions.map { try! fixture.copy(redaction: $0) }

        for changed in changedValues {
            XCTAssertThrowsError(try fixture.attestor.validate(changed))
        }
    }

    func testAttestationBindsCanonicalSecretReferenceSet() throws {
        let attestor = try LocalSanitizationAttestor(
            key: Data(repeating: 0x61, count: 32),
            policyRevision: 1
        )
        let first = SecretReferenceID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let second = SecretReferenceID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let redaction = try RedactionMetadata(
            classification: .secret,
            redactedFieldPaths: ["$.credential"],
            omittedByteCount: 8,
            policyVersion: 1
        )
        let signed = try attestor.attest(
            value: CanonicalJSON(.object(["credential": .string("secret-ref")])) ,
            referencedSecretIDs: [second, first, second],
            redaction: redaction
        )
        XCTAssertEqual(signed.referencedSecretIDs, [first, second])
        XCTAssertNoThrow(try attestor.validate(signed))

        let removedReference = try SanitizedCanonicalJSON(
            value: signed.value,
            referencedSecretIDs: [first],
            redaction: signed.redaction,
            policyRevision: signed.policyRevision,
            attestationDigest: signed.attestationDigest
        )
        XCTAssertThrowsError(try attestor.validate(removedReference))
    }

    func testPolicyEngineFailsClosedForForgedPayloadAndCanonicalArguments() async throws {
        let fixture = try PolicyAttestationFixture()
        let engine = try DefaultApprovalPolicyEngine(
            policyVersion: 1,
            sanitizationValidator: fixture.attestor
        )

        for prepared in [fixture.forgedPayloadRequest, fixture.forgedArgumentsRequest] {
            let evaluation = engine.evaluate(
                prepared: prepared,
                trustedRunAuthority: fixture.trustedAuthority,
                feature: .notApplicable,
                interaction: .foregroundInteractive,
                candidateReceipts: [],
                at: fixture.now
            )
            XCTAssertEqual(evaluation.authorization.decision, .deny)
            XCTAssertEqual(evaluation.authorization.diagnostic, .policyUnavailable)

            do {
                _ = try await engine.bindLocalPolicy(
                    prepared: prepared,
                    approvalID: ApprovalID(),
                    trustedRunAuthority: fixture.trustedAuthority,
                    at: fixture.now
                )
                XCTFail("Forged sanitizer output must not bind executable authority")
            } catch {
                XCTAssertEqual(error as? ApprovalPolicyEngineError, .authorizationNotGranted)
            }
        }
    }
}

private struct AttestationFixture {
    let key = Data(repeating: 0x0b, count: 32)
    let attestor: LocalSanitizationAttestor
    let signed: SanitizedCanonicalJSON

    init() throws {
        attestor = try LocalSanitizationAttestor(key: key, policyRevision: 7)
        signed = try attestor.attest(
            value: CanonicalJSON(.object(["query": .string("example")])),
            redaction: RedactionMetadata(
                classification: .publicMetadata,
                redactedFieldPaths: ["$.token", "$.password"],
                omittedByteCount: 17,
                policyVersion: 3,
                omittedContentDigest: StableDigest.sha256(Data("secret".utf8))
            )
        )
    }

    func copy(
        value: CanonicalJSON? = nil,
        redaction: RedactionMetadata? = nil,
        policyRevision: UInt64? = nil,
        attestationDigest: StableDigest? = nil
    ) throws -> SanitizedCanonicalJSON {
        try SanitizedCanonicalJSON(
            value: value ?? signed.value,
            referencedSecretIDs: signed.referencedSecretIDs,
            redaction: redaction ?? signed.redaction,
            policyRevision: policyRevision ?? signed.policyRevision,
            attestationDigest: attestationDigest ?? signed.attestationDigest
        )
    }
}

private struct PolicyAttestationFixture {
    let attestor: LocalSanitizationAttestor
    let forgedPayloadRequest: PreparedExternalOperationRequest
    let forgedArgumentsRequest: PreparedExternalOperationRequest
    let trustedAuthority: TrustedRunAuthority
    let now = AgentTimestamp(rawValue: 1_000)

    init() throws {
        attestor = try LocalSanitizationAttestor(
            key: Data(repeating: 0x41, count: 32),
            policyRevision: 1
        )
        let body = try CanonicalJSON(.object(["query": .string("example")]))
        let redaction = try RedactionMetadata(classification: .sensitive, policyVersion: 1)
        let valid = try attestor.attest(value: body, redaction: redaction)
        let forged = try SanitizedCanonicalJSON(
            value: body,
            redaction: redaction,
            policyRevision: 1,
            attestationDigest: StableDigest.sha256(Data("forged".utf8))
        )
        let ceiling = RunCapabilityCeiling(authority: .empty)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: .empty)
        let runID = AgentRunID()
        trustedAuthority = try TrustedRunAuthority(
            runID: runID,
            ceiling: ceiling,
            policyRevision: 1
        )

        func request(
            payload: SanitizedCanonicalJSON,
            arguments: SanitizedCanonicalJSON
        ) throws -> PreparedExternalOperationRequest {
            let plan = try ExternalOperationPlan(
                kind: .localPure,
                subjectID: "security.attestation-test",
                canonicalArguments: arguments,
                payloadDigest: payload.fingerprint,
                effects: [AgentEffect.localPure],
                requiredCapabilities: AgentCapabilitySet([]),
                maximumRequestBytes: UInt64(payload.data.count),
                maximumResponseBytes: 1_024,
                timeoutMilliseconds: 1_000,
                retryPolicy: .never,
                idempotency: .pureRead,
                userPreview: ""
            )
            return try PreparedExternalOperationRequest(
                requestID: AgentRequestID(),
                runID: runID,
                conversationID: ConversationID(),
                stepID: AgentStepID(),
                plan: plan,
                payload: payload,
                capabilityGrant: grant
            )
        }

        forgedPayloadRequest = try request(payload: forged, arguments: valid)
        forgedArgumentsRequest = try request(payload: valid, arguments: forged)
    }
}
