// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Parent execution context a workflow may attenuate from when spawning children.
public struct WorkflowParentContext: Sendable {
    public let runID: AgentRunID
    public let requestID: AgentRequestID
    public let requestingStepID: AgentStepID
    public let capabilityCeiling: RunCapabilityCeiling
    public let budget: AgentBudget
    public let modelPolicy: AgentModelPolicy
    public let approvalMode: AgentApprovalMode

    public init(
        runID: AgentRunID,
        requestID: AgentRequestID,
        requestingStepID: AgentStepID,
        capabilityCeiling: RunCapabilityCeiling,
        budget: AgentBudget,
        modelPolicy: AgentModelPolicy,
        approvalMode: AgentApprovalMode
    ) {
        self.runID = runID
        self.requestID = requestID
        self.requestingStepID = requestingStepID
        self.capabilityCeiling = capabilityCeiling
        self.budget = budget
        self.modelPolicy = modelPolicy
        self.approvalMode = approvalMode
    }
}

/// Produces the strictly attenuated child ceiling for one fan-out child.
public typealias WorkflowCeilingAttenuator = @Sendable (
    RunCapabilityCeiling,
    WorkflowPhasePlan,
    Int
) throws -> RunCapabilityCeiling

/// Produces the independent child budget for one fan-out child.
public typealias WorkflowBudgetAttenuator = @Sendable (
    AgentBudget,
    WorkflowPhasePlan,
    Int
) throws -> AgentBudget

/// Durable store for workflow summaries; production persists JSON beside conversation records,
/// tests use an in-memory fake.
public protocol WorkflowRecording: Sendable {
    func load(workflowID: UUID) async throws -> WorkflowSummary?
    func save(_ summary: WorkflowSummary) async throws
}

public enum WorkflowOrchestratorError: Error, Hashable, Sendable {
    case workflowAlreadyExists
    case workflowNotFound
    case workflowNotRunning
    case emptyPlan
    case childSpawnFailed(UUID, UInt64, Int)
    case childFailed(UUID, UInt64, Int)
    case recordingUnavailable
}

/// The separate orchestrator above `AgentExecutor` (spec §23): decomposes a goal into durable
/// phases, spawns children through `SubagentSpawning`, fans their results back in, and writes
/// `WorkflowPhaseRecord` / `WorkflowHandoff` records. It holds no direct filesystem, network, tool,
/// or sandbox authority.
public struct WorkflowOrchestrator: Sendable {
    public let spawner: any SubagentSpawning
    public let recording: any WorkflowRecording

    public init(
        spawner: any SubagentSpawning,
        recording: any WorkflowRecording
    ) {
        self.spawner = spawner
        self.recording = recording
    }

    /// Creates the durable summary from a plan and runs every phase to completion.
    public func start(
        workflowID: UUID,
        title: String,
        plan: WorkflowPlan,
        conversationID: UUID? = nil,
        parent: WorkflowParentContext,
        ceilingAttenuator: @escaping WorkflowCeilingAttenuator,
        budgetAttenuator: @escaping WorkflowBudgetAttenuator
    ) async throws -> WorkflowSummary {
        guard try await recording.load(workflowID: workflowID) == nil else {
            throw WorkflowOrchestratorError.workflowAlreadyExists
        }
        var summary = WorkflowSummary(
            id: workflowID,
            title: title,
            conversationID: conversationID,
            plan: plan,
            rootRunID: parent.runID,
            phases: plan.phases.map {
                WorkflowPhaseRecord(
                    sequence: $0.sequence,
                    title: $0.title,
                    inputArtifactReferences: $0.inputArtifactReferences,
                    acceptanceCriteria: $0.acceptanceCriteria,
                    handoff: $0.handoff
                )
            }
        )
        try await recording.save(summary)
        while summary.status == .running {
            summary = try await advance(
                workflowID: workflowID,
                plan: plan,
                parent: parent,
                ceilingAttenuator: ceilingAttenuator,
                budgetAttenuator: budgetAttenuator
            )
        }
        return summary
    }

