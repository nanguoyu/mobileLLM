// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

enum ExecutionEncoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try AgentWireDecoder.decode(
            type,
            from: data,
            limits: .contractEnvelope
        )
    }
}

enum ExecutionStableID {
    static func handle(request: AgentRequest, commandID: AgentCommandID) -> AgentExecutionHandleID {
        AgentExecutionHandleID(
            rawValue: uuid(
                domain: "execution-handle",
                components: [request.id.description, request.runID.description, commandID.description]
            )
        )
    }

    static func message(runID: AgentRunID, role: JournalMessageReference.Role) -> MessageID {
        MessageID(
            rawValue: uuid(
                domain: "message-\(role.rawValue)",
                components: [runID.description]
            )
        )
    }

    static func event(runID: AgentRunID, key: String, ordinal: UInt16 = 0) -> AgentEventID {
        AgentEventID(
            rawValue: uuid(
                domain: "event-\(key)",
                components: [runID.description, String(ordinal)]
            )
        )
    }

    static func commandEvent(
        runID: AgentRunID,
        commandID: AgentCommandID,
        ordinal: UInt16
    ) -> AgentEventID {
        event(runID: runID, key: "command-\(commandID.description)", ordinal: ordinal)
    }

    static func step(runID: AgentRunID, attempt: UInt64) -> AgentStepID {
        AgentStepID(
            rawValue: uuid(
                domain: "model-step",
                components: [runID.description, String(attempt)]
            )
        )
    }

    static func approval(runID: AgentRunID, invocationID: ToolInvocationID) -> ApprovalID {
        ApprovalID(
            rawValue: uuid(
                domain: "approval",
                components: [runID.description, invocationID.description]
            )
        )
    }

    static func reservation(
        runID: AgentRunID,
        kind: String,
        stableID: String
    ) -> BudgetReservationID {
        BudgetReservationID(
            rawValue: uuid(
                domain: "budget-\(kind)",
                components: [runID.description, stableID]
            )
        )
    }

    static func interactionMessage(
        runID: AgentRunID,
        requestID: InteractionRequestID
    ) -> MessageID {
        MessageID(
            rawValue: uuid(
                domain: "interaction-message",
                components: [runID.description, requestID.description]
            )
        )
    }

    private static func uuid(domain: String, components: [String]) -> UUID {
        let digest = StableDigest.fingerprint(
            domain: "mobilellm.execution-id.\(domain).v1",
            components: components.map { Data($0.utf8) }
        )
        let bytes = stride(from: 0, to: 32, by: 2).map { index -> UInt8 in
            let start = digest.rawValue.index(digest.rawValue.startIndex, offsetBy: index)
            let end = digest.rawValue.index(start, offsetBy: 2)
            return UInt8(digest.rawValue[start ..< end], radix: 16)!
        }
        var value = bytes
        value[6] = (value[6] & 0x0f) | 0x50
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }
}

struct ExecutionEventBuilder {
    let requestID: AgentRequestID
    let handleID: AgentExecutionHandleID
    let runID: AgentRunID
    private(set) var sequence: UInt64
    private(set) var stateVersion: UInt64
    private(set) var state: AgentRunState
    private(set) var timestamp: AgentTimestamp
    private(set) var usage: AgentUsage
    private(set) var previousDigest: StableDigest?

    init(projection: AgentRunProjection) {
        requestID = projection.requestID
        handleID = projection.executionHandleID
        runID = projection.runID
        sequence = projection.eventCount
        stateVersion = projection.stateVersion
        state = projection.state
        timestamp = projection.cursor.timestamp
        usage = projection.cumulativeUsage
        previousDigest = projection.cursor.recordDigest
    }

    init(
        requestID: AgentRequestID,
        handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        timestamp: AgentTimestamp
    ) {
        self.requestID = requestID
        self.handleID = handleID
        self.runID = runID
        sequence = 0
        stateVersion = 1
        state = .created
        self.timestamp = timestamp
        usage = .zero
        previousDigest = nil
    }

    mutating func append(
        id: AgentEventID,
        event: AgentEvent,
        transitionTo nextState: AgentRunState? = nil,
        statusVersion: UInt64? = nil,
        cumulativeUsage: AgentUsage? = nil,
        at proposedTimestamp: AgentTimestamp? = nil,
        redaction: RedactionMetadata
    ) throws -> AgentEventEnvelope {
        let (nextSequence, sequenceOverflow) = sequence.addingReportingOverflow(1)
        guard !sequenceOverflow else {
            throw AgentExecutionError.internalInvariant("event sequence overflow")
        }
        let eventState: AgentRunState
        let eventVersion: UInt64
        if let nextState {
            let (nextVersion, versionOverflow) = stateVersion.addingReportingOverflow(1)
            guard !versionOverflow,
                  AgentRunTransitionMatrix.allows(from: state, to: nextState)
            else { throw AgentExecutionError.internalInvariant("illegal runtime transition") }
            eventState = nextState
            eventVersion = statusVersion ?? nextVersion
            guard eventVersion == nextVersion else {
                throw AgentExecutionError.internalInvariant("state version gap")
            }
        } else {
            eventState = state
            eventVersion = statusVersion ?? stateVersion
            guard eventVersion == stateVersion else {
                throw AgentExecutionError.internalInvariant("nontransition changed state version")
            }
        }
        let nextTimestamp = try monotonicTimestamp(proposedTimestamp)
        let nextUsage = cumulativeUsage ?? usage
        let record = try AgentEventRecord(
            eventID: id,
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID,
            sequence: nextSequence,
            runStateVersion: eventVersion,
            runState: eventState,
            timestamp: nextTimestamp,
            event: event,
            redaction: redaction,
            cumulativeUsage: nextUsage,
            previousRecordDigest: previousDigest
        )
        sequence = nextSequence
        stateVersion = eventVersion
        state = eventState
        timestamp = nextTimestamp
        usage = nextUsage
        previousDigest = record.recordDigest
        return try AgentEventEnvelope(payload: record)
    }

