// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Durable, reconnectable execution surface used by the root agent today and future child agents.
public protocol AgentExecutor: Sendable {
    /// Submits one immutable request. Reusing `commandID` with the same request returns the
    /// original handle; reusing it with a different request fails closed.
    func submit(
        _ request: AgentRequest,
        commandID: AgentCommandID
    ) async throws -> AgentExecutionHandleID

    /// Reattaches to a previously submitted execution without starting or resuming it.
    func attach(to id: AgentExecutionHandleID) async throws -> any AgentExecutionHandle
}

/// A lightweight view of durable execution. Destroying a handle or an event subscription never
/// changes the run; only an explicit command may do so.
public protocol AgentExecutionHandle: Sendable {
    var id: AgentExecutionHandleID { get }

    /// Replays committed events after an optional cursor and then follows newly committed events.
    func events(
        after cursor: AgentEventCursor?
    ) -> AsyncThrowingStream<AgentEventEnvelope, Error>

    /// Subscribes to live-only model and tool activity. Events are never replayed or persisted;
    /// ending this stream only detaches the observer and never changes the run.
    func ephemeralEvents() async -> AsyncThrowingStream<AgentEphemeralEventEnvelope, Error>

    func status() async throws -> AgentRunStatus
    func result() async throws -> AgentResult?

    /// Durably admits and idempotently processes an explicitly targeted state-changing command.
    func send(_ command: AgentCommandEnvelope) async throws -> AgentCommandReceipt
}

/// Errors safe for clients of the reconnectable execution API to branch on.
public enum AgentExecutionError: Error, Hashable, Sendable {
    case requestRunAlreadyExists(AgentRunID)
    case submissionCommandConflict(AgentCommandID)
    case executionNotFound(AgentExecutionHandleID)
    case corruptExecutionBinding
    case cursorBelongsToAnotherExecution
    case cursorNotFound
    case cursorIntegrityMismatch
    case commandTargetsAnotherRun
    case commandLeaseUnavailable
    case dependencyUnavailable(String)
    case malformedModelAction
    case structuredRepairExhausted
    case toolBatchInvalid
    case toolUnavailable(AgentToolDescriptorID)
    case approvalUnavailable
    case interactionUnavailable
    case reconciliationUnavailable
    case budgetUnavailable
    case invalidRecoveryBoundary
    case ephemeralObserverLagged
    case internalInvariant(String)
}

/// Trusted wall-clock and bounded-delay source. Tests provide a virtual implementation.
public protocol AgentExecutionClock: AgentAuthorizationClock, Sendable {
    func sleep(milliseconds: UInt64) async throws
}

/// Production clock. Waiting uses cancellation-aware structured concurrency.
public struct SystemAgentExecutionClock: AgentExecutionClock, Sendable {
    public init() {}

    public func now() async throws -> AgentTimestamp { try AgentTimestamp(Date()) }

    public func sleep(milliseconds: UInt64) async throws {
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { throw AgentExecutionError.internalInvariant("delay overflow") }
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Frozen input resolver. Implementations may consult mutable app stores only while this method is
/// executing during submission; the returned value is persisted before execution begins.
public protocol AgentRunInputFreezing: Sendable {
    func freeze(_ request: AgentRequest) async throws -> FrozenAgentRunInputs
}

/// Artifact-backed stable-boundary storage used for sensitive bodies that do not belong in events.
public protocol AgentExecutionPayloadStoring: Sendable {
    func commit(
        data: Data,
        mimeType: String,
        semanticType: String,
        runID: AgentRunID,
        stepID: AgentStepID?,
        invocationID: ToolInvocationID?,
        owner: ArtifactOwner,
        sensitivity: RedactionClassification
    ) async throws -> ArtifactReference

    func load(_ reference: ArtifactReference, maximumBytes: UInt64) async throws -> Data

    func reference(for id: ArtifactID) async -> ArtifactReference?

    func toolArtifactWriter(
        runID: AgentRunID,
        stepID: AgentStepID,
        invocationID: ToolInvocationID
    ) async throws -> any ToolArtifactWriting
}

/// Runtime-local sanitizer. It returns authenticated, secret-reference-only canonical JSON.
public protocol AgentExecutionPayloadSanitizing: SanitizationAttestationValidating, Sendable {
    func sanitize(
        _ value: CanonicalJSON,
        referencedSecretIDs: [SecretReferenceID],
        redaction: RedactionMetadata
    ) throws -> SanitizedCanonicalJSON
}

extension LocalSanitizationAttestor: AgentExecutionPayloadSanitizing {
    public func sanitize(
        _ value: CanonicalJSON,
        referencedSecretIDs: [SecretReferenceID],
        redaction: RedactionMetadata
    ) throws -> SanitizedCanonicalJSON {
        try attest(
            value: value,
            referencedSecretIDs: referencedSecretIDs,
            redaction: redaction
        )
    }
}

/// Read-only source of reusable conversation-scoped receipts. Returned receipts are still fully
/// revalidated by `ApprovalPolicyEngine`; this store cannot authorize an operation.
public protocol AgentReusableApprovalProviding: Sendable {
    func candidateReceipts(
        conversationID: ConversationID,
        prepared: PreparedExternalOperationRequest
    ) async throws -> [ApprovalReceipt]
}

public struct EmptyReusableApprovalProvider: AgentReusableApprovalProviding, Sendable {
    public init() {}

    public func candidateReceipts(
        conversationID _: ConversationID,
        prepared _: PreparedExternalOperationRequest
    ) async throws -> [ApprovalReceipt] { [] }
}

/// Redacted operational logger used by both the controller and scoped tools.
public protocol AgentExecutionLogging: ToolRedactedLogging, Sendable {}

public struct NoOpAgentExecutionLogger: AgentExecutionLogging, Sendable {
    public init() {}
    public func record(code _: String, metadata _: [String: String]) async {}
}
