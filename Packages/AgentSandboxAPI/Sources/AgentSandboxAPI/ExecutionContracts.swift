// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Opaque, bounded identity used to deduplicate sandbox starts.
public struct SandboxStartIdempotencyKey: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: StableDigest

    public init(rawValue: StableDigest) { self.rawValue = rawValue }

    public init(requestFingerprint: StableDigest, callerScope: StableDigest) {
        rawValue = .fingerprint(
            domain: "agent-sandbox-start-idempotency.v1",
            components: [
                Data(requestFingerprint.rawValue.utf8),
                Data(callerScope.rawValue.utf8),
            ]
        )
    }

    public var description: String { rawValue.rawValue }
}

/// Non-secret reference to the trusted external-operation authorization that permits a start.
///
/// This value is an audit binding, not a bearer credential. The runtime remains responsible for
/// validating the actual approval receipt and trusted run authority immediately before `start`.
public struct SandboxAuthorizationReference: Hashable, Codable, Sendable {
    public let approvalID: ApprovalID
    public let requestID: AgentRequestID
    public let runID: AgentRunID
    public let stepID: AgentStepID
    public let sanitizedPayloadFingerprint: StableDigest
    public let externalPlanFingerprint: StableDigest
    public let executionConstraintDigest: StableDigest
    public let negotiatedCapabilitiesFingerprint: StableDigest

    public init(
        approvalID: ApprovalID,
        requestID: AgentRequestID,
        runID: AgentRunID,
        stepID: AgentStepID,
        sanitizedPayloadFingerprint: StableDigest,
        externalPlanFingerprint: StableDigest,
        executionConstraintDigest: StableDigest,
        negotiatedCapabilitiesFingerprint: StableDigest
    ) {
        self.approvalID = approvalID
        self.requestID = requestID
        self.runID = runID
        self.stepID = stepID
        self.sanitizedPayloadFingerprint = sanitizedPayloadFingerprint
        self.externalPlanFingerprint = externalPlanFingerprint
        self.executionConstraintDigest = executionConstraintDigest
        self.negotiatedCapabilitiesFingerprint = negotiatedCapabilitiesFingerprint
    }
}