    private func monotonicTimestamp(_ proposed: AgentTimestamp?) throws -> AgentTimestamp {
        guard sequence > 0 else { return proposed ?? timestamp }
        let (minimum, overflow) = timestamp.rawValue.addingReportingOverflow(1)
        guard !overflow else { throw AgentExecutionError.internalInvariant("timestamp overflow") }
        return AgentTimestamp(rawValue: max(minimum, proposed?.rawValue ?? minimum))
    }
}

actor ExecutionCancellationToken: ToolCancellationChecking {
    private var cancelled = false

    func cancel() { cancelled = true }
    func isCancelled() -> Bool { cancelled }
}

/// Binds the generic authorization gate to one exact durable run projection. SQLite validates
/// this scope and inserts the one-shot claim in the same write transaction.
struct ScopedExternalOperationAttemptLedger: ExternalOperationAttemptClaiming, Sendable {
    let repository: any RuntimeRepository
    let scope: RuntimeBoundaryClaimScope

    func claimBoundaryHop(
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool {
        do {
            return try await repository.claimBoundaryHop(
                scope: scope,
                approvalID: approvalID,
                preparedRequestFingerprint: preparedRequestFingerprint,
                attempt: attempt,
                hop: hop
            )
        } catch RuntimeRepositoryError.boundaryClaimStateMismatch {
            // A lifecycle command won the durable CAS before this gate. No boundary claim and no
            // adapter I/O occurred, so normalize it to the executor's interruption path.
            throw CancellationError()
        }
    }
}

/// Durable purpose of a compiled model context. This cannot be inferred from the advertised tool
/// list because an ordinary model pass can legitimately select zero tools.
enum ExecutionModelAttemptPurpose: String, Sendable {
    case standard
    case toolFreeSynthesis

    static let legacySemanticType = "agent-compiled-context.v1"
    static let standardSemanticType = "agent-compiled-context.standard.v1"
    static let synthesisSemanticType = "agent-compiled-context.synthesis.v1"

    init?(semanticType: String?) {
        switch semanticType {
        case Self.legacySemanticType, Self.standardSemanticType:
            self = .standard
        case Self.synthesisSemanticType:
            self = .toolFreeSynthesis
        default:
            return nil
        }
    }

    var semanticType: String {
        switch self {
        case .standard: Self.standardSemanticType
        case .toolFreeSynthesis: Self.synthesisSemanticType
        }
    }
}

struct ExecutionHistory: Sendable {
    let events: [AgentEventEnvelope]
    let status: AgentRunStatus
    let result: AgentResult?
    let modelOutcomes: [(AgentEventRecord, AgentModelAttemptOutcome)]
    let manifestEvents: [(
        AgentEventRecord,
        AgentStepID,
        AgentStableBoundaryReference,
        ExecutionModelAttemptPurpose
    )]
    let actionEvents: [(AgentEventRecord, AgentStepID, AgentStableBoundaryReference)]
    let toolIntents: [ToolInvocationID: (AgentEventRecord, PreparedExternalOperationRequest)]
    let toolOutcomes: [ToolInvocationID: (AgentEventRecord, AgentToolInvocationOutcome)]
    let approvals: [ApprovalID: (
        requestRecord: AgentEventRecord,
        request: AgentApprovalRequest,
        receiptRecord: AgentEventRecord?,
        receipt: ApprovalReceipt?
    )]
    let interactions: [InteractionRequestID: (
        request: UserInputRequest,
        response: AgentStableBoundaryReference?
    )]
    let diagnostics: [(AgentEventRecord, AgentFailure)]

