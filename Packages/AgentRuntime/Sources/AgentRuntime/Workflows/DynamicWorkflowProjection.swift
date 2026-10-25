// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public enum WorkflowProjectionError: Error, Hashable, Sendable {
    case missingCreatedEvent
    case duplicateCreatedEvent
    case streamIdentityMismatch
    case noncontiguousSequence
    case hashChainMismatch
    case timestampRegression
    case eventAfterTerminal
    case illegalStateTransition(WorkflowRunStateV1, WorkflowRunStateV1)
    case invalidEventForState
    case duplicateEventIdentity
    case duplicateAgentCall
    case noncontiguousAgentOrdinal
    case unknownAgentCall
    case duplicateAgentSettlement
    case usageRegression
}

/// Deterministic materialized view of one workflow journal. It is always rebuilt from the
/// hash-chained event stream; SQLite rows are an index, never a second source of truth.
public struct WorkflowRunProjectionV1: Hashable, Sendable {
    public let launch: WorkflowLaunchSnapshotV1
    public private(set) var state: WorkflowRunStateV1
    public private(set) var launchApprovalID: ApprovalID?
    public private(set) var currentPhase: String?
    public private(set) var logs: [String]
    public private(set) var savedWorkflowPins: [String: WorkflowScriptReferenceV1]
    public private(set) var calls: [WorkflowAgentCallV1]
    public private(set) var submittedHandles: [WorkflowAgentCallID: AgentExecutionHandleID]
    public private(set) var outcomes: [WorkflowAgentCallID: WorkflowAgentOutcomeV1]
    public private(set) var waits: [WorkflowWaitSelection]
    public private(set) var taskGraph: WorkflowTaskGraph?
    public private(set) var collaborationReceipts: [WorkflowCollaborationReceipt]
    public private(set) var goalResumptions: [UInt32: WorkflowTaskGraph]
    public private(set) var preparedAt: [WorkflowAgentCallID: AgentTimestamp]
    public private(set) var submittedAt: [WorkflowAgentCallID: AgentTimestamp]
    public private(set) var settledAt: [WorkflowAgentCallID: AgentTimestamp]
    public private(set) var preparedSequences: [WorkflowAgentCallID: UInt64]
    public private(set) var settledSequences: [WorkflowAgentCallID: UInt64]
    public private(set) var restartRequests: [WorkflowAgentCallID]
    public private(set) var reconciliationCallID: WorkflowAgentCallID?
    public private(set) var reconciliationDecision: AgentReconciliationDecision?
    public private(set) var reconciliationGeneration: UInt32
    public private(set) var usage: AgentUsage
    public private(set) var output: WorkflowValueReferenceV1?
    public private(set) var failure: String?
    public private(set) var lastSequence: UInt64
    public private(set) var lastDigest: StableDigest
    public private(set) var lastTimestamp: AgentTimestamp
    public private(set) var eventIDs: Set<WorkflowEventID>

    public var runID: WorkflowRunID { launch.runID }
    public var isTerminal: Bool { state.isTerminal }

    public static func replay(_ events: [WorkflowRunEventV1]) throws -> Self? {
        guard let first = events.first else { return nil }
        guard first.sequence == 1, first.previousDigest == nil,
              case .created(let launch) = first.kind,
              launch.runID == first.runID
        else { throw WorkflowProjectionError.missingCreatedEvent }
        var projection = Self(
            launch: launch,
            state: .waitingForLaunchApproval,
            launchApprovalID: nil,
            currentPhase: nil,
            logs: [],
            savedWorkflowPins: [:],
            calls: [],
            submittedHandles: [:],
            outcomes: [:],
            waits: [],
            taskGraph: nil,
            collaborationReceipts: [],
            goalResumptions: [:],
            preparedAt: [:],
            submittedAt: [:],
            settledAt: [:],
            preparedSequences: [:],
            settledSequences: [:],
            restartRequests: [],
            reconciliationCallID: nil,
            reconciliationDecision: nil,
            reconciliationGeneration: 0,
            usage: .zero,
            output: nil,
            failure: nil,
            lastSequence: first.sequence,
            lastDigest: first.recordDigest,
            lastTimestamp: first.timestamp,
            eventIDs: [first.eventID]
        )
        for event in events.dropFirst() { try projection.apply(event) }
        return projection
    }

