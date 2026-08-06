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
        finalAnswer: String? = nil
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
        finalAnswer: String? = nil
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
                        "Before answering, call the web_search tool to gather the latest facts, "
                            + "specifications, and constraints about: \(goal). Keep your answer "
                            + "concise (under 200 words).",
                    ]
                ),
                WorkflowPhasePlan(
                    sequence: 2,
                    title: "Plan",
                    acceptanceCriteria: "A concrete step-by-step plan is written from the findings",
                    childInstructions: [
                        "Write a concrete, step-by-step plan for: \(goal). Keep it under 300 words.",
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
                            + "user receives. Keep it concise (under 400 words).",
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