    init(events: [AgentEventEnvelope], projection: AgentRunProjection) throws {
        var currentStatus = try AgentRunStatus(
            state: .created,
            stateVersion: 1
        )
        var result: AgentResult?
        var modelOutcomes: [(AgentEventRecord, AgentModelAttemptOutcome)] = []
        var manifests: [(
            AgentEventRecord,
            AgentStepID,
            AgentStableBoundaryReference,
            ExecutionModelAttemptPurpose
        )] = []
        var artifacts: [ArtifactID: ArtifactReference] = [:]
        var actions: [(AgentEventRecord, AgentStepID, AgentStableBoundaryReference)] = []
        var intents: [ToolInvocationID: (AgentEventRecord, PreparedExternalOperationRequest)] = [:]
        var outcomes: [ToolInvocationID: (AgentEventRecord, AgentToolInvocationOutcome)] = [:]
        var approvals: [ApprovalID: (
            AgentEventRecord,
            AgentApprovalRequest,
            AgentEventRecord?,
            ApprovalReceipt?
        )] = [:]
        var interactions: [InteractionRequestID: (UserInputRequest, AgentStableBoundaryReference?)] = [:]
        var diagnostics: [(AgentEventRecord, AgentFailure)] = []
        for envelope in events {
            let record = envelope.payload
            switch record.event {
            case .statusChanged(let value):
                currentStatus = value
            case .terminal(let value):
                result = value
                currentStatus = value.status
            case .modelAttemptOutcome(let value):
                modelOutcomes.append((record, value))
            case .compiledManifestCommitted(let stepID, let reference):
                guard let artifactID = reference.artifactID,
                      let artifact = artifacts[artifactID],
                      artifact.contentDigest == reference.digest,
                      let purpose = ExecutionModelAttemptPurpose(
                          semanticType: artifact.semanticType
                      )
                else { throw AgentExecutionError.invalidRecoveryBoundary }
                manifests.append((record, stepID, reference, purpose))
            case .validatedActionCommitted(let stepID, let reference):
                actions.append((record, stepID, reference))
            case .toolIntentRecorded(let request):
                if let invocationID = request.invocationID { intents[invocationID] = (record, request) }
            case .toolOutcomeRecorded(let invocationID, let outcome):
                outcomes[invocationID] = (record, outcome)
            case .approvalRequested(let request):
                approvals[request.id] = (record, request, nil, nil)
            case .approvalDecided(let receipt):
                if let existing = approvals[receipt.id] {
                    approvals[receipt.id] = (existing.0, existing.1, record, receipt)
                }
            case .userInputRequested(let request):
                interactions[request.id] = (request, nil)
            case .userInputResponseCommitted(let requestID, let reference):
                if let existing = interactions[requestID] {
                    interactions[requestID] = (existing.0, reference)
                }
            case .diagnostic(let failure):
                diagnostics.append((record, failure))
            case .artifactCommitted(let artifact):
                artifacts[artifact.id] = artifact
            case .runInputSnapshotCommitted, .usageUpdated:
                break
            }
        }
        guard currentStatus.state == projection.state,
              currentStatus.stateVersion == projection.stateVersion
        else { throw AgentExecutionError.invalidRecoveryBoundary }
        self.events = events
        status = currentStatus
        self.result = result
        self.modelOutcomes = modelOutcomes
        manifestEvents = manifests
        actionEvents = actions
        toolIntents = intents
        toolOutcomes = outcomes
        self.approvals = approvals
        self.interactions = interactions
        self.diagnostics = diagnostics
    }

    var repairCount: UInt64 {
        UInt64(diagnostics.lazy.filter { $0.1.code == "execution.structured-repair" }.count)
    }

}

extension AgentUsage {
    func adding(_ other: AgentUsage) throws -> AgentUsage {
        AgentUsage(quantities: try quantities.adding(other.quantities))
    }
}

enum ExecutionFailureFactory {
    static func make(
        reason: AgentTerminalReason,
        code: String,
        message: String
    ) throws -> AgentFailure {
        let classification: AgentFailureClassification
        let external: ExternalEffectDisposition
        let action: AgentRequiredUserAction
        switch reason {
        case .budgetExceeded:
            classification = .budgetRelated
            external = .confirmedNone
            action = .none
        case .permissionDenied:
            classification = .permissionRelated
            external = .confirmedNone
            action = .updateSystemPermission
        case .toolUnavailable, .modelUnavailable, .contextUnsatisfiable:
            classification = .incompatible
            external = .confirmedNone
            action = .restoreDependency
        case .externalResultUncertain:
            classification = .potentiallySideEffecting
            external = .uncertain
            action = .reconcile
        case .cancelledByUser:
            classification = .cancelled
            external = .confirmedNone
            action = .none
        case .completed:
            throw AgentExecutionError.internalInvariant("completion is not a failure")
        case .noProgress, .internalFailure:
            classification = .permanent
            external = .confirmedNone
            action = .none
        }
        return try AgentFailure(
            code: code,
            classification: classification,
            safeMessage: message,
            retryAdvice: .never,
            externalEffect: external,
            requiredUserAction: action,
            redaction: RedactionMetadata(
                classification: .publicMetadata,
                policyVersion: 1
            )
        )
    }

    static func uncertain(code: String, message: String) throws -> AgentFailure {
        try AgentFailure(
            code: code,
            classification: .potentiallySideEffecting,
            safeMessage: message,
            retryAdvice: .never,
            externalEffect: .uncertain,
            requiredUserAction: .reconcile,
            redaction: RedactionMetadata(
                classification: .publicMetadata,
                policyVersion: 1
            )
        )
    }
}
