// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) import AgentContracts
@testable import AgentSandboxAPI

enum SandboxTestValues {
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

    static func budget(limit: UInt64 = 1_000_000) -> AgentBudget {
        try! AgentBudget(
            limits: BudgetQuantities(
                Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map { ($0, limit) })
            ),
            maximumThermalState: .fair,
            memoryPressureResponse: .pause
        )
    }

    static func authority(
        capabilities: [AgentCapability] = [.codeExecution, .localRead, .localWrite],
        destinations: [ExternalDestination] = [],
        dataCategories: [AgentDataCategory] = [],
        artifactIDs: [ArtifactID] = [],
        secretIDs: [SecretReferenceID] = [],
        workspaceIDs: [SandboxWorkspaceHandleID] = [],
        checkpointIDs: [SandboxCheckpointHandleID] = [],
        constraints: [AgentAuthorityConstraint] = []
    ) -> AgentAuthorityScope {
        try! AgentAuthorityScope(
            capabilities: AgentCapabilitySet(capabilities),
            destinations: destinations,
            dataCategories: dataCategories,
            artifactIDs: artifactIDs,
            secretReferenceIDs: secretIDs,
            workspaceIDs: workspaceIDs,
            checkpointIDs: checkpointIDs,
            constraints: constraints
        )
    }

    static func descriptor(
        displayName: String = "Test Sandbox",
        implementationVersion: SemanticVersion = AgentContractVersion.currentProtocol,
        trustRevision: UInt64 = 7,
        versions: [SemanticVersion] = [AgentContractVersion.currentProtocol]
    ) throws -> AgentSandboxProviderDescriptor {
        try AgentSandboxProviderDescriptor(
            providerID: "test.sandbox",
            displayName: displayName,
            implementationVersion: implementationVersion,
            supportedProtocolVersions: versions,
            trustRevision: trustRevision
        )
    }

    static func capabilities(
        descriptor: AgentSandboxProviderDescriptor,
        features: [SandboxFeature] = SandboxFeature.allCases,
        authority: AgentAuthorityScope? = nil,
        budget: AgentBudget? = nil,
        maximumConcurrentExecutions: UInt16 = 4,
        versions: [SemanticVersion] = [AgentContractVersion.currentProtocol]
    ) throws -> SandboxCapabilities {
        try SandboxCapabilities(
            providerID: descriptor.providerID,
            descriptorFingerprint: descriptor.fingerprint,
            supportedProtocolVersions: versions,
            features: features,
            maximumAuthority: authority ?? self.authority(),
            maximumBudget: budget ?? self.budget(),
            maximumConcurrentExecutions: maximumConcurrentExecutions,
            reportRevision: 3
        )
    }

    static func policy(
        descriptor: AgentSandboxProviderDescriptor,
        features: [SandboxFeature] = SandboxFeature.allCases,
        authority: AgentAuthorityScope? = nil,
        budget: AgentBudget? = nil,
        maximumConcurrentExecutions: UInt16 = 2,
        versions: [SemanticVersion] = [AgentContractVersion.currentProtocol]
    ) throws -> RegisteredSandboxProviderPolicy {
        try RegisteredSandboxProviderPolicy(
            providerID: descriptor.providerID,
            descriptorFingerprint: descriptor.fingerprint,
            trustRevision: descriptor.trustRevision,
            allowedProtocolVersions: versions,
            allowedFeatures: features,
            maximumAuthority: authority ?? self.authority(),
            maximumBudget: budget ?? self.budget(),
            maximumConcurrentExecutions: maximumConcurrentExecutions,
            policyRevision: 11
        )
    }

    static func negotiated(
        descriptor: AgentSandboxProviderDescriptor? = nil,
        report: SandboxCapabilities? = nil,
        policy: RegisteredSandboxProviderPolicy? = nil
    ) throws -> (
        descriptor: AgentSandboxProviderDescriptor,
        report: SandboxCapabilities,
        policy: RegisteredSandboxProviderPolicy,
        negotiated: NegotiatedSandboxCapabilities
    ) {
        let descriptor = try descriptor ?? self.descriptor()
        let report = try report ?? capabilities(descriptor: descriptor)
        let policy = try policy ?? self.policy(descriptor: descriptor)
        return (
            descriptor,
            report,
            policy,
            try policy.negotiate(descriptor: descriptor, capabilities: report)
        )
    }

    static func sanitizedPayload(
        _ value: JSONValue = .object(["operation": .string("test")]),
        secretIDs: [SecretReferenceID] = []
    ) throws -> SanitizedCanonicalJSON {
        let classification: RedactionClassification = secretIDs.isEmpty ? .publicMetadata : .secret
        let redaction = try RedactionMetadata(
            classification: classification,
            redactedFieldPaths: secretIDs.isEmpty ? [] : ["$.credential"],
            omittedByteCount: secretIDs.isEmpty ? nil : 8,
            policyVersion: 1
        )
        return try SanitizedCanonicalJSON(
            value: CanonicalJSON(value),
            referencedSecretIDs: secretIDs,
            redaction: redaction,
            policyRevision: 1,
            attestationDigest: digest("e")
        )
    }

    static func request(
        negotiated: NegotiatedSandboxCapabilities? = nil,
        authority: AgentAuthorityScope? = nil,
        budget: AgentBudget? = nil,
        requiredFeatures: [SandboxFeature] = [.codeExecution, .cancellation]
    ) throws -> SandboxExecutionRequest {
        let negotiated = try negotiated ?? self.negotiated().negotiated
        let authority = authority ?? self.authority()
        let budget = budget ?? self.budget(limit: 10_000)
        let requirement = try SandboxRequirement(
            minimumProtocolVersion: negotiated.selectedProtocolVersion,
            authority: authority,
            budget: budget,
            process: SandboxProcessRequirement(
                maximumConcurrentProcesses: 1,
                maximumProcessLaunches: 2,
                allowedRuntimeIDs: ["test.runtime"]
            )
        )
        let grant = try StepCapabilityGrant(
            runCeiling: RunCapabilityCeiling(authority: authority),
            authority: authority
        )
        let payload = try sanitizedPayload()
        let authorization = SandboxAuthorizationReference(
            approvalID: id(ApprovalIDDomain.self, 4),
            requestID: id(AgentRequestIDDomain.self, 1),
            runID: id(AgentRunIDDomain.self, 2),
            stepID: id(AgentStepIDDomain.self, 3),
            sanitizedPayloadFingerprint: payload.fingerprint,
            externalPlanFingerprint: digest("b"),
            executionConstraintDigest: requirement.fingerprint,
            negotiatedCapabilitiesFingerprint: negotiated.fingerprint
        )
        return try SandboxExecutionRequest(
            requestID: id(AgentRequestIDDomain.self, 1),
            runID: id(AgentRunIDDomain.self, 2),
            stepID: id(AgentStepIDDomain.self, 3),
            requirement: requirement,
            stepGrant: grant,
            parentBudget: self.budget(),
            negotiatedCapabilities: negotiated,
            requiredFeatures: requiredFeatures,
            sanitizedPayload: payload,
            authorization: authorization
        )
    }

    static func status(
        handleID: SandboxExecutionHandleID,
        version: UInt64 = 1,
        state: SandboxExecutionState = .accepted,
        progress: AgentExecutionProgress? = nil,
        failure: AgentFailure? = nil,
        time: Int64 = 1_000
    ) throws -> SandboxExecutionStatus {
        try SandboxExecutionStatus(
            handleID: handleID,
            stateVersion: version,
            state: state,
            progress: progress,
            failure: failure,
            acceptedAt: AgentTimestamp(rawValue: 1_000),
            updatedAt: AgentTimestamp(rawValue: time)
        )
    }

    static func failure(_ classification: AgentFailureClassification = .permanent) throws -> AgentFailure {
        try AgentFailure(
            code: classification == .cancelled ? "sandbox.cancelled" : "sandbox.failed",
            classification: classification,
            safeMessage: classification == .cancelled ? "Execution cancelled" : "Execution failed",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
    }

    static func artifact(_ value: UInt16 = 40) throws -> ArtifactReference {
        try ArtifactReference(
            id: id(ArtifactIDDomain.self, value),
            contentDigest: digest("c"),
            byteCount: 12,
            mimeType: "text/plain",
            semanticType: "sandbox-output",
            provenance: ArtifactProvenance(
                runID: id(AgentRunIDDomain.self, 2),
                providerID: "test.sandbox"
            ),
            createdAt: AgentTimestamp(rawValue: 1_100),
            retentionPolicy: .run,
            locator: ArtifactLocator(
                kind: .providerOpaque,
                value: "output-\(value)",
                providerID: "test.sandbox"
            ),
            sensitivity: .publicMetadata,
            integrityStatus: .verified
        )
    }
}

func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func decoded<T: Decodable>(_ type: T.Type, from value: some Encodable) throws -> T {
    try JSONDecoder().decode(type, from: encodedJSON(value))
}

func replacingJSONField(in data: Data, path: [String], with replacement: Any) throws -> Data {
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
