// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Subagent spawn contract (spec §22)

/// A validated request to spawn one durable child run under a reserved parent identity.
public struct SubagentSpawnRequest: Hashable, Codable, Sendable {
    /// Parent run identity.
    public let parentRunID: AgentRunID
    /// Parent request identity, recorded as child provenance.
    public let parentRequestID: AgentRequestID
    /// Parent step requesting the child.
    public let requestingStepID: AgentStepID
    /// Stable child run identity selected before submission.
    public let childRunID: AgentRunID
    /// Bounded role label.
    public let role: String
    /// Trusted instruction for this child.
    public let instruction: String
    /// Required structured output form.
    public let outputRequirement: AgentOutputRequirement
    /// Provider-neutral model policy.
    public let modelPolicy: AgentModelPolicy
    /// Strictly attenuated child ceiling.
    public let capabilityCeiling: RunCapabilityCeiling
    /// Independent immutable child budget.
    public let budget: AgentBudget
    /// Frozen context references.
    public let contextReferences: [AgentContextReference]
    /// Durable artifact inputs.
    public let artifactReferences: [ArtifactReference]
    /// Optional sandbox requirement (authority/budget must be subsets).
    public let sandboxRequirement: SandboxRequirement?
    /// Deterministically ordered metadata labels.
    public let labels: [AgentRequestLabel]
    /// Submission source: `.parentAgent` or `.workflow`.
    public let source: AgentRequestProvenance.Source
    /// Approval mode frozen with the child run.
    public let approvalMode: AgentApprovalMode
    /// Stable evidence references for future verification.
    public let evidenceDigests: [StableDigest]