/// Fully bounded, authorized sandbox start request.
public struct SandboxExecutionRequest: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.execution-request"

    public let requestID: AgentRequestID
    public let runID: AgentRunID
    public let stepID: AgentStepID
    public let requirement: SandboxRequirement
    public let stepGrant: StepCapabilityGrant
    public let parentBudget: AgentBudget
    public let negotiatedCapabilities: NegotiatedSandboxCapabilities
    public let protocolVersion: SemanticVersion
    public let requiredFeatures: [SandboxFeature]
    public let sanitizedPayload: SanitizedCanonicalJSON
    public let inputArtifacts: [ArtifactReference]
    public let authorization: SandboxAuthorizationReference
    public let fingerprint: StableDigest

    public init(
        requestID: AgentRequestID,
        runID: AgentRunID,
        stepID: AgentStepID,
        requirement: SandboxRequirement,
        stepGrant: StepCapabilityGrant,
        parentBudget: AgentBudget,
        negotiatedCapabilities: NegotiatedSandboxCapabilities,
        requiredFeatures: some Sequence<SandboxFeature>,
        sanitizedPayload: SanitizedCanonicalJSON,
        inputArtifacts: some Sequence<ArtifactReference> = [],
        authorization: SandboxAuthorizationReference
    ) throws {
        var requiredFeatureSet = Set(requiredFeatures)
        if !requirement.filesystem.isEmpty { requiredFeatureSet.insert(.filesystemRead) }
        if requirement.filesystem.contains(where: { $0.access == .readWrite }) {
            requiredFeatureSet.insert(.filesystemWrite)
        }
        if !requirement.networkDestinations.isEmpty { requiredFeatureSet.insert(.networkAccess) }
        if requirement.process != nil {
            requiredFeatureSet.insert(.processExecution)
            requiredFeatureSet.insert(.codeExecution)
        }
        if requirement.workspaceID != nil { requiredFeatureSet.insert(.workspaceReuse) }
        if requirement.checkpointID != nil { requiredFeatureSet.insert(.checkpointResume) }
        let features = requiredFeatureSet.sorted()
        let artifacts = Array(Set(inputArtifacts)).sorted { $0.id.description < $1.id.description }
        guard requirement.minimumProtocolVersion.major
                == negotiatedCapabilities.selectedProtocolVersion.major,
              !negotiatedCapabilities.selectedProtocolVersion.hasLowerSemanticPrecedence(
                  than: requirement.minimumProtocolVersion
              ),
              Set(features).isSubset(of: Set(negotiatedCapabilities.features)),
              authorization.requestID == requestID,
              authorization.runID == runID,
              authorization.stepID == stepID,
              authorization.sanitizedPayloadFingerprint == sanitizedPayload.fingerprint,
              authorization.executionConstraintDigest == requirement.fingerprint,
              authorization.negotiatedCapabilitiesFingerprint == negotiatedCapabilities.fingerprint
        else { throw AgentSandboxAPIError.requestBindingMismatch }
        guard requirement.authority.isSubset(of: stepGrant.authority),
              requirement.authority.isSubset(of: negotiatedCapabilities.maximumAuthority),
              artifacts.allSatisfy({ requirement.authority.artifactIDs.contains($0.id) }),
              Set(sanitizedPayload.referencedSecretIDs)
                .isSubset(of: Set(requirement.authority.secretReferenceIDs))
        else { throw AgentSandboxAPIError.authorityOrBudgetExpansion }
        do {
            _ = try parentBudget.attenuating(to: requirement.budget)
            _ = try negotiatedCapabilities.maximumBudget.attenuating(to: requirement.budget)
        } catch {
            throw AgentSandboxAPIError.authorityOrBudgetExpansion
        }

        self.requestID = requestID
        self.runID = runID
        self.stepID = stepID
        self.requirement = requirement
        self.stepGrant = stepGrant
        self.parentBudget = parentBudget
        self.negotiatedCapabilities = negotiatedCapabilities
        protocolVersion = negotiatedCapabilities.selectedProtocolVersion
        self.requiredFeatures = features
        self.sanitizedPayload = sanitizedPayload
        self.inputArtifacts = artifacts
        self.authorization = authorization
        fingerprint = try Self.makeFingerprint(
            requestID: requestID,
            runID: runID,
            stepID: stepID,
            requirement: requirement,
            stepGrant: stepGrant,
            parentBudget: parentBudget,
            negotiatedCapabilities: negotiatedCapabilities,
            protocolVersion: negotiatedCapabilities.selectedProtocolVersion,
            requiredFeatures: features,
            sanitizedPayload: sanitizedPayload,
            inputArtifacts: artifacts,
            authorization: authorization
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        let encodedFeatures = try container.decode([SandboxFeature].self, forKey: .requiredFeatures)
        let encodedArtifacts = try container.decode([ArtifactReference].self, forKey: .inputArtifacts)
        let encodedProtocolVersion = try container.decode(SemanticVersion.self, forKey: .protocolVersion)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                requestID: container.decode(AgentRequestID.self, forKey: .requestID),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                stepID: container.decode(AgentStepID.self, forKey: .stepID),
                requirement: container.decode(SandboxRequirement.self, forKey: .requirement),
                stepGrant: container.decode(StepCapabilityGrant.self, forKey: .stepGrant),
                parentBudget: container.decode(AgentBudget.self, forKey: .parentBudget),
                negotiatedCapabilities: container.decode(
                    NegotiatedSandboxCapabilities.self,
                    forKey: .negotiatedCapabilities
                ),
                requiredFeatures: encodedFeatures,
                sanitizedPayload: container.decode(SanitizedCanonicalJSON.self, forKey: .sanitizedPayload),
                inputArtifacts: encodedArtifacts,
                authorization: container.decode(SandboxAuthorizationReference.self, forKey: .authorization)
            )
            guard decoded.requiredFeatures == encodedFeatures,
                  decoded.inputArtifacts == encodedArtifacts,
                  decoded.protocolVersion == encodedProtocolVersion,
                  decoded.fingerprint == encodedFingerprint
            else {
                throw AgentSandboxAPIError.requestBindingMismatch
            }
            return decoded
        }
    }

    private struct FingerprintMaterial: Encodable {
        let requestID: AgentRequestID
        let runID: AgentRunID
        let stepID: AgentStepID
        let requirement: SandboxRequirement
        let stepGrant: StepCapabilityGrant
        let parentBudget: AgentBudget
        let negotiatedCapabilities: NegotiatedSandboxCapabilities
        let protocolVersion: SemanticVersion
        let requiredFeatures: [SandboxFeature]
        let sanitizedPayload: SanitizedCanonicalJSON
        let inputArtifacts: [ArtifactReference]
        let authorization: SandboxAuthorizationReference
    }

    private static func makeFingerprint(
        requestID: AgentRequestID,
        runID: AgentRunID,
        stepID: AgentStepID,
        requirement: SandboxRequirement,
        stepGrant: StepCapabilityGrant,
        parentBudget: AgentBudget,
        negotiatedCapabilities: NegotiatedSandboxCapabilities,
        protocolVersion: SemanticVersion,
        requiredFeatures: [SandboxFeature],
        sanitizedPayload: SanitizedCanonicalJSON,
        inputArtifacts: [ArtifactReference],
        authorization: SandboxAuthorizationReference
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-execution-request.v1",
            value: FingerprintMaterial(
                requestID: requestID,
                runID: runID,
                stepID: stepID,
                requirement: requirement,
                stepGrant: stepGrant,
                parentBudget: parentBudget,
                negotiatedCapabilities: negotiatedCapabilities,
                protocolVersion: protocolVersion,
                requiredFeatures: requiredFeatures,
                sanitizedPayload: sanitizedPayload,
                inputArtifacts: inputArtifacts,
                authorization: authorization
            )
        )
    }
}

