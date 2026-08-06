// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import MobileLLMUI

/// App-side workflow launcher (spec §22/§23): creates the reserved workflow-root run through the
/// normal frozen-input pipeline, then drives `WorkflowOrchestrator` so children attenuate from the
/// exact ceiling/budget/model policy the conversation would have used for a chat run.
@MainActor
final class WorkflowLauncher {
    private let container: AppContainer
    private let assembly: AgentRuntimeAssembly
    private let downloadBase: URL
    private let onlineConfigBox: OpenAIOnlineConfigurationBox
    private let orchestrator: WorkflowOrchestrator

    init(
        container: AppContainer,
        assembly: AgentRuntimeAssembly,
        downloadBase: URL,
        onlineConfigBox: OpenAIOnlineConfigurationBox
    ) {
        self.container = container
        self.assembly = assembly
        self.downloadBase = downloadBase
        self.onlineConfigBox = onlineConfigBox
        let spawner = DurableSubagentSpawner(
            executor: assembly.executor,
            repository: assembly.repository
        )
        orchestrator = WorkflowOrchestrator(
            spawner: spawner,
            recording: container.workflowStore
        )
    }

    func launch(
        goal: String,
        conversationID: UUID,
        userMessageID: UUID,
        workflowID: UUID
    ) async throws {
        guard let snapshot = makeAgentSnapshot(
            container: container,
            conversationID: conversationID,
            userTurnID: userMessageID,
            text: goal,
            imageRefs: [],
            downloadBase: downloadBase,
            onlineConfigBox: onlineConfigBox
        ) else {
            throw WorkflowLaunchError.snapshotUnavailable
        }
        let root = try assembly.makeWorkflowRoot(
            snapshot: snapshot,
            workflowID: workflowID
        )
        _ = try await assembly.executor.submit(
            root,
            commandID: WorkflowIdentity.rootCommand(workflowID: workflowID)
        )
        let parent = assembly.workflowParentContext(workflowID: workflowID, request: root)
        let plan = try WorkflowPlan(
            goal: goal,
            phases: [
                WorkflowPhasePlan(
                    sequence: 1,
                    title: "Goal",
                    acceptanceCriteria: "Complete the user's goal: \(goal)",
                    childInstructions: [goal],
                    handoff: WorkflowHandoff(
                        taskBrief: goal,
                        acceptanceCriteria: "Complete the user's goal: \(goal)"
                    )
                ),
            ]
        )
        let title = goal.count <= 48 ? goal : String(goal.prefix(48)) + "…"
        container.chat.attachWorkflowRecord(
            WorkflowMessageRecord(
                workflowID: workflowID,
                title: title,
                conversationID: conversationID,
                status: .running,
                rootRunID: root.runID
            ),
            to: userMessageID
        )
        _ = try await orchestrator.start(
            workflowID: workflowID,
            title: title,
            plan: plan,
            conversationID: conversationID,
            parent: parent,
            ceilingAttenuator: { ceiling, _, _ in
                let capabilities = AgentCapabilitySet(
                    ceiling.capabilities.values.filter { $0 != .unknownExternal }
                )
                return try ceiling.attenuating(
                    to: AgentAuthorityScope(
                        capabilities: capabilities,
                        destinations: ceiling.authority.destinations,
                        dataCategories: ceiling.authority.dataCategories
                    ),
                    requireStrict: true
                )
            },
            budgetAttenuator: { budget, _, _ in
                let values = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                    ($0, budget.limits[$0])
                })
                var child = values
                child[.modelAttempts] = max(1, values[.modelAttempts]! / 2)
                child[.activeMilliseconds] = values[.activeMilliseconds]! / 2
                let attenuated = try AgentBudget(
                    limits: BudgetQuantities(child),
                    maximumThermalState: budget.maximumThermalState,
                    memoryPressureResponse: budget.memoryPressureResponse
                )
                _ = try budget.attenuating(to: attenuated, requireStrict: true)
                return attenuated
            }
        )
    }
}

enum WorkflowLaunchError: Error {
    case snapshotUnavailable
}
