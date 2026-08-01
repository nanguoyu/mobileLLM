// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

enum TestValues {
    static func id<Domain: AgentIdentifierDomain>(
        _ type: Domain.Type = Domain.self,
        _ value: UInt16
    ) -> AgentIdentifier<Domain> {
        let string = String(format: "00000000-0000-4000-8000-%012x", value)
        return AgentIdentifier(rawValue: UUID(uuidString: string)!)
    }

    static func digest(_ character: Character = "a") -> StableDigest {
        try! StableDigest(rawValue: String(repeating: character, count: 64))
    }

    static func redaction(
        _ classification: RedactionClassification = .publicMetadata
    ) -> RedactionMetadata {
        try! RedactionMetadata(classification: classification, policyVersion: 1)
    }

    static func sanitized(_ value: CanonicalJSON) -> SanitizedCanonicalJSON {
        try! SanitizedCanonicalJSON(
            value: value,
            redaction: redaction(),
            policyRevision: 1,
            attestationDigest: digest("e")
        )
    }

    static func budget(limit: UInt64 = 1_000_000) -> AgentBudget {
        try! AgentBudget(
            limits: BudgetQuantities(
                Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map { ($0, limit) })
            ),
            maximumThermalState: .fair,
            memoryPressureResponse: .pause
        )
    }

    static func destination(_ suffix: String = "primary") -> ExternalDestination {
        try! ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://example.invalid/\(suffix)"
        )
    }

    static func category() -> AgentDataCategory {
        try! AgentDataCategory(rawValue: "user.query")
    }

    static func networkAuthority(
        destinations: [ExternalDestination]? = nil,
        secretIDs: [SecretReferenceID] = []
    ) -> AgentAuthorityScope {
        try! AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            destinations: destinations ?? [destination()],
            dataCategories: [category()],
            secretReferenceIDs: secretIDs
        )
    }

    static func preparedRead(
        payload: CanonicalJSON? = nil,
        destination: ExternalDestination = destination(),
        redirects: [ExternalDestination] = [],
        secret: SecretReference? = nil,
        requestID: AgentRequestID = id(AgentRequestIDDomain.self, 1),
        runID: AgentRunID = id(AgentRunIDDomain.self, 2),
        conversationID: ConversationID = id(ConversationIDDomain.self, 3),
        stepID: AgentStepID = id(AgentStepIDDomain.self, 4),
        invocationID: ToolInvocationID? = id(ToolInvocationIDDomain.self, 5),
        grantAuthority: AgentAuthorityScope? = nil
    ) throws -> PreparedExternalOperationRequest {
        let canonical = try payload ?? CanonicalJSON(.object(["query": .string("weather")]))
        let payload = sanitized(canonical)
        let authority = grantAuthority ?? networkAuthority(
            destinations: [destination] + redirects,
            secretIDs: secret.map { [$0.id] } ?? []
        )
        let ceiling = RunCapabilityCeiling(authority: authority)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: authority)
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: "test.web.read",
            destination: destination,
            allowedRedirects: redirects,
            dataCategories: [category()],
            payloadDigest: canonical.fingerprint,
            effects: [AgentEffect.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            maximumRequestBytes: 4_096,
            maximumResponseBytes: 8_192,
            timeoutMilliseconds: 5_000,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: "Read weather from example.invalid",
            descriptorID: "test.web.read@1",
            schemaDigest: digest("b"),
            trustRevision: "local-1",
            credentialReference: secret
        )
        return try PreparedExternalOperationRequest(
            requestID: requestID,
            runID: runID,
            conversationID: conversationID,
            stepID: stepID,
            invocationID: invocationID,
            plan: plan,
            payload: payload,
            capabilityGrant: grant
        )
    }

    static func observation(
        for prepared: PreparedExternalOperationRequest,
        destination: ExternalDestination? = nil,
        payloadDigest: StableDigest? = nil,
        idempotencyKey: ExternalIdempotencyKey? = nil,
        credentialReference: SecretReference? = nil
    ) throws -> ExternalOperationObservation {
        try ExternalOperationObservation(
            destination: destination ?? prepared.plan.destination,
            dataCategories: prepared.plan.dataCategories,
            effects: prepared.plan.effects,
            requestBytes: UInt64(prepared.payload.data.count),
            responseBytesLimit: prepared.plan.maximumResponseBytes,
            payloadDigest: payloadDigest ?? prepared.plan.payloadDigest,
            executionConstraintDigest: prepared.plan.executionConstraintDigest,
            artifactIDs: prepared.plan.artifactIDs,
            workspaceID: prepared.plan.workspaceID,
            descriptorID: prepared.plan.descriptorID,
            schemaDigest: prepared.plan.schemaDigest,
            trustRevision: prepared.plan.trustRevision,
            idempotencyKey: idempotencyKey ?? prepared.plan.idempotencyKey,
            credentialReference: credentialReference ?? prepared.plan.credentialReference,
            resolvedSecretReferenceIDs: (prepared.plan.canonicalArguments?.referencedSecretIDs ?? [])
                + [prepared.plan.credentialReference?.id].compactMap { $0 }
        )
    }

    static func failure(
        classification: AgentFailureClassification = .permanent,
        externalEffect: ExternalEffectDisposition = .confirmedNone,
        action: AgentRequiredUserAction = .none,
        retry: AgentRetryAdvice = .never
    ) -> AgentFailure {
        try! AgentFailure(
            code: "test.failure",
            classification: classification,
            safeMessage: "Safe failure",
            retryAdvice: retry,
            externalEffect: externalEffect,
            requiredUserAction: action,
            redaction: redaction()
        )
    }

    static func artifact(
        mimeType: String = "text/plain",
        locator: ArtifactLocator? = nil
    ) -> ArtifactReference {
        try! ArtifactReference(
            id: id(ArtifactIDDomain.self, 40),
            contentDigest: digest("c"),
            byteCount: 12,
            mimeType: mimeType,
            semanticType: "test-output",
            provenance: ArtifactProvenance(runID: id(AgentRunIDDomain.self, 2)),
            createdAt: AgentTimestamp(rawValue: 1_000),
            retentionPolicy: .run,
            locator: locator ?? ArtifactLocator(kind: .managedRelativePath, value: "runs/output.txt"),
            sensitivity: .publicMetadata,
            integrityStatus: .verified
        )
    }
}

func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

@discardableResult
func assertContractRoundTrip<T: Codable & Equatable>(
    _ value: T,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    let decoded = try AgentWireDecoder.decode(T.self, from: encodedJSON(value))
    XCTAssertEqual(decoded, value, file: file, line: line)
    return decoded
}

func replacingJSONField(
    in data: Data,
    path: [String],
    with replacement: Any
) throws -> Data {
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    func replace(_ object: inout [String: Any], remaining: ArraySlice<String>) {
        let key = remaining.first!
        if remaining.count == 1 {
            object[key] = replacement
            return
        }
        var child = object[key] as! [String: Any]
        replace(&child, remaining: remaining.dropFirst())
        object[key] = child
    }
    replace(&root, remaining: path[...])
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}
