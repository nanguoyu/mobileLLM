// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Per-run serialization state for budget-settling tool commits (see `commitEventsSettling`).
struct ToolCommitGate {
    var inFlight = false
    var waiters: [CheckedContinuation<Void, Never>] = []
}

extension AgentRunController {
    struct CommittedEventBatch {
        let events: [AgentEventEnvelope]
        let receipt: RuntimeJournalMutationReceipt
    }

    func commitEvents(
        runID: AgentRunID,
        identity: RunJournalMutationIdentity,
        budgetOperations: [BudgetLedgerOperation] = [],
        build: (inout ExecutionEventBuilder) throws -> [AgentEventEnvelope]
    ) async throws -> CommittedEventBatch {
        try await commitEventsInner(
            runID: runID,
            identity: identity,
            budgetOperations: budgetOperations,
            build: build
        )
    }

    /// Variant that computes the budget settlement atomically with the append and retries on a
    /// stale head, so concurrent parallel tool outcomes can never build events against a stale
    /// cumulative-usage snapshot (which the journal rejects as usage regression).
    func commitEventsSettling(
        runID: AgentRunID,
        identity: RunJournalMutationIdentity,
        settle: (BudgetLedgerSnapshot) throws -> (
            BudgetLedgerSnapshot,
            [BudgetLedgerOperation]
        ),
        build: (inout ExecutionEventBuilder, BudgetLedgerSnapshot) throws -> [AgentEventEnvelope]
    ) async throws -> CommittedEventBatch {
        await waitForToolCommitGate(runID: runID)
        defer { releaseToolCommitGate(runID: runID) }
        for _ in 0 ..< 8 {
            guard let facts = try await repository.loadRunFacts(for: runID),
                  let currentLedger = facts.budgetLedger
            else { throw AgentExecutionError.invalidRecoveryBoundary }
            let (settled, operations) = try settle(currentLedger)
            var builder = ExecutionEventBuilder(projection: facts.projection)
            let events: [AgentEventEnvelope]
            do {
                events = try build(&builder, settled)
            } catch RunJournalContractError.eventUsageRegression {
                continue
            }
            let request: RunJournalAppendRequest
            do {
                request = try RunJournalAppendRequest(
                    mutationIdentity: identity,
                    runID: runID,
                    expectedRunStateVersion: facts.projection.stateVersion,
                    events: events
                )
            } catch RunJournalContractError.eventUsageRegression,
                    RunJournalContractError.discontinuousEventBatch
            {
                continue
            }
            let receipt = try await repository.commit(
                RuntimeJournalMutation(append: request, budgetOperations: operations)
            )
            switch receipt.appendReceipt.disposition {
            case .appended:
                broadcast(events, handleID: facts.projection.executionHandleID)
                return CommittedEventBatch(events: events, receipt: receipt)
            case .replayed:
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
                continue
            case .rejected:
                throw AgentExecutionError.internalInvariant(
                    "journal rejected event mutation: \(String(describing: receipt.appendReceipt.diagnostic))"
                )
            }
        }
        throw AgentExecutionError.invalidRecoveryBoundary
    }

    private func waitForToolCommitGate(runID: AgentRunID) async {
        if let gate = toolCommitGates[runID], gate.inFlight {
            await withCheckedContinuation { continuation in
                var updated = gate
                updated.waiters.append(continuation)
                toolCommitGates[runID] = updated
            }
        }
        var gate = toolCommitGates[runID] ?? ToolCommitGate()
        gate.inFlight = true
        toolCommitGates[runID] = gate
    }

    private func releaseToolCommitGate(runID: AgentRunID) {
        guard var gate = toolCommitGates[runID] else { return }
        gate.inFlight = false
        if !gate.waiters.isEmpty {
            let next = gate.waiters.removeFirst()
            toolCommitGates[runID] = gate
            next.resume()
        } else {
            toolCommitGates[runID] = nil
        }
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

    private func commitEventsInner(
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
