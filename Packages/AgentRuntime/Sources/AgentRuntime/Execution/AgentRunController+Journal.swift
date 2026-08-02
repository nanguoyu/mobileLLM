// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

extension AgentRunController {
    struct CommittedEventBatch {
        let events: [AgentEventEnvelope]
        let receipt: RuntimeJournalMutationReceipt
    }

    func loadRun(
        _ runID: AgentRunID
    ) async throws -> (RuntimeRunFacts, ExecutionHistory) {
        guard let snapshot = try await repository.loadRunSnapshot(for: runID) else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        return (
            snapshot.facts,
            try ExecutionHistory(events: snapshot.events, projection: snapshot.facts.projection)
        )
    }

    @discardableResult
    func commitEvents(
        runID: AgentRunID,
        identity: RunJournalMutationIdentity,
        budgetOperations: [BudgetLedgerOperation] = [],
        build: (inout ExecutionEventBuilder) throws -> [AgentEventEnvelope]
    ) async throws -> CommittedEventBatch {
        guard let facts = try await repository.loadRunFacts(for: runID) else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        var builder = ExecutionEventBuilder(projection: facts.projection)
        let events = try build(&builder)
        let request = try RunJournalAppendRequest(
            mutationIdentity: identity,
            runID: runID,
            expectedRunStateVersion: facts.projection.stateVersion,
            events: events
        )
        let receipt = try await repository.commit(
            RuntimeJournalMutation(append: request, budgetOperations: budgetOperations)
        )
        switch receipt.appendReceipt.disposition {
        case .appended:
            broadcast(events, handleID: facts.projection.executionHandleID)
            return CommittedEventBatch(events: events, receipt: receipt)
        case .replayed:
            // The caller built against today's projection, but the mutation identity may have
            // committed against an older one. Never expose or broadcast those speculative values.
            // Resolve the exact first-commit batch from the durable receipt instead.
            guard let snapshot = try await repository.loadRunSnapshot(for: runID) else {
                throw AgentExecutionError.invalidRecoveryBoundary
            }
            let byID = Dictionary(uniqueKeysWithValues: snapshot.events.map {
                ($0.payload.eventID, $0)
            })
            let committed = try receipt.appendReceipt.eventIDs.map { eventID in
                guard let event = byID[eventID] else {
                    throw AgentExecutionError.invalidRecoveryBoundary
                }
                return event
            }
            return CommittedEventBatch(events: committed, receipt: receipt)
        case .stale:
            throw AgentExecutionError.invalidRecoveryBoundary
        case .rejected:
            throw AgentExecutionError.internalInvariant(
                "journal rejected event mutation: \(String(describing: receipt.appendReceipt.diagnostic))"
            )
        }
    }

    func nextEventID(
        _ builder: ExecutionEventBuilder,
        key: String,
        offset: UInt64 = 1
    ) -> AgentEventID {
        ExecutionStableID.event(
            runID: builder.runID,
            key: "\(key)-sequence-\(builder.sequence + offset)"
        )
    }

    func status(
        after builder: ExecutionEventBuilder,
        state: AgentRunState,
        terminalReason: AgentTerminalReason? = nil,
        failure: AgentFailure? = nil,
        blockingReason: AgentBlockingReason? = nil
    ) throws -> AgentRunStatus {
        let (version, overflow) = builder.stateVersion.addingReportingOverflow(1)
        guard !overflow else { throw AgentExecutionError.internalInvariant("state version overflow") }
        return try AgentRunStatus(
            state: state,
            stateVersion: version,
            terminalReason: terminalReason,
            failure: failure,
            blockingReason: blockingReason
        )
    }

    func commandFailure(
        code: String,
        message: String,
        classification: AgentFailureClassification = .permanent,
        action: AgentRequiredUserAction = .none
    ) throws -> AgentFailure {
        try AgentFailure(
            code: code,
            classification: classification,
            safeMessage: message,
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: action,
            redaction: Self.publicRedaction
        )
    }

    func stableReference(_ artifact: ArtifactReference, data: Data) throws
        -> AgentStableBoundaryReference
    {
        guard artifact.contentDigest == StableDigest.sha256(data) else {
            throw AgentExecutionError.internalInvariant("artifact digest mismatch")
        }
        return try AgentStableBoundaryReference(
            digest: artifact.contentDigest,
            artifactID: artifact.id
        )
    }

    func loadPayload<T: Decodable>(
        _ type: T.Type,
        reference: AgentStableBoundaryReference,
        maximumBytes: UInt64 = 8 * 1_024 * 1_024
    ) async throws -> T {
        guard let id = reference.artifactID,
              let artifact = await payloadStore.reference(for: id),
              artifact.contentDigest == reference.digest
        else { throw AgentExecutionError.invalidRecoveryBoundary }
        let data = try await payloadStore.load(artifact, maximumBytes: maximumBytes)
        guard StableDigest.sha256(data) == reference.digest else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        return try ExecutionEncoding.decode(type, from: data)
    }
}
