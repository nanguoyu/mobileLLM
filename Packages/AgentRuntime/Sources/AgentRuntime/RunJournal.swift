// SPDX-License-Identifier: MIT

import AgentContracts

/// Stable identity used to deduplicate an atomic journal mutation.
public enum RunJournalMutationIdentity: Hashable, Codable, Sendable {
    /// User/lifecycle command identity.
    case command(AgentCommandID)
    /// Trusted callback outcome identity, represented by its globally unique event identity.
    case outcome(AgentEventID)
}

/// Structural failure in a journal protocol value.
public enum RunJournalContractError: Error, Hashable, Sendable {
    case invalidExpectedStateVersion
    case emptyEventBatch
    case eventOwnershipMismatch
    case duplicateEventIdentity
    case noncontiguousEventBatch
    case discontinuousEventBatch
    case eventStateVersionPrecedesExpectation
    case eventStateVersionGap
    case eventTimestampRegression
    case eventUsageRegression
    case illegalEventTransition
    case eventAfterTerminal
    case outcomeIdentityMissingFromBatch
    case invalidReadLimit
    case invalidPageCursor
    case invalidAppendReceipt
}

/// Atomic compare-and-swap append request. Concrete journals allocate no effects outside this call.
public struct RunJournalAppendRequest: Sendable {
    public let mutationIdentity: RunJournalMutationIdentity
    public let runID: AgentRunID
    public let expectedRunStateVersion: UInt64
    public let events: [AgentEventEnvelope]

    public init(
        mutationIdentity: RunJournalMutationIdentity,
        runID: AgentRunID,
        expectedRunStateVersion: UInt64,
        events: [AgentEventEnvelope]
    ) throws {
        guard expectedRunStateVersion > 0 else {
            throw RunJournalContractError.invalidExpectedStateVersion
        }
        guard let first = events.first else { throw RunJournalContractError.emptyEventBatch }
        guard first.payload.runID == runID else {
            throw RunJournalContractError.eventOwnershipMismatch
        }
        guard first.payload.runStateVersion >= expectedRunStateVersion else {
            throw RunJournalContractError.eventStateVersionPrecedesExpectation
        }
        let (nextExpectedVersion, versionOverflow) = expectedRunStateVersion.addingReportingOverflow(1)
        guard first.payload.runStateVersion == expectedRunStateVersion
                || (!versionOverflow && first.payload.runStateVersion == nextExpectedVersion)
        else { throw RunJournalContractError.eventStateVersionGap }

        var eventIDs: Set<AgentEventID> = []
        var previous = first.payload
        for envelope in events {
            let record = envelope.payload
            guard record.runID == runID,
                  record.requestID == first.payload.requestID,
                  record.executionHandleID == first.payload.executionHandleID
            else { throw RunJournalContractError.eventOwnershipMismatch }
            guard eventIDs.insert(record.eventID).inserted else {
                throw RunJournalContractError.duplicateEventIdentity
            }
            if record.eventID != first.payload.eventID {
                guard !previous.runState.isTerminal else {
                    throw RunJournalContractError.eventAfterTerminal
                }
                let (expectedSequence, overflow) = previous.sequence.addingReportingOverflow(1)
                guard !overflow, record.sequence == expectedSequence else {
                    throw RunJournalContractError.noncontiguousEventBatch
                }
                guard record.previousRecordDigest == previous.recordDigest else {
                    throw RunJournalContractError.discontinuousEventBatch
                }
                guard record.timestamp >= previous.timestamp else {
                    throw RunJournalContractError.eventTimestampRegression
                }
                guard previous.cumulativeUsage.quantities.isComponentwiseAtMost(
                    record.cumulativeUsage.quantities
                ) else { throw RunJournalContractError.eventUsageRegression }
                try Self.validateTransition(from: previous, to: record)
                previous = record
            }
        }
        if case .outcome(let outcomeID) = mutationIdentity,
           !eventIDs.contains(outcomeID)
        {
            throw RunJournalContractError.outcomeIdentityMissingFromBatch
        }

        self.mutationIdentity = mutationIdentity
        self.runID = runID
        self.expectedRunStateVersion = expectedRunStateVersion
        self.events = events
    }

