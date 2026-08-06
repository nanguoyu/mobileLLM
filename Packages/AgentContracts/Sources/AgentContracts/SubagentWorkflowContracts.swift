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

    public init(
        runID: AgentRunID,
        handleID: AgentExecutionHandleID,
        outcome: SubagentOutcome
    ) {
        self.runID = runID
        self.handleID = handleID
        self.outcome = outcome
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
        aggregated: WorkflowAggregatedStats = WorkflowAggregatedStats()
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
    }

    public var isRunning: Bool { status == .running }

    /// Recomputes workflow-level aggregates from phase records (caller persists after mutation).
    public mutating func refreshAggregates() {
        var total = WorkflowAggregatedStats()
        for phase in phases {
            total.merge(phase.stats)
        }
        aggregated = total
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

    public init(
        workflowID: UUID,
        title: String,
        conversationID: UUID? = nil,
        status: WorkflowStatus = .running,
        startTime: Date = Date(),
        endTime: Date? = nil,
        rootRunID: AgentRunID? = nil,
        aggregated: WorkflowAggregatedStats = WorkflowAggregatedStats()
    ) {
        self.workflowID = workflowID
        self.title = title
        self.conversationID = conversationID
        self.status = status
        self.startTime = startTime
        self.endTime = endTime
        self.rootRunID = rootRunID
        self.aggregated = aggregated
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
}