/// Durable lifecycle state for one sandbox execution.
public enum SandboxExecutionState: String, CaseIterable, Hashable, Codable, Sendable {
    case accepted
    case running
    case cancellationRequested
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .accepted, .running, .cancellationRequested: false
        }
    }
}

/// Versioned, compare-and-swap addressable status for one durable execution.
public struct SandboxExecutionStatus: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.execution-status"

    public let handleID: SandboxExecutionHandleID
    public let protocolVersion: SemanticVersion
    public let stateVersion: UInt64
    public let state: SandboxExecutionState
    public let progress: AgentExecutionProgress?
    public let failure: AgentFailure?
    public let acceptedAt: AgentTimestamp
    public let updatedAt: AgentTimestamp
    public let fingerprint: StableDigest

    public init(
        handleID: SandboxExecutionHandleID,
        stateVersion: UInt64,
        state: SandboxExecutionState,
        progress: AgentExecutionProgress? = nil,
        failure: AgentFailure? = nil,
        acceptedAt: AgentTimestamp,
        updatedAt: AgentTimestamp,
        protocolVersion: SemanticVersion = AgentContractVersion.currentProtocol
    ) throws {
        guard stateVersion > 0,
              protocolVersion.major == AgentContractVersion.currentProtocol.major,
              updatedAt >= acceptedAt,
              progress == nil || state == .running || state == .cancellationRequested
        else { throw AgentSandboxAPIError.invalidValue("execution status") }
        switch state {
        case .accepted, .running, .cancellationRequested, .completed:
            guard failure == nil else { throw AgentSandboxAPIError.invalidValue("unexpected failure") }
        case .failed:
            guard let failure, failure.classification != .cancelled else {
                throw AgentSandboxAPIError.invalidValue("failed status")
            }
        case .cancelled:
            guard let failure, failure.classification == .cancelled else {
                throw AgentSandboxAPIError.invalidValue("cancelled status")
            }
        }
        self.handleID = handleID
        self.protocolVersion = protocolVersion
        self.stateVersion = stateVersion
        self.state = state
        self.progress = progress
        self.failure = failure
        self.acceptedAt = acceptedAt
        self.updatedAt = updatedAt
        fingerprint = try Self.makeFingerprint(
            handleID: handleID,
            protocolVersion: protocolVersion,
            stateVersion: stateVersion,
            state: state,
            progress: progress,
            failure: failure,
            acceptedAt: acceptedAt,
            updatedAt: updatedAt
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                handleID: container.decode(SandboxExecutionHandleID.self, forKey: .handleID),
                stateVersion: container.decode(UInt64.self, forKey: .stateVersion),
                state: container.decode(SandboxExecutionState.self, forKey: .state),
                progress: container.decodeIfPresent(AgentExecutionProgress.self, forKey: .progress),
                failure: container.decodeIfPresent(AgentFailure.self, forKey: .failure),
                acceptedAt: container.decode(AgentTimestamp.self, forKey: .acceptedAt),
                updatedAt: container.decode(AgentTimestamp.self, forKey: .updatedAt),
                protocolVersion: container.decode(SemanticVersion.self, forKey: .protocolVersion)
            )
            guard decoded.fingerprint == encodedFingerprint else {
                throw AgentSandboxAPIError.invalidValue("status fingerprint")
            }
            return decoded
        }
    }

    private struct FingerprintMaterial: Encodable {
        let handleID: SandboxExecutionHandleID
        let protocolVersion: SemanticVersion
        let stateVersion: UInt64
        let state: SandboxExecutionState
        let progress: AgentExecutionProgress?
        let failure: AgentFailure?
        let acceptedAt: AgentTimestamp
        let updatedAt: AgentTimestamp
    }

    private static func makeFingerprint(
        handleID: SandboxExecutionHandleID,
        protocolVersion: SemanticVersion,
        stateVersion: UInt64,
        state: SandboxExecutionState,
        progress: AgentExecutionProgress?,
        failure: AgentFailure?,
        acceptedAt: AgentTimestamp,
        updatedAt: AgentTimestamp
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-execution-status.v1",
            value: FingerprintMaterial(
                handleID: handleID,
                protocolVersion: protocolVersion,
                stateVersion: stateVersion,
                state: state,
                progress: progress,
                failure: failure,
                acceptedAt: acceptedAt,
                updatedAt: updatedAt
            )
        )
    }
}

