// SPDX-License-Identifier: MIT

import AgentContracts

/// Deterministic replay failure for a journal event sequence.
public enum AgentRunProjectionReplayError: Error, Hashable, Sendable {
    case initialSequenceMustBeOne
    case duplicateEventIdentity(AgentEventID)
    case eventAfterTerminal
    case streamIdentityMismatch
    case sequenceOverflow
    case noncontiguousSequence(expected: UInt64, actual: UInt64)
    case stateVersionRegression
    case stateVersionGap
    case illegalStateTransition(from: AgentRunState, to: AgentRunState)
    case illegalSelfTransition(state: AgentRunState)
    case timestampRegression
    case usageRegression
    case hashChainMismatch
    case terminalEventMismatch
}

/// UI-neutral run state reconstructed solely from committed event envelopes.
///
/// The projection owns no controller, database, model, tool, or platform object. Applying the same
/// ordered envelopes always produces an equal value.
public struct AgentRunProjection: Hashable, Sendable {
    public let requestID: AgentRequestID
    public let executionHandleID: AgentExecutionHandleID
    public let runID: AgentRunID
    public let cursor: AgentEventCursor
    public let observedEventIDs: Set<AgentEventID>

    public var state: AgentRunState { cursor.runState }
    public var stateVersion: UInt64 { cursor.runStateVersion }
    public var eventCount: UInt64 { cursor.sequence }
    public var cumulativeUsage: AgentUsage { cursor.cumulativeUsage }
    public var isTerminal: Bool { cursor.isTerminal }

    private init(
        requestID: AgentRequestID,
        executionHandleID: AgentExecutionHandleID,
        runID: AgentRunID,
        cursor: AgentEventCursor,
        observedEventIDs: Set<AgentEventID>
    ) {
        self.requestID = requestID
        self.executionHandleID = executionHandleID
        self.runID = runID
        self.cursor = cursor
        self.observedEventIDs = observedEventIDs
    }

    /// Replays a complete event stream. An empty journal has no projection.
    public static func replay(_ envelopes: [AgentEventEnvelope]) throws -> Self? {
        guard let first = envelopes.first else { return nil }
        var projection = try initial(first)
        for envelope in envelopes.dropFirst() {
            projection = try projection.applying(envelope)
        }
        return projection
    }

    /// Applies one contiguous journal page to this projection.
    public func applying(_ envelopes: [AgentEventEnvelope]) throws -> Self {
        var projection = self
        for envelope in envelopes {
            projection = try projection.applying(envelope)
        }
        return projection
    }

    /// Applies exactly one next event, rejecting duplicates, gaps, illegal edges, and regressions.
    public func applying(_ envelope: AgentEventEnvelope) throws -> Self {
        let record = envelope.payload
        guard !observedEventIDs.contains(record.eventID) else {
            throw AgentRunProjectionReplayError.duplicateEventIdentity(record.eventID)
        }
        guard !isTerminal else { throw AgentRunProjectionReplayError.eventAfterTerminal }
        guard record.requestID == requestID,
              record.executionHandleID == executionHandleID,
              record.runID == runID
        else { throw AgentRunProjectionReplayError.streamIdentityMismatch }

        let (expectedSequence, sequenceOverflow) = cursor.sequence.addingReportingOverflow(1)
        guard !sequenceOverflow else { throw AgentRunProjectionReplayError.sequenceOverflow }
        guard record.sequence == expectedSequence else {
            throw AgentRunProjectionReplayError.noncontiguousSequence(
                expected: expectedSequence,
                actual: record.sequence
            )
        }
        guard record.previousRecordDigest == cursor.recordDigest else {
            throw AgentRunProjectionReplayError.hashChainMismatch
        }
        guard record.timestamp >= cursor.timestamp else {
            throw AgentRunProjectionReplayError.timestampRegression
        }
        guard cursor.cumulativeUsage.quantities.isComponentwiseAtMost(
            record.cumulativeUsage.quantities
        ) else { throw AgentRunProjectionReplayError.usageRegression }
        guard record.runStateVersion >= cursor.runStateVersion else {
            throw AgentRunProjectionReplayError.stateVersionRegression
        }
        try validateStateVersionAndEdge(record)
        guard record.event.isRunTerminal == record.runState.isTerminal else {
            throw AgentRunProjectionReplayError.terminalEventMismatch
        }

        var eventIDs = observedEventIDs
        eventIDs.insert(record.eventID)
        return Self(
            requestID: requestID,
            executionHandleID: executionHandleID,
            runID: runID,
            cursor: record.cursor,
            observedEventIDs: eventIDs
        )
    }

    private static func initial(_ envelope: AgentEventEnvelope) throws -> Self {
        let record = envelope.payload
        guard record.sequence == 1 else {
            throw AgentRunProjectionReplayError.initialSequenceMustBeOne
        }
        guard record.event.isRunTerminal == record.runState.isTerminal else {
            throw AgentRunProjectionReplayError.terminalEventMismatch
        }
        return Self(
            requestID: record.requestID,
            executionHandleID: record.executionHandleID,
            runID: record.runID,
            cursor: record.cursor,
            observedEventIDs: [record.eventID]
        )
    }

    private func validateStateVersionAndEdge(_ record: AgentEventRecord) throws {
        if record.runState == state {
            if record.runStateVersion == stateVersion { return }
            let (nextVersion, overflow) = stateVersion.addingReportingOverflow(1)
            guard !overflow, record.runStateVersion == nextVersion else {
                throw AgentRunProjectionReplayError.stateVersionGap
            }
            guard state == .waitingForApproval || state == .pausing else {
                throw AgentRunProjectionReplayError.illegalSelfTransition(state: state)
            }
            return
        }

        let (nextVersion, overflow) = stateVersion.addingReportingOverflow(1)
        guard !overflow, record.runStateVersion == nextVersion else {
            throw AgentRunProjectionReplayError.stateVersionGap
        }
        guard AgentRunTransitionMatrix.allows(from: state, to: record.runState) else {
            throw AgentRunProjectionReplayError.illegalStateTransition(
                from: state,
                to: record.runState
            )
        }
    }
}