    private static func validateTransition(
        from previous: AgentEventRecord,
        to record: AgentEventRecord
    ) throws {
        if record.runState == previous.runState {
            if record.runStateVersion == previous.runStateVersion { return }
            let (nextVersion, overflow) = previous.runStateVersion.addingReportingOverflow(1)
            guard !overflow,
                  record.runStateVersion == nextVersion,
                  record.runState == .waitingForApproval || record.runState == .pausing
            else { throw RunJournalContractError.illegalEventTransition }
            return
        }
        let (nextVersion, overflow) = previous.runStateVersion.addingReportingOverflow(1)
        guard !overflow,
              record.runStateVersion == nextVersion,
              AgentRunTransitionMatrix.allows(from: previous.runState, to: record.runState)
        else { throw RunJournalContractError.illegalEventTransition }
    }
}

/// Durable outcome of an atomic journal append attempt.
public enum RunJournalAppendDisposition: String, CaseIterable, Hashable, Codable, Sendable {
    case appended
    case replayed
    case stale
    case rejected
}

/// Receipt returned by the journal after committing, replaying, or denying one mutation.
public struct RunJournalAppendReceipt: Hashable, Sendable {
    public let mutationIdentity: RunJournalMutationIdentity
    public let disposition: RunJournalAppendDisposition
    public let projection: AgentRunProjection
    public let eventIDs: [AgentEventID]
    public let diagnostic: AgentRunDecisionDiagnostic?

    public init(
        mutationIdentity: RunJournalMutationIdentity,
        disposition: RunJournalAppendDisposition,
        projection: AgentRunProjection,
        eventIDs: [AgentEventID] = [],
        diagnostic: AgentRunDecisionDiagnostic? = nil
    ) throws {
        guard Set(eventIDs).count == eventIDs.count else {
            throw RunJournalContractError.invalidAppendReceipt
        }
        switch disposition {
        case .appended, .replayed:
            guard !eventIDs.isEmpty, diagnostic == nil else {
                throw RunJournalContractError.invalidAppendReceipt
            }
        case .stale:
            guard eventIDs.isEmpty, diagnostic == .staleExpectedVersion else {
                throw RunJournalContractError.invalidAppendReceipt
            }
        case .rejected:
            guard eventIDs.isEmpty, diagnostic != nil else {
                throw RunJournalContractError.invalidAppendReceipt
            }
        }
        self.mutationIdentity = mutationIdentity
        self.disposition = disposition
        self.projection = projection
        self.eventIDs = eventIDs
        self.diagnostic = diagnostic
    }
}

/// Cursor-based bounded event read request.
public struct RunJournalReadRequest: Hashable, Sendable {
    public let runID: AgentRunID
    public let after: AgentEventCursor?
    public let limit: Int

    public init(runID: AgentRunID, after: AgentEventCursor? = nil, limit: Int = 256) throws {
        guard (1 ... 1_024).contains(limit) else {
            throw RunJournalContractError.invalidReadLimit
        }
        self.runID = runID
        self.after = after
        self.limit = limit
    }
}

/// One bounded, ordered journal page.
public struct RunJournalEventPage: Sendable {
    public let events: [AgentEventEnvelope]
    public let nextCursor: AgentEventCursor?
    public let reachedEnd: Bool

    public init(
        events: [AgentEventEnvelope],
        nextCursor: AgentEventCursor?,
        reachedEnd: Bool
    ) throws {
        guard events.last?.payload.cursor == nextCursor,
              (events.isEmpty ? nextCursor == nil : nextCursor != nil)
        else { throw RunJournalContractError.invalidPageCursor }
        self.events = events
        self.nextCursor = nextCursor
        self.reachedEnd = reachedEnd
    }
}

/// Persistence abstraction for canonical run events and materialized projections.
///
/// Implementations must perform deduplication, expected-version comparison, event append, projection
/// update, and any durable projection outbox write in one transaction.
public protocol RunJournal: Sendable {
    func loadProjection(for runID: AgentRunID) async throws -> AgentRunProjection?
    func append(_ request: RunJournalAppendRequest) async throws -> RunJournalAppendReceipt
    func readEvents(_ request: RunJournalReadRequest) async throws -> RunJournalEventPage
}