/// Stable terminal result. It exists if and only if status is terminal.
public struct SandboxExecutionResult: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.execution-result"

    public let requestID: AgentRequestID
    public let handleID: SandboxExecutionHandleID
    public let protocolVersion: SemanticVersion
    public let terminalStatus: SandboxExecutionStatus
    public let structuredOutput: CanonicalJSON?
    public let artifacts: [ArtifactReference]
    public let finalWorkspaceID: SandboxWorkspaceHandleID?
    public let checkpointID: SandboxCheckpointHandleID?
    public let usage: AgentUsage
    public let fingerprint: StableDigest

    public init(
        requestID: AgentRequestID,
        handleID: SandboxExecutionHandleID,
        terminalStatus: SandboxExecutionStatus,
        structuredOutput: CanonicalJSON? = nil,
        artifacts: some Sequence<ArtifactReference> = [],
        finalWorkspaceID: SandboxWorkspaceHandleID? = nil,
        checkpointID: SandboxCheckpointHandleID? = nil,
        usage: AgentUsage = .zero
    ) throws {
        let artifacts = Array(Set(artifacts)).sorted { $0.id.description < $1.id.description }
        guard terminalStatus.handleID == handleID,
              terminalStatus.protocolVersion.major == AgentContractVersion.currentProtocol.major,
              terminalStatus.state.isTerminal,
              terminalStatus.state == .completed || structuredOutput == nil
        else { throw AgentSandboxAPIError.invalidValue("terminal result") }
        self.requestID = requestID
        self.handleID = handleID
        protocolVersion = terminalStatus.protocolVersion
        self.terminalStatus = terminalStatus
        self.structuredOutput = structuredOutput
        self.artifacts = artifacts
        self.finalWorkspaceID = finalWorkspaceID
        self.checkpointID = checkpointID
        self.usage = usage
        fingerprint = try Self.makeFingerprint(
            requestID: requestID,
            handleID: handleID,
            protocolVersion: terminalStatus.protocolVersion,
            terminalStatus: terminalStatus,
            structuredOutput: structuredOutput,
            artifacts: artifacts,
            finalWorkspaceID: finalWorkspaceID,
            checkpointID: checkpointID,
            usage: usage
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        let encodedArtifacts = try container.decode([ArtifactReference].self, forKey: .artifacts)
        let encodedProtocolVersion = try container.decode(SemanticVersion.self, forKey: .protocolVersion)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                requestID: container.decode(AgentRequestID.self, forKey: .requestID),
                handleID: container.decode(SandboxExecutionHandleID.self, forKey: .handleID),
                terminalStatus: container.decode(SandboxExecutionStatus.self, forKey: .terminalStatus),
                structuredOutput: container.decodeIfPresent(CanonicalJSON.self, forKey: .structuredOutput),
                artifacts: encodedArtifacts,
                finalWorkspaceID: container.decodeIfPresent(
                    SandboxWorkspaceHandleID.self,
                    forKey: .finalWorkspaceID
                ),
                checkpointID: container.decodeIfPresent(
                    SandboxCheckpointHandleID.self,
                    forKey: .checkpointID
                ),
                usage: container.decode(AgentUsage.self, forKey: .usage)
            )
            guard decoded.artifacts == encodedArtifacts,
                  decoded.protocolVersion == encodedProtocolVersion,
                  decoded.fingerprint == encodedFingerprint
            else {
                throw AgentSandboxAPIError.invalidValue("result fingerprint")
            }
            return decoded
        }
    }

    private struct FingerprintMaterial: Encodable {
        let requestID: AgentRequestID
        let handleID: SandboxExecutionHandleID
        let protocolVersion: SemanticVersion
        let terminalStatus: SandboxExecutionStatus
        let structuredOutput: CanonicalJSON?
        let artifacts: [ArtifactReference]
        let finalWorkspaceID: SandboxWorkspaceHandleID?
        let checkpointID: SandboxCheckpointHandleID?
        let usage: AgentUsage
    }

    private static func makeFingerprint(
        requestID: AgentRequestID,
        handleID: SandboxExecutionHandleID,
        protocolVersion: SemanticVersion,
        terminalStatus: SandboxExecutionStatus,
        structuredOutput: CanonicalJSON?,
        artifacts: [ArtifactReference],
        finalWorkspaceID: SandboxWorkspaceHandleID?,
        checkpointID: SandboxCheckpointHandleID?,
        usage: AgentUsage
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-execution-result.v1",
            value: FingerprintMaterial(
                requestID: requestID,
                handleID: handleID,
                protocolVersion: protocolVersion,
                terminalStatus: terminalStatus,
                structuredOutput: structuredOutput,
                artifacts: artifacts,
                finalWorkspaceID: finalWorkspaceID,
                checkpointID: checkpointID,
                usage: usage
            )
        )
    }
}