    /// Processes the next pending phase (used for relaunch resume); returns the updated summary.
    public func advance(
        workflowID: UUID,
        plan: WorkflowPlan,
        parent: WorkflowParentContext,
        ceilingAttenuator: @escaping WorkflowCeilingAttenuator,
        budgetAttenuator: @escaping WorkflowBudgetAttenuator
    ) async throws -> WorkflowSummary {
        guard var summary = try await recording.load(workflowID: workflowID) else {
            throw WorkflowOrchestratorError.workflowNotFound
        }
        guard summary.status == .running else {
            throw WorkflowOrchestratorError.workflowNotRunning
        }
        guard let index = summary.phases.firstIndex(where: {
            $0.status == .pending || $0.status == .running
        }) else {
            summary.status = .completed
            summary.endTime = Date()
            summary.refreshAggregates()
            try await recording.save(summary)
            return summary
        }
        let phasePlan = plan.phases[index]
        var phase = summary.phases[index]
        phase.status = .running
        phase.startTime = phase.startTime ?? Date()
        summary.phases[index] = phase
        try await recording.save(summary)

        var outputArtifacts: [ArtifactReference] = []
        var results: [SubagentResult] = []
        var lastAnswer: String?
        // The previous phase's handoff carries audit findings / decisions the next phase must
        // consume (e.g. a Revise phase fixing what the Audit phase flagged).
        let upstreamHandoff = index > 0 ? summary.phases[index - 1].handoff : nil
        for (childIndex, childInstruction) in phasePlan.childInstructions.enumerated() {
            let childRunID = SubagentStableID.childRun(
                workflowID: workflowID,
                phase: phasePlan.sequence,
                child: childIndex
            )
            let childCeiling: RunCapabilityCeiling
            let childBudget: AgentBudget
            let spawnRequest: SubagentSpawnRequest
            do {
                childCeiling = try ceilingAttenuator(
                    parent.capabilityCeiling,
                    phasePlan,
                    childIndex
                )
                childBudget = try budgetAttenuator(
                    parent.budget,
                    phasePlan,
                    childIndex
                )
                spawnRequest = try SubagentSpawnRequest(
                    parentRunID: parent.runID,
                    parentRequestID: parent.requestID,
                    requestingStepID: parent.requestingStepID,
                    childRunID: childRunID,
                    role: "subagent",
                    instruction: Self.composedInstruction(
                        child: childInstruction,
                        phasePlan: phasePlan,
                        upstreamHandoff: upstreamHandoff
                    ),
                    outputRequirement: .textAndArtifacts,
                    modelPolicy: parent.modelPolicy,
                    capabilityCeiling: childCeiling,
                    budget: childBudget,
                    contextReferences: [],
                    artifactReferences: phasePlan.inputArtifactReferences,
                    sandboxRequirement: nil,
                    source: .workflow,
                    approvalMode: parent.approvalMode
                )
            } catch {
                phase.status = .failed
                phase.endTime = Date()
                summary.phases[index] = phase
                summary.status = .failed
                summary.endTime = Date()
                summary.refreshAggregates()
                try await recording.save(summary)
                throw WorkflowOrchestratorError.childSpawnFailed(
                    workflowID,
                    phasePlan.sequence,
                    childIndex
                )
            }
            let handleID: AgentExecutionHandleID
            do {
                handleID = try await spawner.spawn(spawnRequest)
            } catch {
                phase.status = .failed
                phase.endTime = Date()
                summary.phases[index] = phase
                summary.status = .failed
                summary.endTime = Date()
                try await recording.save(summary)
                throw WorkflowOrchestratorError.childSpawnFailed(
                    workflowID,
                    phasePlan.sequence,
                    childIndex
                )
            }
            phase.childRunIDs.append(childRunID)
            phase.stats.subagentCount += 1
            summary.phases[index] = phase
            try await recording.save(summary)

            let result: SubagentResult
            do {
                result = try await spawner.collect(handleID)
            } catch {
                phase.status = .failed
                phase.endTime = Date()
                summary.phases[index] = phase
                summary.status = .failed
                summary.endTime = Date()
                try await recording.save(summary)
                throw WorkflowOrchestratorError.childFailed(
                    workflowID,
                    phasePlan.sequence,
                    childIndex
                )
            }
            results.append(result)
            switch result.outcome {
            case .completed(let answer, let usage):
                outputArtifacts.append(contentsOf: answer.artifacts)
                phase.stats.merge(Self.stats(usage: usage))
                if let text = answer.text, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    lastAnswer = text
                }
            case .failed(_, let usage):
                phase.stats.merge(Self.stats(usage: usage))
                phase.completedChildCount += 1
                summary.phases[index] = phase
                summary.refreshAggregates()
                try await recording.save(summary)
                phase.status = .failed
                phase.endTime = Date()
                summary.phases[index] = phase
                summary.status = .failed
                summary.endTime = Date()
                summary.refreshAggregates()
                try await recording.save(summary)
                throw WorkflowOrchestratorError.childFailed(
                    workflowID,
                    phasePlan.sequence,
                    childIndex
                )
            case .cancelled:
                phase.completedChildCount += 1
                summary.phases[index] = phase
                summary.refreshAggregates()
                try await recording.save(summary)
                phase.status = .cancelled
                phase.endTime = Date()
                summary.phases[index] = phase
                summary.status = .cancelled
                summary.endTime = Date()
                summary.refreshAggregates()
                try await recording.save(summary)
                return summary
            }
            phase.completedChildCount += 1
            summary.phases[index] = phase
            summary.refreshAggregates()
            try await recording.save(summary)
        }

