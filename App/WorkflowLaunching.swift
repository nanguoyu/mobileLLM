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
    private var monitors: [UUID: Task<Void, Never>] = [:]

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
        let title = goal.count <= 48 ? goal : String(goal.prefix(48)) + "…"
        let dynamicRunID = WorkflowRunID(rawValue: workflowID)
        var summary = WorkflowSummary(
            id: workflowID,
            title: title,
            conversationID: conversationID,
            status: .running,
            dynamic: DynamicWorkflowPresentation(
                runID: dynamicRunID,
                state: .generatingCandidate
            )
        )
        try await container.workflowStore.save(summary)
        container.chat.attachWorkflowRecord(WorkflowMessageRecord(summary: summary), to: userMessageID)
        let candidate: AppDynamicWorkflowCandidatePreview
        do {
            candidate = try await prepareDynamicCandidate(
                goal: goal,
                conversationID: conversationID,
                userMessageID: userMessageID,
                workflowID: workflowID
            )
        } catch {
            summary.status = .failed
            summary.endTime = Date()
            summary.dynamic?.state = .failed
            summary.dynamic?.failure = error.localizedDescription
            try? await container.workflowStore.save(summary)
            throw error
        }
        do {
            // `/workflow` is itself the user's launch intent. Journal a one-run, digest-bound
            // approval and start immediately; child tools still cross their normal authorization
            // boundary independently.
            try await startPreparedDynamic(
                workflowID: workflowID,
                requiresApproval: candidate.launch.requiresApproval
            )
        } catch {
            try? await refreshDynamicSummary(workflowID: workflowID)
            throw error
        }
    }

    /// Relaunch resume (spec §23 recovery / §33 gap 3): reconstructs an unfinished workflow from its
    /// durable summary, re-registers the inherited tool-policy template for its children, rebuilds the
    /// parent context from the JOURNALED root request (frozen ceiling/budget/model policy — never a
    /// fresh guess), and advances every remaining phase. Children keep their stable identities, so the
    /// orchestrator re-collects completed work idempotently and only spawns missing work.
    func resume(workflowID: UUID) async throws {
        guard let container else {
            throw WorkflowLaunchError.snapshotUnavailable("container deallocated")
        }
        guard let summary = container.workflowStore.summary(workflowID: workflowID),
              summary.status == .running,
              summary.plan != nil,
              let conversationID = summary.conversationID
        else {
            throw WorkflowLaunchError.planGenerationFailed(
                "workflow \(workflowID) is not resumable (missing running summary/plan/conversation)"
            )
        }
        guard let userMessageID = container.chat.workflowInitiatingMessageID(
            conversationID: conversationID,
            workflowID: workflowID
        ) else {
            throw WorkflowLaunchError.snapshotUnavailable(
                "initiating message for workflow \(workflowID) is missing"
            )
        }
        guard let snapshot = makeAgentSnapshot(
            container: container,
            conversationID: conversationID,
            userTurnID: userMessageID,
            text: summary.title,
            imageRefs: [],
            downloadBase: downloadBase,
            onlineConfigBox: onlineConfigBox
        ) else {
            throw WorkflowLaunchError.snapshotUnavailable(
                "activeModel=\(container.chat.activeModel != nil) "
                    + "online=\(container.chat.onlineModelID ?? "nil")"
            )
        }
        AppWorkflowSnapshotRegistry.shared.register(
            conversationID: conversationID,
            userTurnID: userMessageID,
            template: snapshot
        )
        defer {
            AppWorkflowSnapshotRegistry.shared.unregister(
                conversationID: conversationID,
                userTurnID: userMessageID
            )
        }
        let rootRunID = WorkflowIdentity.rootRun(workflowID: workflowID)
        guard let facts = try await assembly.repository.loadRunFacts(for: rootRunID),
              let rootRequest = facts.submission?.request.payload
        else {
            throw WorkflowLaunchError.snapshotUnavailable(
                "journaled workflow root request for \(workflowID) is missing"
            )
        }
        let parent = WorkflowParentContext(
            runID: rootRequest.runID,
            requestID: rootRequest.id,
            requestingStepID: WorkflowIdentity.rootStep(workflowID: workflowID),
            capabilityCeiling: rootRequest.capabilityCeiling,
            budget: rootRequest.budget,
            modelPolicy: rootRequest.modelPolicy,
            approvalMode: rootRequest.approvalMode
        )
        _ = try await orchestrator.resume(
            workflowID: workflowID,
            parent: parent,
            ceilingAttenuator: ceilingAttenuator(),
            budgetAttenuator: budgetAttenuator()
        )
    }

    /// Reprojects known dynamic records from the hash-chained journal after relaunch. This is
    /// deliberately read-only: it never starts, resumes, or loads a model.
    func reconcileDynamicWorkflows() async {
        guard let container else { return }
        let ids = container.workflowStore.workflows.values.compactMap {
            $0.dynamic == nil ? nil : $0.id
        }
        for id in ids { try? await refreshDynamicSummary(workflowID: id) }
    }

    func runDynamic(workflowID: UUID) async throws {
        guard let state = container?.workflowStore.summary(workflowID: workflowID)?.dynamic?.state else {
            throw WorkflowLaunchError.snapshotUnavailable("dynamic workflow state is missing")
        }
        switch state {
        case .waitingForLaunchApproval:
            try await startPreparedDynamic(workflowID: workflowID, requiresApproval: true)
        case .queued:
            try await startPreparedDynamic(workflowID: workflowID, requiresApproval: false)
        default:
            throw WorkflowLaunchError.planGenerationFailed(
                "workflow is not ready to run from state \(state.rawValue)"
            )
        }
    }

    private func startPreparedDynamic(
        workflowID: UUID,
        requiresApproval: Bool
    ) async throws {
        let runID = try dynamicRunID(workflowID)
        if requiresApproval {
            _ = try await assembly.dynamicWorkflows.approveAndStart(runID: runID, reuseScope: nil)
        } else {
            try await assembly.dynamicWorkflows.start(runID: runID)
        }
        try await refreshDynamicSummary(workflowID: workflowID)
        container?.workflowStore.markDynamicExecutionAttached(workflowID: workflowID)
        monitorDynamic(workflowID: workflowID)
    }

    func denyDynamic(workflowID: UUID) async throws {
        let runID = try dynamicRunID(workflowID)
        try await assembly.dynamicWorkflows.deny(runID: runID)
        try await refreshDynamicSummary(workflowID: workflowID)
    }

    func startDynamic(workflowID: UUID) async throws {
        let runID = try dynamicRunID(workflowID)
        try await assembly.dynamicWorkflows.start(runID: runID)
        try await refreshDynamicSummary(workflowID: workflowID)
        container?.workflowStore.markDynamicExecutionAttached(workflowID: workflowID)
        monitorDynamic(workflowID: workflowID)
    }

    func pauseDynamic(workflowID: UUID) async throws {
        try await assembly.dynamicWorkflows.pause(runID: try dynamicRunID(workflowID))
        try await refreshDynamicSummary(workflowID: workflowID)
    }

    func resumeDynamic(workflowID: UUID) async throws {
        try await assembly.dynamicWorkflows.resume(runID: try dynamicRunID(workflowID))
        try await refreshDynamicSummary(workflowID: workflowID)
        container?.workflowStore.markDynamicExecutionAttached(workflowID: workflowID)
        monitorDynamic(workflowID: workflowID)
    }

    func reconcileDynamic(
        workflowID: UUID,
        decision: AgentReconciliationDecision
    ) async throws {
        let runID = try dynamicRunID(workflowID)
        guard let callID = container?.workflowStore
            .summary(workflowID: workflowID)?.dynamic?.reconciliationCallID
        else { throw WorkflowLaunchError.snapshotUnavailable("reconciliation call is missing") }
        try await assembly.dynamicWorkflows.reconcileAndResume(
            runID: runID,
            callID: callID,
            decision: decision
        )
        try await refreshDynamicSummary(workflowID: workflowID)
        container?.workflowStore.markDynamicExecutionAttached(workflowID: workflowID)
        monitorDynamic(workflowID: workflowID)
    }

    func stopDynamic(workflowID: UUID) async throws {
        try await assembly.dynamicWorkflows.stop(runID: try dynamicRunID(workflowID))
        try await refreshDynamicSummary(workflowID: workflowID)
    }

    func restartDynamicAgent(
        workflowID: UUID,
        callID: WorkflowAgentCallID
    ) async throws {
        try await assembly.dynamicWorkflows.restartAgent(
            runID: try dynamicRunID(workflowID),
            callID: callID
        )
        try await refreshDynamicSummary(workflowID: workflowID)
        container?.workflowStore.markDynamicExecutionAttached(workflowID: workflowID)
        monitorDynamic(workflowID: workflowID)
    }

    private func dynamicRunID(_ workflowID: UUID) throws -> WorkflowRunID {
        guard let runID = container?.workflowStore.summary(workflowID: workflowID)?.dynamic?.runID else {
            throw WorkflowLaunchError.snapshotUnavailable("dynamic workflow record is missing")
        }
        return runID
    }

    private func refreshDynamicSummary(workflowID: UUID) async throws {
        guard let container,
              var summary = container.workflowStore.summary(workflowID: workflowID),
              let runID = summary.dynamic?.runID
        else { return }
        guard let recovered = try await assembly.dynamicWorkflows.recoveredCandidate(runID: runID) else {
            // Candidate generation is a normal durable model run, but no workflow script exists
            // until that run returns analyzable source. Relaunch must not leave an orphaned row
            // pretending to generate forever, and it must not auto-resume/load the model.
            if summary.dynamic?.state == .generatingCandidate {
                summary.status = .failed
                summary.endTime = Date()
                summary.dynamic?.state = .failed
                summary.dynamic?.failure =
                    "Candidate generation was interrupted. Send the /workflow command again."
                try await container.workflowStore.save(summary)
            }
            return
        }
        let projection = recovered.projection
        summary.dynamic = DynamicWorkflowPresentation(
            runID: runID,
            scriptReference: recovered.savedScript.script.reference,
            metadata: recovered.savedScript.metadata,
            source: recovered.savedScript.script.source,
            state: DynamicWorkflowPresentationState(projection.state),
            currentPhase: projection.currentPhase,
            logs: projection.logs,
            completedCallCount: projection.completedCallCount,
            totalCallCount: projection.calls.count,
            childCalls: projection.childCalls,
            reconciliationCallID: projection.reconciliationCallID,
            failure: projection.failure
        )
        summary.status = summary.dynamic!.state.workflowStatus
        if projection.state.isTerminal, summary.endTime == nil { summary.endTime = Date() }
        summary.aggregated = WorkflowAggregatedStats(
            subagentCount: projection.childCalls.filter { $0.handleID != nil }.count,
            elapsedMilliseconds: Int64(max(0, (summary.endTime ?? Date()).timeIntervalSince(summary.startTime) * 1000)),
            inputTokens: Int64(clamping: projection.usage.quantities[.inputTokens]),
            outputTokens: Int64(clamping: projection.usage.quantities[.outputTokens]),
            toolInvocationCount: Int64(clamping: projection.usage.quantities[.toolInvocations])
        )
        if projection.output != nil,
           let output = try await assembly.dynamicWorkflows.resolvedOutput(runID: runID)
        {
            if let value = try? JSONDecoder().decode(JSONValue.self, from: output.data),
               case .string(let text) = value
            {
                summary.finalAnswer = text
            } else {
                summary.finalAnswer = output.string
            }
        }
        try await container.workflowStore.save(summary)
    }

    private func monitorDynamic(workflowID: UUID) {
        monitors[workflowID]?.cancel()
        monitors[workflowID] = Task { [weak self] in
            for _ in 0 ..< 14_400 {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                try? await self.refreshDynamicSummary(workflowID: workflowID)
                guard let state = self.container?.workflowStore
                    .summary(workflowID: workflowID)?.dynamic?.state,
                    ![.completed, .failed, .cancelled, .paused, .waitingForForeground,
                      .waitingForReconciliation].contains(state)
                else { return }
            }
        }
    }

    func suspendForDataErase() async throws {
        let tasks = Array(monitors.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        monitors.removeAll()
        try await assembly.dynamicWorkflows.suspendForDataErase()
        try await assembly.executor.controller.suspendForDataErase()
    }

    func quiesceForBackground(excluding conversationID: UUID? = nil) async throws {
        let protected = Set((container?.workflowStore.workflows.values.map { $0 } ?? [])
            .filter { conversationID != nil && $0.conversationID == conversationID }
            .map { WorkflowRunID(rawValue: $0.id) })
        try await assembly.dynamicWorkflows.quiesceForBackground(excluding: protected)
        for id in container?.workflowStore.workflows.keys.map({ $0 }) ?? [] {
            try? await refreshDynamicSummary(workflowID: id)
        }
    }

    /// Freeze a model-created plan, then save the exact reviewed coordination program. All work,
    /// replanning, delivery and review use the same durable child calls and replay path.
    func prepareDynamicCandidate(
        goal: String,
        conversationID: UUID,
        userMessageID: UUID,
        workflowID: UUID,
        scope: WorkflowScriptScopeV1 = .conversation
    ) async throws -> AppDynamicWorkflowCandidatePreview {
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
            throw WorkflowLaunchError.snapshotUnavailable("dynamic workflow snapshot unavailable")
        }
        return try await assembly.prepareCoordinatedWorkflow(
            snapshot: snapshot, runID: WorkflowRunID(rawValue: workflowID), scope: scope
        )
    }

    private func ceilingAttenuator() -> WorkflowCeilingAttenuator {
        { ceiling, _, _ in
            let capabilities = AgentCapabilitySet(
                ceiling.capabilities.values.filter {
                    $0 != AppFrozenInputBuilder.workflowDelegationCapability
                }
            )
            return try ceiling.attenuating(
                to: AgentAuthorityScope(
                    capabilities: capabilities,
                    destinations: ceiling.authority.destinations,
                    dataCategories: ceiling.authority.dataCategories
                ),
                requireStrict: true
            )
        }
    }

    private func budgetAttenuator() -> WorkflowBudgetAttenuator {
        { budget, _, _ in
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
    }
}