/// Explicit state-changing commands supported by the first protocol version.
public enum SandboxCommandAction: String, CaseIterable, Hashable, Codable, Sendable {
    case cancel
}

/// Idempotent, compare-and-swap command addressed to one durable execution.
public struct SandboxCommand: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.command"

    public let commandID: SandboxCommandID
    public let handleID: SandboxExecutionHandleID
    public let expectedStateVersion: UInt64
    public let action: SandboxCommandAction
    public let issuedAt: AgentTimestamp
    public let fingerprint: StableDigest

    public init(
        commandID: SandboxCommandID,
        handleID: SandboxExecutionHandleID,
        expectedStateVersion: UInt64,
        action: SandboxCommandAction,
        issuedAt: AgentTimestamp
    ) throws {
        guard expectedStateVersion > 0 else {
            throw AgentSandboxAPIError.invalidValue("command state version")
        }
        self.commandID = commandID
        self.handleID = handleID
        self.expectedStateVersion = expectedStateVersion
        self.action = action
        self.issuedAt = issuedAt
        fingerprint = .fingerprint(
            domain: "agent-sandbox-command.v1",
            components: [
                Data(commandID.description.utf8),
                Data(handleID.description.utf8),
                Data(String(expectedStateVersion).utf8),
                Data(action.rawValue.utf8),
                Data(String(issuedAt.rawValue).utf8),
            ]
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                commandID: container.decode(SandboxCommandID.self, forKey: .commandID),
                handleID: container.decode(SandboxExecutionHandleID.self, forKey: .handleID),
                expectedStateVersion: container.decode(UInt64.self, forKey: .expectedStateVersion),
                action: container.decode(SandboxCommandAction.self, forKey: .action),
                issuedAt: container.decode(AgentTimestamp.self, forKey: .issuedAt)
            )
            guard decoded.fingerprint == encodedFingerprint else {
                throw AgentSandboxAPIError.idempotencyConflict
            }
            return decoded
        }
    }
}

/// Durable outcome of applying or rejecting one command.
public enum SandboxCommandDisposition: String, CaseIterable, Hashable, Codable, Sendable {
    case accepted
    case stale
    case rejected
}