    public mutating func apply(_ event: WorkflowRunEventV1) throws {
        guard event.runID == runID else { throw WorkflowProjectionError.streamIdentityMismatch }
        guard eventIDs.insert(event.eventID).inserted else {
            throw WorkflowProjectionError.duplicateEventIdentity
        }
        guard !isTerminal else { throw WorkflowProjectionError.eventAfterTerminal }
        let (next, overflow) = lastSequence.addingReportingOverflow(1)
        guard !overflow, event.sequence == next else {
            throw WorkflowProjectionError.noncontiguousSequence
        }
        guard event.previousDigest == lastDigest else { throw WorkflowProjectionError.hashChainMismatch }
        guard event.timestamp >= lastTimestamp else { throw WorkflowProjectionError.timestampRegression }

        switch event.kind {
        case .created:
            throw WorkflowProjectionError.duplicateCreatedEvent
        case .launchApproved(let approvalID):
            guard state == .waitingForLaunchApproval, launchApprovalID == nil else {
                throw WorkflowProjectionError.invalidEventForState
            }
            launchApprovalID = approvalID
        case .stateChanged(let from, let to, _):
            guard from == state, Self.allows(from: from, to: to) else {
                throw WorkflowProjectionError.illegalStateTransition(from, to)
            }
            guard !to.isTerminal || (
                Self.allSubmittedChildrenAreSettled(self) && reconciliationCallID == nil
            ) else {
                throw WorkflowProjectionError.invalidEventForState
            }
            if from == .waitingForLaunchApproval, to != .cancelled, to != .failed,
               launchApprovalID == nil
            {
                throw WorkflowProjectionError.invalidEventForState
            }
            state = to
        case .phaseStarted(let value):
            guard Self.acceptsRuntimeActivity(state),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowProjectionError.invalidEventForState
            }
            currentPhase = value
        case .logAppended(let value):
            guard Self.acceptsRuntimeActivity(state), !value.isEmpty else {
                throw WorkflowProjectionError.invalidEventForState
            }
            logs.append(value)
        case .savedWorkflowPinned(let name, let reference):
            guard (state == .waitingForLaunchApproval || Self.acceptsRuntimeActivity(state)),
                  !name.isEmpty,
                  launch.savedWorkflowPins[name] == reference,
                  savedWorkflowPins[name].map({ $0 == reference }) ?? true
            else { throw WorkflowProjectionError.invalidEventForState }
            savedWorkflowPins[name] = reference
        case .agentCallPrepared(let call):
            guard Self.acceptsRuntimeActivity(state) else {
                throw WorkflowProjectionError.invalidEventForState
            }
            guard !calls.contains(where: { $0.callID == call.callID }) else {
                throw WorkflowProjectionError.duplicateAgentCall
            }
            let maximumOrdinal = calls.map(\.ordinal).max() ?? 0
            let priorAttempts = calls.filter { $0.ordinal == call.ordinal }
            guard call.ordinal <= maximumOrdinal + 1,
                  call.ordinal > 0,
                  call.attempt == (priorAttempts.map(\.attempt).max() ?? 0) + 1,
                  call.ordinal <= maximumOrdinal || call.attempt == 1
            else { throw WorkflowProjectionError.noncontiguousAgentOrdinal }
            calls.append(call)
            if let descriptor = call.options.task, let revision = descriptor.expectedRevision {
                guard var graph = taskGraph else { throw WorkflowTaskGraphError.invalid }
                try graph.claim(taskID: descriptor.taskID, expectedRevision: revision, call: call)
                taskGraph = graph
            }
            preparedAt[call.callID] = event.timestamp
            preparedSequences[call.callID] = event.sequence
        case .agentChildSubmitted(let callID, let handleID):
            guard Self.acceptsRuntimeActivity(state), calls.contains(where: { $0.callID == callID }),
                  submittedHandles[callID] == nil, outcomes[callID] == nil
            else { throw WorkflowProjectionError.unknownAgentCall }
            submittedHandles[callID] = handleID
            submittedAt[callID] = event.timestamp
        case .agentCallSettled(let callID, let outcome):
            guard Self.acceptsRuntimeActivity(state), calls.contains(where: { $0.callID == callID }) else {
                throw WorkflowProjectionError.unknownAgentCall
            }
            guard outcomes[callID] == nil else { throw WorkflowProjectionError.duplicateAgentSettlement }
            outcomes[callID] = outcome
            settledAt[callID] = event.timestamp
            settledSequences[callID] = event.sequence
        case .agentRestartRequested(let callID):
            guard !state.isTerminal, calls.contains(where: { $0.callID == callID }) else {
                throw WorkflowProjectionError.unknownAgentCall
            }
            restartRequests.append(callID)
        case .waitSelected(let receipt):
            guard Self.acceptsRuntimeActivity(state), receipt.index == waits.count + 1,
                  !receipt.candidates.isEmpty, receipt.candidates.count <= 1_000,
                  Set(receipt.candidates).count == receipt.candidates.count,
                  receipt.candidates.contains(receipt.selected), outcomes[receipt.selected] != nil,
                  receipt.candidates.allSatisfy({ id in calls.contains { $0.callID == id } })
            else { throw WorkflowProjectionError.invalidEventForState }
            waits.append(receipt)
        case .collaborationRecorded(let receipt):
            guard Self.acceptsRuntimeActivity(state), receipt.index == collaborationReceipts.count + 1,
                  receipt.senderRunID == launch.initiatingRunID || calls.contains(where: { $0.childRunID == receipt.senderRunID })
            else { throw WorkflowProjectionError.invalidEventForState }
            try receipt.graph.validate()
            if let old = taskGraph {
                guard receipt.graph.objective == old.objective, receipt.graph.amendments == old.amendments,
                      receipt.graph.revision >= old.revision, receipt.graph.artifacts.starts(with: old.artifacts),
                      receipt.graph.revision != old.revision || receipt.graph == old
                else { throw WorkflowProjectionError.invalidEventForState }
            }
            taskGraph = receipt.graph
            collaborationReceipts.append(receipt)
        case .goalAmended(let amendment):
            guard var graph = taskGraph else { throw WorkflowProjectionError.invalidEventForState }
            try graph.amend(amendment)
            taskGraph = graph
        case .goalResumed(let index, let graph):
            guard let old = taskGraph, state == .paused, goalResumptions[index] == nil,
                  collaborationReceipts.last?.index == index,
                  graph.objective == old.objective, graph.amendments == old.amendments,
                  graph.tasks == old.tasks, graph.artifacts == old.artifacts,
                  graph.revision == old.revision + 1, graph.state == .active
            else { throw WorkflowProjectionError.invalidEventForState }
            taskGraph = graph
            goalResumptions[index] = graph
        case .usageCommitted(let nextUsage):
            guard usage.quantities.isComponentwiseAtMost(nextUsage.quantities) else {
                throw WorkflowProjectionError.usageRegression
            }
            usage = nextUsage
        case .reconciliationRequired(let callID, _):
            if let callID, !calls.contains(where: { $0.callID == callID }) {
                throw WorkflowProjectionError.unknownAgentCall
            }
            guard reconciliationCallID == nil else {
                throw WorkflowProjectionError.invalidEventForState
            }
            let (nextGeneration, overflow) = reconciliationGeneration.addingReportingOverflow(1)
            guard !overflow, nextGeneration > 0 else {
                throw WorkflowProjectionError.invalidEventForState
            }
            reconciliationGeneration = nextGeneration
            reconciliationCallID = callID
        case .reconciliationRequested(let callID, let decision):
            guard state == .waitingForReconciliation,
                  reconciliationCallID == callID,
                  reconciliationDecision == nil,
                  outcomes[callID] == nil
            else { throw WorkflowProjectionError.invalidEventForState }
            reconciliationDecision = decision
        case .reconciliationDecided(let callID, let decision):
            guard state == .waitingForReconciliation,
                  reconciliationCallID == callID,
                  reconciliationDecision == decision,
                  outcomes[callID] == nil
            else { throw WorkflowProjectionError.invalidEventForState }
            reconciliationCallID = nil
            reconciliationDecision = nil
        case .outputCommitted(let value):
            guard Self.acceptsRuntimeActivity(state), output == nil, failure == nil,
                  reconciliationCallID == nil,
                  Self.allSubmittedChildrenAreSettled(self),
                  taskGraph == nil || taskGraph?.state == .completed
            else {
                throw WorkflowProjectionError.invalidEventForState
            }
            output = value
        case .failureCommitted(let value):
            guard !state.isTerminal, failure == nil, !value.isEmpty else {
                throw WorkflowProjectionError.invalidEventForState
            }
            failure = value
        }
        lastSequence = event.sequence
        lastDigest = event.recordDigest
        lastTimestamp = event.timestamp
    }

    private static func allows(from: WorkflowRunStateV1, to: WorkflowRunStateV1) -> Bool {
        guard from != to, !from.isTerminal else { return false }
        switch from {
        case .waitingForLaunchApproval:
            return [.queued, .failed, .cancelled].contains(to)
        case .queued:
            return [.running, .paused, .waitingForForeground, .failed, .cancelled].contains(to)
        case .running:
            return [.pausing, .paused, .waitingForForeground, .waitingForReconciliation,
                    .completed, .failed, .cancelled].contains(to)
        case .pausing:
            return [.running, .paused, .completed, .failed, .cancelled].contains(to)
        case .paused:
            return [.queued, .running, .waitingForForeground, .failed, .cancelled].contains(to)
        case .waitingForForeground, .waitingForReconciliation:
            return [.queued, .running, .failed, .cancelled].contains(to)
        case .completed, .failed, .cancelled:
            return false
        }
    }

    private static func acceptsRuntimeActivity(_ state: WorkflowRunStateV1) -> Bool {
        state == .running || state == .pausing
    }

    private static func allSubmittedChildrenAreSettled(_ projection: Self) -> Bool {
        projection.submittedHandles.keys.allSatisfy { projection.outcomes[$0] != nil }
    }
}
