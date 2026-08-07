// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import LLMCore
import MobileLLMUI

/// App-side workflow launcher (spec §22/§23): creates the reserved workflow-root run through the
/// normal frozen-input pipeline, then drives `WorkflowOrchestrator` so children attenuate from the
/// exact ceiling/budget/model policy the conversation would have used for a chat run.
@MainActor
final class WorkflowLauncher {
    private weak var container: AppContainer?
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
        guard let container else {
            throw WorkflowLaunchError.snapshotUnavailable("container deallocated")
        }
        guard let snapshot = makeAgentSnapshot(
            container: container,
            conversationID: conversationID,
            userTurnID: userMessageID,
            text: goal,
            imageRefs: [],
            downloadBase: downloadBase,
            onlineConfigBox: onlineConfigBox
        ) else {
            let fallback = container.models.model(id: container.settings.defaultModelID)?.id
                ?? LLMCatalog.all.first?.id ?? "nil"
            throw WorkflowLaunchError.snapshotUnavailable(
                "activeModel=\(container.chat.activeModel != nil) "
                    + "online=\(container.chat.onlineModelID ?? "nil") "
                + "fallback=\(fallback)"
            )
        }
        // Tool-selection gate (spec §2/§14/§33): the workflow only inherits what the conversation
        // already allows. Missing research tools are an explicit user-input/enable state, never
        // force-enabled here; approval mode does not substitute for tool selection.
        let missingTools = WorkflowToolPolicyGate.missingTools(
            policy: snapshot.toolPolicy,
            catalogToolNames: snapshot.localToolNames,
            toolsEnabled: snapshot.toolsEnabled
        )
        guard missingTools.isEmpty else {
            throw WorkflowToolPolicyGateError.toolsRequired(missingTools)
        }
        // Root and children carry the conversation's exact tool policy; SubagentSpawner further
        // attenuates every child's ceiling. Registering the template lets the input freezer rebuild
        // every child anchored to this message from the same inherited snapshot.
        let workflowSnapshot = snapshot
        AppWorkflowSnapshotRegistry.shared.register(
            conversationID: conversationID,
            userTurnID: userMessageID,
            template: workflowSnapshot
        )
        defer {
            AppWorkflowSnapshotRegistry.shared.unregister(
                conversationID: conversationID,
                userTurnID: userMessageID
            )
        }
        let root = try assembly.makeWorkflowRoot(
            snapshot: workflowSnapshot,
            workflowID: workflowID
        )
        let rootHandleID = try await assembly.executor.submit(
            root,
            commandID: WorkflowIdentity.rootCommand(workflowID: workflowID)
        )
        let parent = assembly.workflowParentContext(workflowID: workflowID, request: root)
        let title = goal.count <= 48 ? goal : String(goal.prefix(48)) + "…"
        // The running record anchors to the message immediately — the planner may take minutes and
        // the row must exist from the first frame (spec §20).
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
        // The workflow root is a planner: it emits the structured multi-phase plan. Simulator/device
        // E2E can inject a deterministic plan instead of depending on the planner model's JSON.
        let plan: WorkflowPlan
        if let raw = ProcessInfo.processInfo.environment["MOBILELLM_WORKFLOW_PLAN_JSON"],
           !raw.isEmpty,
           let data = raw.data(using: .utf8)
        {
            plan = try JSONDecoder().decode(WorkflowPlan.self, from: data)
        } else {
            let handle = try await assembly.executor.attach(to: rootHandleID)
            let result = try await waitForTerminalResult(handle: handle)
            if let structured = result?.answer?.structuredOutput,
               let decoded = try? WorkflowPlan.decode(from: structured)
            {
                plan = decoded
            } else {
                // The planner model is a preference, not a dependency: the runtime already gave it
                // one bounded structured-output repair, and the deterministic explore→plan→audit
                // fallback keeps the harness able to plan ANY goal.
                plan = try WorkflowPlan.fallback(goal: goal)
            }
        }
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
                // Exploration/audit children legitimately make several web searches per turn; the
                // parent's default ceiling is too tight for deep research (searches + page reads).
                child[.toolInvocations] = 10
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

    private func waitForTerminalResult(
        handle: any AgentExecutionHandle
    ) async throws -> AgentResult? {
        for _ in 0 ..< 1_200 {
            if let status = try? await handle.status(), status.state.isTerminal {
                return try await handle.result()
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return try await handle.result()
    }
}

enum WorkflowLaunchError: LocalizedError {
    case snapshotUnavailable(String)
    case planGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable(let reason):
            "Workflow snapshot unavailable: \(reason)"
        case .planGenerationFailed(let reason):
            "Workflow plan generation failed: \(reason)"
        }
    }
}