public struct SandboxCommandReceipt: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.command-receipt"

    public let commandID: SandboxCommandID
    public let commandFingerprint: StableDigest
    public let handleID: SandboxExecutionHandleID
    public let protocolVersion: SemanticVersion
    public let disposition: SandboxCommandDisposition
    public let currentStatus: SandboxExecutionStatus
    public let failure: AgentFailure?
    public let fingerprint: StableDigest

    public init(
        commandID: SandboxCommandID,
        commandFingerprint: StableDigest,
        handleID: SandboxExecutionHandleID,
        disposition: SandboxCommandDisposition,
        currentStatus: SandboxExecutionStatus,
        failure: AgentFailure? = nil
    ) throws {
        guard currentStatus.handleID == handleID,
              (disposition == .accepted) == (failure == nil)
        else { throw AgentSandboxAPIError.invalidValue("command receipt") }
        self.commandID = commandID
        self.commandFingerprint = commandFingerprint
        self.handleID = handleID
        protocolVersion = currentStatus.protocolVersion
        self.disposition = disposition
        self.currentStatus = currentStatus
        self.failure = failure
        fingerprint = try Self.makeFingerprint(
            commandID: commandID,
            commandFingerprint: commandFingerprint,
            handleID: handleID,
            protocolVersion: currentStatus.protocolVersion,
            disposition: disposition,
            currentStatus: currentStatus,
            failure: failure
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedProtocolVersion = try container.decode(SemanticVersion.self, forKey: .protocolVersion)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                commandID: container.decode(SandboxCommandID.self, forKey: .commandID),
                commandFingerprint: container.decode(StableDigest.self, forKey: .commandFingerprint),
                handleID: container.decode(SandboxExecutionHandleID.self, forKey: .handleID),
                disposition: container.decode(SandboxCommandDisposition.self, forKey: .disposition),
                currentStatus: container.decode(SandboxExecutionStatus.self, forKey: .currentStatus),
                failure: container.decodeIfPresent(AgentFailure.self, forKey: .failure)
            )
            guard decoded.protocolVersion == encodedProtocolVersion,
                  decoded.fingerprint == encodedFingerprint
            else { throw AgentSandboxAPIError.invalidValue("receipt fingerprint") }
            return decoded
        }
    }

    private struct FingerprintMaterial: Encodable {
        let commandID: SandboxCommandID
        let commandFingerprint: StableDigest
        let handleID: SandboxExecutionHandleID
        let protocolVersion: SemanticVersion
        let disposition: SandboxCommandDisposition
        let currentStatus: SandboxExecutionStatus
        let failure: AgentFailure?
    }

    private static func makeFingerprint(
        commandID: SandboxCommandID,
        commandFingerprint: StableDigest,
        handleID: SandboxExecutionHandleID,
        protocolVersion: SemanticVersion,
        disposition: SandboxCommandDisposition,
        currentStatus: SandboxExecutionStatus,
        failure: AgentFailure?
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-command-receipt.v1",
            value: FingerprintMaterial(
                commandID: commandID,
                commandFingerprint: commandFingerprint,
                handleID: handleID,
                protocolVersion: protocolVersion,
                disposition: disposition,
                currentStatus: currentStatus,
                failure: failure
            )
        )
    }
}

public typealias SandboxCommandEnvelope = AgentEnvelope<SandboxCommand>

/// An injected provider boundary. Open-source production code intentionally supplies no conformer.
public protocol AgentSandboxProvider: Sendable {
    var descriptor: AgentSandboxProviderDescriptor { get }
    func capabilities() async throws -> SandboxCapabilities
    func start(
        _ request: SandboxExecutionRequest,
        idempotencyKey: String
    ) async throws -> SandboxExecutionHandleID
    func attach(to id: SandboxExecutionHandleID) async throws -> any SandboxExecutionHandle
}

/// Durable handle whose observation lifetime is independent from execution lifetime.
public protocol SandboxExecutionHandle: Sendable {
    var id: SandboxExecutionHandleID { get }
    func events(after cursor: AgentEventCursor?) -> AsyncThrowingStream<SandboxEventEnvelope, Error>
    func status() async throws -> SandboxExecutionStatus
    func result() async throws -> SandboxExecutionResult?
    func send(_ command: SandboxCommandEnvelope) async throws -> SandboxCommandReceipt
}