    /// Creates a normalized, validated spawn request. Deep ceiling/budget attenuation is enforced
    /// by `SubagentSpawning` against the live parent run facts.
    public init(
        parentRunID: AgentRunID,
        parentRequestID: AgentRequestID,
        requestingStepID: AgentStepID,
        childRunID: AgentRunID,
        role: String,
        instruction: String,
        outputRequirement: AgentOutputRequirement,
        modelPolicy: AgentModelPolicy,
        capabilityCeiling: RunCapabilityCeiling,
        budget: AgentBudget,
        contextReferences: [AgentContextReference] = [],
        artifactReferences: [ArtifactReference] = [],
        sandboxRequirement: SandboxRequirement? = nil,
        labels: some Sequence<AgentRequestLabel> = [],
        source: AgentRequestProvenance.Source,
        approvalMode: AgentApprovalMode = .ask,
        evidenceDigests: some Sequence<StableDigest> = []
    ) throws {
        guard source == .parentAgent || source == .workflow else {
            throw AgentContractError.invalidName("subagent spawn source")
        }
        let normalizedLabels = Array(Set(labels)).sorted()
        try outputRequirement.validate()
        guard AgentWireValidation.isNonblankControlFree(role, maximumLength: 128),
              !instruction.isEmpty,
              instruction.utf8.count <= 256 * 1_024,
              instruction == instruction.trimmingCharacters(in: .whitespacesAndNewlines),
              Set(normalizedLabels.map(\.key)).count == normalizedLabels.count,
              Set(contextReferences).count == contextReferences.count,
              Set(artifactReferences.map(\.id)).count == artifactReferences.count
        else { throw AgentContractError.invalidName("subagent spawn request") }
        if let sandboxRequirement,
           !sandboxRequirement.authority.isSubset(of: capabilityCeiling.authority)
        {
            throw AgentContractError.capabilityEscalation(
                sandboxRequirement.authority.capabilities.values.filter {
                    !capabilityCeiling.capabilities.contains($0)
                }
            )
        }
        if let sandboxRequirement {
            _ = try budget.attenuating(to: sandboxRequirement.budget)
        }
        self.parentRunID = parentRunID
        self.parentRequestID = parentRequestID
        self.requestingStepID = requestingStepID
        self.childRunID = childRunID
        self.role = role
        self.instruction = instruction
        self.outputRequirement = outputRequirement
        self.modelPolicy = modelPolicy
        self.capabilityCeiling = capabilityCeiling
        self.budget = budget
        self.contextReferences = contextReferences
        self.artifactReferences = artifactReferences
        self.sandboxRequirement = sandboxRequirement
        self.labels = normalizedLabels
        self.source = source
        self.approvalMode = approvalMode
        self.evidenceDigests = Array(Set(evidenceDigests)).sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

/// Terminal outcome of one child run, normalized for workflow fan-in.
public enum SubagentOutcome: Hashable, Codable, Sendable {
    case completed(answer: AgentAnswer, usage: AgentUsage)
    case failed(failure: AgentFailure, usage: AgentUsage)
    case cancelled
}

/// Durable, normalized child result consumed by the workflow orchestrator.
public struct SubagentResult: Hashable, Codable, Sendable {
    public let runID: AgentRunID
    public let handleID: AgentExecutionHandleID
    public let outcome: SubagentOutcome
    /// Cancelled outcomes historically had no usage field. Preserve metered work without changing
    /// that enum's wire shape; old records omit this field and continue to decode.
    public let terminalUsage: AgentUsage?

    public var usage: AgentUsage {
        switch outcome {
        case .completed(_, let usage), .failed(_, let usage): usage
        case .cancelled: terminalUsage ?? .zero
        }
    }

    public init(
        runID: AgentRunID,
        handleID: AgentExecutionHandleID,
        outcome: SubagentOutcome,
        terminalUsage: AgentUsage? = nil
    ) {
        self.runID = runID
        self.handleID = handleID
        self.outcome = outcome
        self.terminalUsage = terminalUsage
    }
}

// MARK: - Workflow contracts (spec §23/§23.1)

/// Workflow-level status shown by the message-anchored record and summary page.
public enum WorkflowStatus: String, CaseIterable, Hashable, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

/// UI-facing lifecycle for a Claude-style JavaScript workflow. Candidate generation is an app
/// concern that intentionally precedes the durable runtime state machine; every other case is a
/// lossless presentation of `WorkflowRunStateV1`.
public enum DynamicWorkflowPresentationState: String, CaseIterable, Hashable, Codable, Sendable {
    case generatingCandidate
    case waitingForLaunchApproval
    case queued
    case running
    case pausing
    case paused
    case waitingForForeground
    case waitingForReconciliation
    case completed
    case failed
    case cancelled

    public init(_ runtimeState: WorkflowRunStateV1) {
        self = switch runtimeState {
        case .waitingForLaunchApproval: .waitingForLaunchApproval
        case .queued: .queued
        case .running: .running
        case .pausing: .pausing
        case .paused: .paused
        case .waitingForForeground: .waitingForForeground
        case .waitingForReconciliation: .waitingForReconciliation
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    public var workflowStatus: WorkflowStatus {
        switch self {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        default: .running
        }
    }
}

public enum DynamicWorkflowChildStatus: String, Hashable, Codable, Sendable {
    case prepared
    case submitted
    case completed
    case failed
    case unavailable
    case stopped
    case uncertain
}

/// Public task assignment and durable execution facts. Provider prompts and private reasoning
/// are never copied into this display snapshot; recorded result bodies are loaded separately.
public struct DynamicWorkflowChildPresentation: Hashable, Codable, Sendable, Identifiable {
    public var id: WorkflowAgentCallID { callID }
    public let callID: WorkflowAgentCallID
    public let ordinal: UInt32
    public let attempt: UInt16
    public let label: String?
    public let phase: String?
    public let childRunID: AgentRunID
    public let handleID: AgentExecutionHandleID?
    public let status: DynamicWorkflowChildStatus
    public let detail: String?
    public var task: WorkflowTaskDescriptorV1?
    public var agentType: String?
    public var executionState: AgentRunState?
    public var preparedAt: AgentTimestamp?
    public var submittedAt: AgentTimestamp?
    public var settledAt: AgentTimestamp?
    public var usage: AgentUsage?
    public var hasResult: Bool?
    public var preparedSequence: UInt64?
    public var settledSequence: UInt64?
    public var sessionKey: String?
    public var profile: WorkflowAgentProfileV1?
    public var modelName: String?
    public var toolCallLimit: UInt64?

    public init(
        callID: WorkflowAgentCallID,
        ordinal: UInt32,
        attempt: UInt16,
        label: String? = nil,
        phase: String? = nil,
        childRunID: AgentRunID,
        handleID: AgentExecutionHandleID? = nil,
        status: DynamicWorkflowChildStatus,
        detail: String? = nil,
        task: WorkflowTaskDescriptorV1? = nil,
        agentType: String? = nil,
        executionState: AgentRunState? = nil,
        preparedAt: AgentTimestamp? = nil,
        submittedAt: AgentTimestamp? = nil,
        settledAt: AgentTimestamp? = nil,
        usage: AgentUsage? = nil,
        hasResult: Bool? = nil,
        preparedSequence: UInt64? = nil,
        settledSequence: UInt64? = nil,
        sessionKey: String? = nil, profile: WorkflowAgentProfileV1? = nil,
        modelName: String? = nil, toolCallLimit: UInt64? = nil
    ) {
        self.callID = callID
        self.ordinal = ordinal
        self.attempt = attempt
        self.label = label
        self.phase = phase
        self.childRunID = childRunID
        self.handleID = handleID
        self.status = status
        self.detail = detail
        self.task = task
        self.agentType = agentType
        self.executionState = executionState
        self.preparedAt = preparedAt
        self.submittedAt = submittedAt
        self.settledAt = settledAt
        self.usage = usage
        self.hasResult = hasResult
        self.preparedSequence = preparedSequence
        self.settledSequence = settledSequence
        self.sessionKey = sessionKey; self.profile = profile
        self.modelName = modelName; self.toolCallLimit = toolCallLimit
    }
}

/// The initial coordinator is a real run before a workflow script has been prepared.
public struct WorkflowPlanningPresentation: Hashable, Codable, Sendable {
    public let runID: AgentRunID
    public let handleID: AgentExecutionHandleID
    public let state: AgentRunState
    public let updatedAt: AgentTimestamp

    public init(runID: AgentRunID, handleID: AgentExecutionHandleID, state: AgentRunState, updatedAt: AgentTimestamp) {
        self.runID = runID
        self.handleID = handleID
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// Presentation contains result identities, never another copy of protected result bodies.
public struct WorkflowGoalResultLink: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let callID: WorkflowAgentCallID
    public let inputArtifactIDs: [String]
    public init(_ artifact: WorkflowTaskArtifact) {
        id = artifact.id; taskID = artifact.taskID; callID = artifact.callID; inputArtifactIDs = artifact.inputArtifactIDs
    }
}

public struct WorkflowGoalPresentation: Hashable, Codable, Sendable {
    public let objective: String
    public let revision: UInt64
    public let state: WorkflowGoalState
    public let reason: String?
    public let amendments: [WorkflowGoalAmendment]
    public let tasks: [WorkflowTaskNode]
    public let results: [WorkflowGoalResultLink]
    public let budget: AgentBudget
    public let usage: AgentUsage
    public let pendingInputs: AgentSessionPendingInputs
    public let skillNames: [String: String]

    public init(graph: WorkflowTaskGraph, budget: AgentBudget, usage: AgentUsage,
                pendingInputs: AgentSessionPendingInputs = .init(), skillNames: [String: String] = [:]) {
        objective = graph.objective; revision = graph.revision; state = graph.state; reason = graph.reason
        amendments = graph.amendments; tasks = graph.tasks; results = graph.artifacts.map(WorkflowGoalResultLink.init)
        self.budget = budget; self.usage = usage; self.pendingInputs = pendingInputs; self.skillNames = skillNames
    }
}

/// Persisted presentation snapshot for a Dynamic Workflow. Keeping the exact analyzed source and
/// phase metadata beside the initiating message makes approval review available after relaunch;
/// the runtime journal remains authoritative for execution state.
public struct DynamicWorkflowPresentation: Hashable, Codable, Sendable {
    public let runID: WorkflowRunID
    public var scriptReference: WorkflowScriptReferenceV1?
    public var metadata: WorkflowScriptMetadataV1?
    public var source: String?
    public var state: DynamicWorkflowPresentationState
    public var currentPhase: String?
    public var logs: [String]
    public var completedCallCount: Int
    public var totalCallCount: Int
    /// Optional for backward decoding of dynamic summaries written before child inspection landed.
    public var childCalls: [DynamicWorkflowChildPresentation]?
    public var reconciliationCallID: WorkflowAgentCallID?
    public var failure: String?
    public var planning: WorkflowPlanningPresentation?
    public var goal: WorkflowGoalPresentation?

    public init(
        runID: WorkflowRunID,
        scriptReference: WorkflowScriptReferenceV1? = nil,
        metadata: WorkflowScriptMetadataV1? = nil,
        source: String? = nil,
        state: DynamicWorkflowPresentationState,
        currentPhase: String? = nil,
        logs: [String] = [],
        completedCallCount: Int = 0,
        totalCallCount: Int = 0,
        childCalls: [DynamicWorkflowChildPresentation] = [],
        reconciliationCallID: WorkflowAgentCallID? = nil,
        failure: String? = nil,
        planning: WorkflowPlanningPresentation? = nil,
        goal: WorkflowGoalPresentation? = nil
    ) {
        self.runID = runID
        self.scriptReference = scriptReference
        self.metadata = metadata
        self.source = source
        self.state = state
        self.currentPhase = currentPhase
        self.logs = logs
        self.completedCallCount = completedCallCount
        self.totalCallCount = totalCallCount
        self.childCalls = childCalls
        self.reconciliationCallID = reconciliationCallID
        self.failure = failure
        self.planning = planning
        self.goal = goal
    }
}

/// Aggregated workflow/phase statistics (spec §20/§23).
public struct WorkflowAggregatedStats: Hashable, Codable, Sendable {
    public var subagentCount: Int
    public var elapsedMilliseconds: Int64
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var toolInvocationCount: Int64

    public init(
        subagentCount: Int = 0,
        elapsedMilliseconds: Int64 = 0,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        toolInvocationCount: Int64 = 0
    ) {
        self.subagentCount = subagentCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.toolInvocationCount = toolInvocationCount
    }

    public mutating func merge(_ other: WorkflowAggregatedStats) {
        subagentCount += other.subagentCount
        elapsedMilliseconds += other.elapsedMilliseconds
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        toolInvocationCount += other.toolInvocationCount
    }
}

/// Status of one phase inside a workflow.
public enum WorkflowPhaseStatus: String, CaseIterable, Hashable, Codable, Sendable {
    case pending
    case running
    case waiting
    case completed
    case failed
    case cancelled
}

/// One durable phase record (spec §23.1).
public struct WorkflowPhaseRecord: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let sequence: UInt64
    public let title: String
    public var status: WorkflowPhaseStatus
    public var inputArtifactReferences: [ArtifactReference]
    public var outputArtifactReferences: [ArtifactReference]
    public let acceptanceCriteria: String
    public var startTime: Date?
    public var endTime: Date?
    public var childRunIDs: [AgentRunID]
    /// How many children in this phase reached a durable terminal state (live progress).
    public var completedChildCount: Int
    public var stats: WorkflowAggregatedStats
    public var handoff: WorkflowHandoff?

    public init(
        id: UUID = UUID(),
        sequence: UInt64,
        title: String,
        status: WorkflowPhaseStatus = .pending,
        inputArtifactReferences: [ArtifactReference] = [],
        outputArtifactReferences: [ArtifactReference] = [],
        acceptanceCriteria: String,
        startTime: Date? = nil,
        endTime: Date? = nil,
        childRunIDs: [AgentRunID] = [],
        completedChildCount: Int = 0,
        stats: WorkflowAggregatedStats = WorkflowAggregatedStats(),
        handoff: WorkflowHandoff? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.title = title
        self.status = status
        self.inputArtifactReferences = inputArtifactReferences
        self.outputArtifactReferences = outputArtifactReferences
        self.acceptanceCriteria = acceptanceCriteria
        self.startTime = startTime
        self.endTime = endTime
        self.childRunIDs = childRunIDs
        self.completedChildCount = completedChildCount
        self.stats = stats
        self.handoff = handoff
    }
}

/// Structured handoff passed from one phase to the next child run (spec §23.1). References are
/// artifact references, never content copies; the child may read only what it is handed.
public struct WorkflowHandoff: Hashable, Codable, Sendable {
    public let taskBrief: String
    public let acceptanceCriteria: String
    public let upstreamArtifactReferences: [ArtifactReference]
    public let keyDecisions: [String]
    public let knownRisks: [String]
    public let verificationDuties: [String]

    public init(
        taskBrief: String,
        acceptanceCriteria: String,
        upstreamArtifactReferences: [ArtifactReference] = [],
        keyDecisions: [String] = [],
        knownRisks: [String] = [],
        verificationDuties: [String] = []
    ) {
        self.taskBrief = taskBrief
        self.acceptanceCriteria = acceptanceCriteria
        self.upstreamArtifactReferences = upstreamArtifactReferences
        self.keyDecisions = keyDecisions
        self.knownRisks = knownRisks
        self.verificationDuties = verificationDuties
    }
}

/// The complete durable workflow record used by the UI and the orchestrator.
public struct WorkflowSummary: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    /// Owning conversation (nil for app-global or legacy records).
    public let conversationID: UUID?
    /// The durable decomposition plan; persisted so relaunch can resume the orchestrator.
    public var plan: WorkflowPlan?
    public var status: WorkflowStatus
    public let startTime: Date
    public var endTime: Date?
    /// Reserved parent-run identity under which child runs are journaled.
    public let rootRunID: AgentRunID?
    public var phases: [WorkflowPhaseRecord]
    public var aggregated: WorkflowAggregatedStats
    /// Live phase progress shown by the message-anchored row.
    public var completedPhaseCount: Int
    public var totalPhaseCount: Int
    /// The workflow's final result text, projected into the chat on completion.
    public var finalAnswer: String?
    /// Present only for the Dynamic Workflows path. `nil` preserves all legacy staged-plan records.
    public var dynamic: DynamicWorkflowPresentation?

    public init(
        id: UUID = UUID(),
        title: String,
        conversationID: UUID? = nil,
        plan: WorkflowPlan? = nil,
        status: WorkflowStatus = .running,
        startTime: Date = Date(),
        endTime: Date? = nil,
        rootRunID: AgentRunID? = nil,
        phases: [WorkflowPhaseRecord] = [],
        aggregated: WorkflowAggregatedStats = WorkflowAggregatedStats(),
        completedPhaseCount: Int = 0,
        totalPhaseCount: Int = 0,
        finalAnswer: String? = nil,
        dynamic: DynamicWorkflowPresentation? = nil
    ) {
        self.id = id
        self.title = title
        self.conversationID = conversationID
        self.plan = plan
        self.status = status
        self.startTime = startTime
        self.endTime = endTime
        self.rootRunID = rootRunID
        self.phases = phases
        self.aggregated = aggregated
        self.completedPhaseCount = completedPhaseCount
        self.totalPhaseCount = totalPhaseCount
        self.finalAnswer = finalAnswer
        self.dynamic = dynamic
    }

    public var isRunning: Bool { status == .running }

    /// Recomputes workflow-level aggregates from phase records (caller persists after mutation).
    public mutating func refreshAggregates() {
        var total = WorkflowAggregatedStats()
        completedPhaseCount = 0
        totalPhaseCount = phases.count
        for phase in phases {
            total.merge(phase.stats)
            if phase.status == .completed {
                completedPhaseCount += 1
            }
        }
        aggregated = total
    }

    /// True when every phase has completed (the workflow may still be marked running while the
    /// orchestrator performs its final bookkeeping).
    public var allPhasesCompleted: Bool {
        !phases.isEmpty && phases.allSatisfy { $0.status == .completed }
    }

    /// Completed subagents across all phases (live x/y numerator).
    public var completedSubagentCount: Int {
        phases.reduce(0) { $0 + $1.completedChildCount }
    }

    /// Planned subagents across all phases (live x/y denominator); falls back to spawned runs for
    /// legacy records without a persisted plan.
    public var totalSubagentCount: Int {
        if let plan {
            return plan.phases.reduce(0) { $0 + $1.childInstructions.count }
        }
        return phases.reduce(0) { $0 + $1.childRunIDs.count }
    }
}

/// The message-anchored workflow record rendered below its initiating message (spec §20/§23).
public struct WorkflowMessageRecord: Hashable, Codable, Sendable {
    public let workflowID: UUID
    public let title: String
    public let conversationID: UUID?
    public var status: WorkflowStatus
    public let startTime: Date
    public var endTime: Date?
    public let rootRunID: AgentRunID?
    public var aggregated: WorkflowAggregatedStats
    public var completedPhaseCount: Int
    public var totalPhaseCount: Int
    public var completedSubagentCount: Int
    public var totalSubagentCount: Int
    public var finalAnswer: String?
    public var dynamic: DynamicWorkflowPresentation?
    /// Process-local attachment projected by `WorkflowStore`; false after neutral relaunch.
    public var isAttachedInCurrentProcess: Bool?

    public init(
        workflowID: UUID,
        title: String,
        conversationID: UUID? = nil,
        status: WorkflowStatus = .running,
        startTime: Date = Date(),
        endTime: Date? = nil,
        rootRunID: AgentRunID? = nil,
        aggregated: WorkflowAggregatedStats = WorkflowAggregatedStats(),
        completedPhaseCount: Int = 0,
        totalPhaseCount: Int = 0,
        completedSubagentCount: Int = 0,
        totalSubagentCount: Int = 0,
        finalAnswer: String? = nil,
        dynamic: DynamicWorkflowPresentation? = nil,
        isAttachedInCurrentProcess: Bool? = nil
    ) {
        self.workflowID = workflowID
        self.title = title
        self.conversationID = conversationID
        self.status = status
        self.startTime = startTime
        self.endTime = endTime
        self.rootRunID = rootRunID
        self.aggregated = aggregated
        self.completedPhaseCount = completedPhaseCount
        self.totalPhaseCount = totalPhaseCount
        self.completedSubagentCount = completedSubagentCount
        self.totalSubagentCount = totalSubagentCount
        self.finalAnswer = finalAnswer
        self.dynamic = dynamic
        self.isAttachedInCurrentProcess = isAttachedInCurrentProcess
    }

    public init(summary: WorkflowSummary) {
        workflowID = summary.id
        title = summary.title
        conversationID = summary.conversationID
        status = summary.status
        startTime = summary.startTime
        endTime = summary.endTime
        rootRunID = summary.rootRunID
        aggregated = summary.aggregated
        completedPhaseCount = summary.completedPhaseCount
        totalPhaseCount = summary.totalPhaseCount
        completedSubagentCount = summary.completedSubagentCount
        totalSubagentCount = summary.totalSubagentCount
        finalAnswer = summary.finalAnswer
        dynamic = summary.dynamic
        isAttachedInCurrentProcess = nil
    }
}

/// One planned phase handed to the orchestrator (the durable decomposition plan).
public struct WorkflowPhasePlan: Hashable, Codable, Sendable {
    public let sequence: UInt64
    public let title: String
    public let acceptanceCriteria: String
    /// One child instruction per fan-out child in this phase (empty = no children; the phase still
    /// records a gate/merge decision).
    public let childInstructions: [String]
    public let inputArtifactReferences: [ArtifactReference]
    public let handoff: WorkflowHandoff?

    public init(
        sequence: UInt64,
        title: String,
        acceptanceCriteria: String,
        childInstructions: [String],
        inputArtifactReferences: [ArtifactReference] = [],
        handoff: WorkflowHandoff? = nil
    ) {
        self.sequence = sequence
        self.title = title
        self.acceptanceCriteria = acceptanceCriteria
        self.childInstructions = childInstructions
        self.inputArtifactReferences = inputArtifactReferences
        self.handoff = handoff
    }

    /// Decodes model-produced plans where optional fields may be absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        title = try container.decode(String.self, forKey: .title)
        acceptanceCriteria = try container.decode(String.self, forKey: .acceptanceCriteria)
        childInstructions = try container.decode([String].self, forKey: .childInstructions)
        inputArtifactReferences = try container.decodeIfPresent(
            [ArtifactReference].self,
            forKey: .inputArtifactReferences
        ) ?? []
        handoff = try container.decodeIfPresent(WorkflowHandoff.self, forKey: .handoff)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(title, forKey: .title)
        try container.encode(acceptanceCriteria, forKey: .acceptanceCriteria)
        try container.encode(childInstructions, forKey: .childInstructions)
        try container.encode(inputArtifactReferences, forKey: .inputArtifactReferences)
        try container.encodeIfPresent(handoff, forKey: .handoff)
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, title, acceptanceCriteria, childInstructions
        case inputArtifactReferences, handoff
    }
}

/// The durable, reviewable decomposition produced before any child run starts (spec §23.1).
public struct WorkflowPlan: Hashable, Codable, Sendable {
    public let goal: String
    public let phases: [WorkflowPhasePlan]

    public init(goal: String, phases: [WorkflowPhasePlan]) throws {
        guard !goal.isEmpty,
              goal.utf8.count <= 8 * 1_024,
              !phases.isEmpty,
              phases.map(\.sequence) == Array(1 ... UInt64(phases.count))
        else { throw AgentContractError.invalidName("workflow plan") }
        self.goal = goal
        self.phases = phases
    }

    /// Decodes the model's structured plan output into the durable plan value.
    public static func decode(from value: JSONValue) throws -> WorkflowPlan {
        let data = try CanonicalJSON(value).data
        return try JSONDecoder().decode(WorkflowPlan.self, from: data)
    }

    /// Deterministic fallback used when the planner model cannot produce valid structured output
    /// (after the runtime's one bounded repair). Guarantees every goal still gets a reviewable
    /// multi-phase, multi-subagent plan with the full quality loop:
    /// explore → plan → audit → revise → verify → deliver.
    public static func fallback(goal: String) throws -> WorkflowPlan {
        try WorkflowPlan(
            goal: goal,
            phases: [
                WorkflowPhasePlan(
                    sequence: 1,
                    title: "Explore",
                    acceptanceCriteria: "The key facts and constraints are gathered",
                    childInstructions: [
                        "Before answering, run EXACTLY 3 different web_search queries with varied "
                            + "wording, then use fetch_webpage to READ at least 2 of the linked "
                            + "pages, so you gather the latest facts, specifications, and constraints "
                            + "about: \(goal). Summarize what you learned with source URLs "
                            + "(under 300 words).",
                    ]
                ),
                WorkflowPhasePlan(
                    sequence: 2,
                    title: "Plan",
                    acceptanceCriteria: "A concrete step-by-step plan is written from the findings",
                    childInstructions: [
                        "Write a concrete, step-by-step plan for: \(goal), citing the gathered facts "
                            + "and source URLs. Keep it under 300 words.",
                    ]
                ),
                WorkflowPhasePlan(
                    sequence: 3,
                    title: "Audit",
                    acceptanceCriteria: "The plan is audited from multiple angles and findings listed",
                    childInstructions: [
                        "Audit the plan for feasibility, cost, memory, and approval risks. List "
                            + "concrete findings (under 200 words).",
                        "Audit the plan for runtime, integration, and UX risks. List concrete "
                            + "findings (under 200 words).",
                    ]
                ),
                WorkflowPhasePlan(
                    sequence: 4,
                    title: "Revise",
                    acceptanceCriteria: "The plan is revised to address every audit finding",
                    childInstructions: [
                        "Revise the plan to address every finding from the previous audit phase. "
                            + "Output the revised plan (under 300 words).",
                    ]
                ),
                WorkflowPhasePlan(
                    sequence: 5,
                    title: "Verify",
                    acceptanceCriteria: "The revised plan is verified against every finding",
                    childInstructions: [
                        "Verify the revised plan resolves every audit finding and is complete and "
                            + "consistent. List any residual gaps or state that verification passed "
                            + "(under 150 words).",
                    ]
                ),
                WorkflowPhasePlan(
                    sequence: 6,
                    title: "Deliver",
                    acceptanceCriteria: "The final delivery-ready plan is written",
                    childInstructions: [
                        "Write the final delivery-ready plan for: \(goal). This is the answer the "
                            + "user receives. Include the key facts and source URLs gathered by the "
                            + "earlier phases. Keep it concise (under 400 words).",
                    ]
                ),
            ]
        )
    }
}

/// Draft 2020-12 JSON schema for the workflow-planning model output. Fully enforced by the runtime,
/// so a planner that emits extra keys or missing phases gets a bounded structured-output repair.
public enum WorkflowPlanSchema {
    public static var document: JSONSchemaDocument {
        try! JSONSchemaDocument(
            root: .object([
                "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                "type": .string("object"),
                "properties": .object([
                    "goal": .object([
                        "type": .string("string"),
                    ]),
                    "phases": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "sequence": .object(["type": .string("integer")]),
                                "title": .object(["type": .string("string")]),
                                "acceptanceCriteria": .object(["type": .string("string")]),
                                "childInstructions": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("string")]),
                                ]),
                            ]),
                            "required": .array([
                                .string("sequence"),
                                .string("title"),
                                .string("acceptanceCriteria"),
                                .string("childInstructions"),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                    ]),
                ]),
                "required": .array([.string("goal"), .string("phases")]),
            ])
        )
    }
}