        phase.status = .completed
        phase.endTime = Date()
        phase.outputArtifactReferences = outputArtifacts
        summary.finalAnswer = lastAnswer ?? summary.finalAnswer
        if let nextPlan = plan.phases.dropFirst(Int(index) + 1).first {
            phase.handoff = Self.makeHandoff(
                phasePlan: phasePlan,
                nextPlan: nextPlan,
                artifacts: outputArtifacts,
                results: results
            )
        }
        summary.phases[index] = phase
        summary.refreshAggregates()
        try await recording.save(summary)
        return summary
    }

    private static func composedInstruction(
        child: String,
        phasePlan: WorkflowPhasePlan,
        upstreamHandoff: WorkflowHandoff?
    ) -> String {
        var parts: [String] = []
        if let brief = phasePlan.handoff?.taskBrief, !brief.isEmpty {
            parts.append(brief)
        }
        if let upstreamHandoff {
            if !upstreamHandoff.keyDecisions.isEmpty {
                parts.append(
                    "Previous phase findings:\n"
                        + upstreamHandoff.keyDecisions.map { "- \($0)" }.joined(separator: "\n")
                )
            }
            if !upstreamHandoff.knownRisks.isEmpty {
                parts.append(
                    "Known risks from the previous phase:\n"
                        + upstreamHandoff.knownRisks.map { "- \($0)" }.joined(separator: "\n")
                )
            }
            if !upstreamHandoff.verificationDuties.isEmpty {
                parts.append("Verify: " + upstreamHandoff.verificationDuties.joined(separator: " "))
            }
        }
        parts.append(child)
        parts.append("Acceptance criteria: \(phasePlan.acceptanceCriteria)")
        if let duties = phasePlan.handoff?.verificationDuties, !duties.isEmpty {
            parts.append("Verify: " + duties.joined(separator: " "))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func makeHandoff(
        phasePlan: WorkflowPhasePlan,
        nextPlan: WorkflowPhasePlan,
        artifacts: [ArtifactReference],
        results: [SubagentResult]
    ) -> WorkflowHandoff {
        var decisions = phasePlan.handoff?.keyDecisions ?? []
        for result in results {
            if case .completed(let answer, _) = result.outcome, let text = answer.text {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    decisions.append(String(trimmed.prefix(800)))
                }
            }
        }
        return WorkflowHandoff(
            taskBrief: nextPlan.handoff?.taskBrief ?? nextPlan.childInstructions.joined(separator: "\n"),
            acceptanceCriteria: nextPlan.acceptanceCriteria,
            upstreamArtifactReferences: artifacts,
            keyDecisions: decisions,
            knownRisks: phasePlan.handoff?.knownRisks ?? [],
            verificationDuties: nextPlan.handoff?.verificationDuties ?? []
        )
    }

    private static func stats(usage: AgentUsage) -> WorkflowAggregatedStats {
        WorkflowAggregatedStats(
            subagentCount: 0,
            elapsedMilliseconds: Int64(clamping: usage.quantities[.activeMilliseconds]),
            inputTokens: Int64(clamping: usage.quantities[.inputTokens]),
            outputTokens: Int64(clamping: usage.quantities[.outputTokens]),
            toolInvocationCount: Int64(clamping: usage.quantities[.toolInvocations])
        )
    }
}