/// One production launch path shared by chat and opt-in runtime evaluations.
@MainActor
extension AgentRuntimeAssembly {
    func prepareCoordinatedWorkflow(
        snapshot: AgentRunRequestSnapshot,
        runID: WorkflowRunID,
        scope: WorkflowScriptScopeV1 = .conversation
    ) async throws -> AppDynamicWorkflowCandidatePreview {
        if !AppFrozenInputBuilder.isOnline(snapshot: snapshot) {
            try await requestBuilder.localModels.register(
                frozenBuilder.registration(snapshot: snapshot)
            )
        }
        let runDate = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let coordinator = try makeWorkflowCoordinator(snapshot: snapshot, runDate: runDate)
        let handleID = try await executor.submit(coordinator, commandID: AgentCommandID())
        let handle = try await executor.attach(to: handleID)
        guard let result = try await waitForTerminalResult(handle: handle),
              result.status.state == .completed,
              let plan = result.answer?.structuredOutput
        else {
            throw WorkflowLaunchError.planGenerationFailed("The coordinator did not return an executable plan.")
        }
        return try await dynamicWorkflows.prepareCandidate(
            source: CoordinatedWorkflow.source,
            scriptID: WorkflowScriptID(),
            version: 1,
            scope: scope,
            args: try CanonicalJSON(.object([
                "goal": .string(snapshot.text), "plan": plan,
                "runDate": .string(runDate),
                "availableTools": .array(try availableWorkflowTools(snapshot: snapshot).map(JSONValue.string)),
            ])),
            initiatingRunID: coordinator.runID,
            runID: runID
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

public struct AppDynamicWorkflowCandidatePreview: Hashable, Sendable {
    public let savedScript: SavedWorkflowScriptV1
    public let launch: WorkflowLaunchPreview
}

public struct AppDynamicWorkflowRecoveredCandidate: Hashable, Sendable {
    public let savedScript: SavedWorkflowScriptV1
    public let projection: AppDynamicWorkflowProjection
}

/// Narrow projection consumed by the existing unified conversation UI. It exposes durable status
/// and inspectable child activity without introducing a second navigation or orchestration UI.
public struct AppDynamicWorkflowProjection: Hashable, Sendable {
    public let runID: WorkflowRunID
    public let state: WorkflowRunStateV1
    public let currentPhase: String?
    public let logs: [String]
    public let calls: [WorkflowAgentCallV1]
    public let childCalls: [DynamicWorkflowChildPresentation]
    public let completedCallCount: Int
    public let usage: AgentUsage
    public let output: WorkflowValueReferenceV1?
    public let reconciliationCallID: WorkflowAgentCallID?
    public let failure: String?

    init(_ projection: WorkflowRunProjectionV1, preparationUsage: AgentUsage = .zero) throws {
        runID = projection.runID
        state = projection.state
        currentPhase = projection.currentPhase
        logs = projection.logs
        calls = projection.calls
        childCalls = projection.calls.map { call in
            let outcome = projection.outcomes[call.callID]
            let status: DynamicWorkflowChildStatus
            let detail: String?
            if projection.reconciliationCallID == call.callID {
                status = .uncertain
                detail = "Outcome requires reconciliation"
            } else if let outcome {
                switch outcome {
                case .completed:
                    status = .completed
                    detail = nil
                case .failed(let failure, _):
                    status = .failed
                    detail = failure.safeMessage
                case .unavailable(let reason, _):
                    status = .unavailable
                    detail = reason
                case .stopped:
                    status = .stopped
                    detail = nil
                }
            } else if projection.submittedHandles[call.callID] != nil {
                status = .submitted
                detail = nil
            } else {
                status = .prepared
                detail = nil
            }
            return DynamicWorkflowChildPresentation(
                callID: call.callID,
                ordinal: call.ordinal,
                attempt: call.attempt,
                label: call.options.label,
                phase: call.options.phase,
                childRunID: call.childRunID,
                handleID: projection.submittedHandles[call.callID],
                status: status,
                detail: detail
            )
        }
        completedCallCount = projection.outcomes.count
        usage = try projection.usage.aggregating(preparationUsage)
        output = projection.output
        reconciliationCallID = projection.reconciliationCallID
        failure = projection.failure
    }
}

/// Production application facade for the package runtime. All execution controls are explicit;
/// constructing the service or opening the app performs no workflow, model, or child-agent work.
public actor AppDynamicWorkflowService {
    private struct ToolBinding: Encodable {
        let catalog: ToolCatalogSnapshot
        let policy: ConversationToolPolicy
    }

    private struct PolicyBinding: Encodable {
        let generation: AgentModelGenerationParameters
        let contextBudget: ContextTokenBudget
        let baseSystem: BaseSystemContextSource
        let skills: [SkillInstructionContextSource]
        let availableToolCapabilities: AgentCapabilitySet
        let contextPolicyVersion: UInt32
        let approvalPolicyVersion: UInt32
    }

    private let engine: DynamicWorkflowEngine
    private let journal: SQLiteDynamicWorkflowJournal
    private let repository: SQLiteRunJournal
    private let payloadStore: ContentAddressedExecutionPayloadStore
    private let valueStore: any WorkflowValueStoring
    private let childRequestBuilder: AppDynamicWorkflowChildRequestBuilder
    private let analyzer = DynamicWorkflowScriptAnalyzer()

    init(
        engine: DynamicWorkflowEngine,
        journal: SQLiteDynamicWorkflowJournal,
        repository: SQLiteRunJournal,
        payloadStore: ContentAddressedExecutionPayloadStore,
        valueStore: any WorkflowValueStoring,
        childRequestBuilder: AppDynamicWorkflowChildRequestBuilder
    ) {
        self.engine = engine
        self.journal = journal
        self.repository = repository
        self.payloadStore = payloadStore
        self.valueStore = valueStore
        self.childRequestBuilder = childRequestBuilder
    }

    /// Normalizes/analyzes one exact candidate, saves it through the durable workflow journal, and
    /// returns a preview. It never approves or starts the script.
    public func suspendForDataErase() async throws {
        try await engine.suspendForDataErase()
        childRequestBuilder.removeAll()
    }

    public func resumeAfterDataErase() async { await engine.resumeAfterDataErase() }
    public func quiesceForBackground(excluding runs: Set<WorkflowRunID> = []) async throws { try await engine.quiesceForBackground(excluding: runs) }

    public func prepareCandidate(
        source: String,
        scriptID: WorkflowScriptID = WorkflowScriptID(),
        version: UInt64 = 1,
        scope: WorkflowScriptScopeV1 = .conversation,
        args: CanonicalJSON? = nil,
        initiatingRunID: AgentRunID,
        runID: WorkflowRunID = WorkflowRunID(),
        runtimeRequirement: WorkflowRuntimeRequirementV1 = .init(),
        limits: WorkflowRunLimitsV1 = .iPhoneDefault()
    ) async throws -> AppDynamicWorkflowCandidatePreview {
        let script = try WorkflowScriptV1(
            scriptID: scriptID,
            version: version,
            source: source
        )
        let analyzed = try analyzer.analyze(script)
        let parent = try await loadParent(runID: initiatingRunID)
        if parent.request.role == "workflow-generator" || parent.request.role == "workflow-coordinator" {
            try Self.validateDeclaredStages(analyzed, requireExplicitToolBudgets: true)
        }
        let owner = workflowScriptOwner(scope: scope, conversationID: parent.request.conversationID)
        let saved = SavedWorkflowScriptV1(
            script: script,
            metadata: analyzed.metadata,
            owner: owner,
            createdAt: try AgentTimestamp(Date())
        )
        let launch = WorkflowLaunchSnapshotV1(
            runID: runID,
            scriptReference: script.reference,
            args: args,
            conversationID: parent.request.conversationID,
            initiatingRunID: parent.request.runID,
            initiatingRequestID: parent.request.id,
            requestingStepID: AgentStepID(rawValue: runID.rawValue),
            capabilityCeiling: parent.request.capabilityCeiling,
            budget: parent.request.budget,
            defaultModelPolicy: parent.request.modelPolicy,
            toolPolicyDigest: try digest(ToolBinding(
                catalog: parent.frozen.toolCatalog,
                policy: parent.frozen.toolPolicy
            ), domain: "app-dynamic-workflow-tool-binding.v1"),
            policySnapshotDigest: try digest(PolicyBinding(
                generation: parent.frozen.generationParameters,
                contextBudget: parent.frozen.contextBudget,
                baseSystem: parent.frozen.baseSystem,
                skills: parent.frozen.skills,
                availableToolCapabilities: parent.frozen.availableToolCapabilities,
                contextPolicyVersion: parent.frozen.contextPolicyVersion,
                approvalPolicyVersion: parent.frozen.approvalPolicyVersion
            ), domain: "app-dynamic-workflow-policy-binding.v1"),
            runtimeRequirement: runtimeRequirement,
            limits: limits,
            approvalMode: parent.request.approvalMode,
            savedWorkflowOwners: [owner]
        )
        try childRequestBuilder.register(launch: launch, parent: parent)
        let preview = try await engine.prepareLaunch(script: saved, snapshot: launch)
        return AppDynamicWorkflowCandidatePreview(savedScript: saved, launch: preview)
    }

    /// Candidate-only lint. Archived scripts retain the V1 analyzer/replay contract. A metadata
    /// promise is not execution: comments and string literals cannot satisfy these call checks.
    static func validateDeclaredStages(_ analyzed: AnalyzedWorkflowScriptV1, requireExplicitToolBudgets: Bool = false) throws {
        if requireExplicitToolBudgets, analyzed.hasUnawaitedHostReturnInCatch {
            throw WorkflowScriptAnalysisError.unsupportedConstruct(
                "an async try/catch must return await agent(...) to catch a rejected host call; returning its promise does not catch rejection"
            )
        }
        if requireExplicitToolBudgets, analyzed.explicitlyBudgetedAgentCallSites != analyzed.staticAgentCallSites {
            throw WorkflowScriptAnalysisError.unsupportedConstruct(
                "each generated agent must declare maxToolCalls; use the role allowance or zero for tool-free synthesis"
            )
        }
        let phases = analyzed.metadata.phases
        if !phases.isEmpty, analyzed.staticPhaseCallSites == 0 {
            throw WorkflowScriptAnalysisError.unsupportedConstruct(
                "declared phases need phase(title) calls at the actual stage boundaries"
            )
        }
        let declaresParallel = phases.contains {
            let description = $0.title + " " + ($0.detail ?? "")
            return description.localizedCaseInsensitiveContains("parallel") || description.contains("并行")
        }
        if declaresParallel, analyzed.staticParallelCallSites == 0 {
            throw WorkflowScriptAnalysisError.unsupportedConstruct(
                "phase metadata declares parallel work but the script has no parallel fan-out"
            )
        }
    }

    public func approve(
        runID: WorkflowRunID,
        reuseScope: WorkflowLaunchApprovalReuseScopeV1? = nil
    ) async throws -> ApprovalID {
        let approvalID = ApprovalID()
        try await engine.approveLaunch(
            runID: runID,
            approvalID: approvalID,
            reuseScope: reuseScope
        )
        return approvalID
    }

    public func deny(runID: WorkflowRunID, reason: String = "launch-denied") async throws {
        try await engine.denyLaunch(runID: runID, reason: reason)
    }

    public func start(runID: WorkflowRunID) async throws {
        try await restoreParentBinding(runID: runID)
        try await engine.start(runID: runID)
    }

    @discardableResult
    public func approveAndStart(
        runID: WorkflowRunID,
        reuseScope: WorkflowLaunchApprovalReuseScopeV1? = nil
    ) async throws -> ApprovalID {
        let approvalID = try await approve(runID: runID, reuseScope: reuseScope)
        try await start(runID: runID)
        return approvalID
    }

    public func pause(runID: WorkflowRunID) async throws {
        try await engine.pause(runID: runID)
    }

    public func resume(runID: WorkflowRunID) async throws {
        try await restoreParentBinding(runID: runID)
        try await engine.resume(runID: runID)
    }

    public func reconcileAndResume(
        runID: WorkflowRunID,
        callID: WorkflowAgentCallID,
        decision: AgentReconciliationDecision
    ) async throws {
        try await restoreParentBinding(runID: runID)
        try await engine.reconcileAgent(runID: runID, callID: callID, decision: decision)
        try await engine.start(runID: runID)
    }

    public func stop(runID: WorkflowRunID) async throws {
        try await engine.stop(runID: runID)
    }

    public func restartAgent(
        runID: WorkflowRunID,
        callID: WorkflowAgentCallID
    ) async throws {
        try await restoreParentBinding(runID: runID)
        try await engine.restartAgent(runID: runID, callID: callID)
    }

    public func projection(runID: WorkflowRunID) async throws -> AppDynamicWorkflowProjection? {
        guard let projection = try await engine.projection(runID: runID) else { return nil }
        return try await presentation(projection)
    }

    public func recoveredCandidate(
        runID: WorkflowRunID
    ) async throws -> AppDynamicWorkflowRecoveredCandidate? {
        guard let projection = try await engine.projection(runID: runID),
              let script = try await journal.loadScript(
                  projection.launch.scriptReference,
                  owners: projection.launch.savedWorkflowOwners
              )
        else { return nil }
        return AppDynamicWorkflowRecoveredCandidate(
            savedScript: script,
            projection: try await presentation(projection)
        )
    }

    private func presentation(_ projection: WorkflowRunProjectionV1) async throws -> AppDynamicWorkflowProjection {
        // Preparation is a real model call even when it returns the answer without delegating.
        // Derive its usage afresh from the journal, so repeated projection cannot double-count it.
        let parent = try await repository.loadRunFacts(for: projection.launch.initiatingRunID)
        let role = parent?.submission?.request.payload.role
        let preparation = role == "workflow-coordinator" || role == "workflow-generator"
            ? parent?.projection.cumulativeUsage ?? .zero : .zero
        return try AppDynamicWorkflowProjection(projection, preparationUsage: preparation)
    }

    public func resolvedOutput(runID: WorkflowRunID) async throws -> CanonicalJSON? {
        guard let output = try await engine.projection(runID: runID)?.output else { return nil }
        return try await valueStore.load(output)
    }

    public func savedScripts(
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> [SavedWorkflowScriptV1] {
        try await journal.listScripts(owners: owners)
    }

    public func resolveSavedScript(
        named name: String,
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> SavedWorkflowScriptV1? {
        try await journal.resolveScript(named: name, owners: owners)
    }

    private func restoreParentBinding(runID: WorkflowRunID) async throws {
        guard let projection = try await engine.projection(runID: runID) else {
            throw AppDynamicWorkflowIntegrationError.parentRunUnavailable
        }
        let parent = try await loadParent(runID: projection.launch.initiatingRunID)
        try childRequestBuilder.register(launch: projection.launch, parent: parent)
    }

    private func loadParent(
        runID: AgentRunID
    ) async throws -> AppDynamicWorkflowChildRequestBuilder.Parent {
        guard let facts = try await repository.loadRunFacts(for: runID),
              let submission = facts.submission,
              let artifactID = submission.inputSnapshot.artifactID,
              let artifact = await payloadStore.reference(for: artifactID),
              artifact.contentDigest == submission.inputSnapshot.digest
        else { throw AppDynamicWorkflowIntegrationError.parentRunUnavailable }
        let data = try await payloadStore.load(
            artifact,
            maximumBytes: UInt64(CanonicalJSON.maximumBytes)
        )
        guard StableDigest.sha256(data) == submission.inputSnapshot.digest else {
            throw AppDynamicWorkflowIntegrationError.frozenInputUnavailable
        }
        let frozen: FrozenAgentRunInputs
        do {
            frozen = try JSONDecoder().decode(FrozenAgentRunInputs.self, from: data)
        } catch {
            throw AppDynamicWorkflowIntegrationError.frozenInputUnavailable
        }
        let request = submission.request.payload
        guard request.modelPolicy.allowedSelections.contains(frozen.modelSelection),
              request.userTurnID.description == frozen.currentUser.frozen.sourceID,
              request.artifactReferences == frozen.currentUser.attachments,
              request.capabilityCeiling.capabilities.contains(
                  AppFrozenInputBuilder.workflowDelegationCapability
              )
        else { throw AppDynamicWorkflowIntegrationError.parentBindingMismatch }
        return AppDynamicWorkflowChildRequestBuilder.Parent(request: request, frozen: frozen)
    }

    private func digest<T: Encodable>(_ value: T, domain: String) throws -> StableDigest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return StableDigest.fingerprint(domain: domain, components: [try encoder.encode(value)])
    }

    private func workflowScriptOwner(
        scope: WorkflowScriptScopeV1,
        conversationID: ConversationID
    ) -> WorkflowScriptOwnerV1 {
        switch scope {
        case .conversation:
            .conversation(conversationID)
        case .personal:
            .personal(StableDigest.fingerprint(
                domain: "mobilellm.workflow-catalog.personal.v1",
                components: []
            ))
        case .project:
            .project(StableDigest.fingerprint(
                domain: "mobilellm.workflow-catalog.default-project.v1",
                components: []
            ))
        case .bundled:
            .bundled(StableDigest.fingerprint(
                domain: "mobilellm.workflow-catalog.bundled.v1",
                components: []
            ))
        }
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
