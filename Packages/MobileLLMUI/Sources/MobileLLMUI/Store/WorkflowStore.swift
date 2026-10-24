// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AgentContracts
import AgentRuntime

/// Durable workflow summaries (spec §23/§23.1). One JSON snapshot beside the conversation records,
/// atomically replaced on every mutation; also serves as the `WorkflowRecording` seam consumed by
/// `WorkflowOrchestrator`, so relaunch can resume the exact phase tree.
@MainActor
@Observable
public final class WorkflowStore: WorkflowRecording {
    public private(set) var workflows: [UUID: WorkflowSummary] = [:]
    public private(set) var lastError: String?
    public private(set) var resumingWorkflowIDs: Set<UUID> = []
    public private(set) var actioningWorkflowIDs: Set<UUID> = []
    /// Workflows known to be executing in this process. A durable `.running` record loaded from disk
    /// is deliberately absent until the user explicitly resumes it.
    public private(set) var executingWorkflowIDs: Set<UUID> = []
    public var onWorkflowChanged: (@MainActor (UUID) -> Void)?
    /// App-owned recovery seam. Loading the store never calls it; only an explicit Resume action
    /// from the workflow UI may restart durable work.
    public var resumeHandler: (@MainActor (UUID) async throws -> Void)?
    public var dynamicRunHandler: (@MainActor (UUID) async throws -> Void)?
    public var dynamicDenyHandler: (@MainActor (UUID) async throws -> Void)?
    public var dynamicStartHandler: (@MainActor (UUID) async throws -> Void)?
    public var dynamicPauseHandler: (@MainActor (UUID) async throws -> Void)?
    public var dynamicResumeHandler: (@MainActor (UUID) async throws -> Void)?
    public var dynamicReconcileHandler: (@MainActor (UUID, AgentReconciliationDecision) async throws -> Void)?
    public var dynamicStopHandler: (@MainActor (UUID) async throws -> Void)?
    public var dynamicRestartHandler: (@MainActor (UUID, WorkflowAgentCallID) async throws -> Void)?
    public var dynamicResultHandler: (@MainActor (UUID, WorkflowAgentCallID) async throws -> String?)?
    public var dynamicObserverHandler: (@MainActor (UUID, WorkflowAgentCallID) async throws -> AgentRunStore?)?
    public var planningObserverHandler: (@MainActor (UUID) async throws -> AgentRunStore?)?

    public func observePlanning(workflowID: UUID) async throws -> AgentRunStore? {
        guard workflows[workflowID] != nil, let planningObserverHandler else { throw WorkflowStoreActionError.unavailable }
        return try await planningObserverHandler(workflowID)
    }

    public func observeTask(workflowID: UUID, callID: WorkflowAgentCallID) async throws -> AgentRunStore? {
        guard workflows[workflowID] != nil, let dynamicObserverHandler else {
            throw WorkflowStoreActionError.unavailable
        }
        return try await dynamicObserverHandler(workflowID, callID)
    }

    public func result(workflowID: UUID, callID: WorkflowAgentCallID) async throws -> String? {
        guard workflows[workflowID] != nil, let dynamicResultHandler else {
            throw WorkflowStoreActionError.unavailable
        }
        return try await dynamicResultHandler(workflowID, callID)
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil, directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("mobileLLM", isDirectory: true)
        self.fileURL = fileURL ?? base.appendingPathComponent("workflows.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public var hasRunningWorkflow: Bool {
        workflows.values.contains { $0.status == .running }
    }

    public func summary(workflowID: UUID) -> WorkflowSummary? {
        workflows[workflowID]
    }

    public func messageRecord(workflowID: UUID) -> WorkflowMessageRecord? {
        guard let summary = workflows[workflowID] else { return nil }
        var record = WorkflowMessageRecord(summary: summary)
        if summary.dynamic != nil {
            record.isAttachedInCurrentProcess = executingWorkflowIDs.contains(workflowID)
        }
        return record
    }

    public func resume(workflowID: UUID) async {
        guard workflows[workflowID]?.status == .running,
              !executingWorkflowIDs.contains(workflowID),
              !resumingWorkflowIDs.contains(workflowID),
              let resumeHandler
        else { return }
        resumingWorkflowIDs.insert(workflowID)
        executingWorkflowIDs.insert(workflowID)
        lastError = nil
        defer { resumingWorkflowIDs.remove(workflowID) }
        do {
            try await resumeHandler(workflowID)
        } catch {
            executingWorkflowIDs.remove(workflowID)
            lastError = "Workflow could not resume: \(error.localizedDescription)"
        }
    }

    public func runDynamic(workflowID: UUID) async {
        await performDynamicAction(workflowID: workflowID) { [dynamicRunHandler] in
            guard let dynamicRunHandler else { throw WorkflowStoreActionError.unavailable }
            try await dynamicRunHandler(workflowID)
        }
    }

    public func denyDynamic(workflowID: UUID) async {
        await performDynamicAction(workflowID: workflowID) { [dynamicDenyHandler] in
            guard let dynamicDenyHandler else { throw WorkflowStoreActionError.unavailable }
            try await dynamicDenyHandler(workflowID)
        }
    }

    public func startDynamic(workflowID: UUID) async {
        await performDynamicAction(workflowID: workflowID) { [dynamicStartHandler] in
            guard let dynamicStartHandler else { throw WorkflowStoreActionError.unavailable }
            try await dynamicStartHandler(workflowID)
        }
    }

    public func pauseDynamic(workflowID: UUID) async {
        await performDynamicAction(workflowID: workflowID) { [dynamicPauseHandler] in
            guard let dynamicPauseHandler else { throw WorkflowStoreActionError.unavailable }
            try await dynamicPauseHandler(workflowID)
        }
    }

    public func resumeDynamic(workflowID: UUID) async {
        await performDynamicAction(workflowID: workflowID) { [dynamicResumeHandler] in
            guard let dynamicResumeHandler else { throw WorkflowStoreActionError.unavailable }
            try await dynamicResumeHandler(workflowID)
        }
    }

    public func stopDynamic(workflowID: UUID) async {
        await performDynamicAction(workflowID: workflowID) { [dynamicStopHandler] in
            guard let dynamicStopHandler else { throw WorkflowStoreActionError.unavailable }
            try await dynamicStopHandler(workflowID)
        }
    }

    public func restartDynamic(workflowID: UUID, callID: WorkflowAgentCallID) async {
        await performDynamicAction(workflowID: workflowID) { [dynamicRestartHandler] in
            guard let dynamicRestartHandler else { throw WorkflowStoreActionError.unavailable }
            try await dynamicRestartHandler(workflowID, callID)
        }
    }

    /// Marks attachment only after an explicit Start/Resume/Restart succeeds. Journal projection
    /// and `load()` never call this, preserving neutral relaunch semantics.
    public func markDynamicExecutionAttached(workflowID: UUID) {
        guard workflows[workflowID]?.dynamic != nil else { return }
        executingWorkflowIDs.insert(workflowID)
        onWorkflowChanged?(workflowID)
    }

    public func reconcileDynamic(
        workflowID: UUID,
        decision: AgentReconciliationDecision
    ) async {
        await performDynamicAction(workflowID: workflowID) { [dynamicReconcileHandler] in
            guard let dynamicReconcileHandler else { throw WorkflowStoreActionError.unavailable }
            try await dynamicReconcileHandler(workflowID, decision)
        }
    }

    /// Loads the durable snapshot once at bootstrap. Missing/corrupt snapshots degrade to empty
    /// (workflow records are recoverable from the initiating message's persisted record).
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try decoder.decode([WorkflowSummary].self, from: data)
            workflows = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
            executingWorkflowIDs.removeAll()
        } catch {
            lastError = "Workflow snapshot could not be read: \(error.localizedDescription)"
        }
    }

    // MARK: - WorkflowRecording (called by the orchestrator)

    public func load(workflowID: UUID) async throws -> WorkflowSummary? {
        workflows[workflowID]
    }

    public func save(_ summary: WorkflowSummary) async throws {
        guard workflows[summary.id] != summary else { return }
        workflows[summary.id] = summary
        if summary.dynamic == nil, summary.status == .running {
            executingWorkflowIDs.insert(summary.id)
        } else if let dynamic = summary.dynamic,
                  summary.status != .running
                    || ![DynamicWorkflowPresentationState.running, .pausing].contains(dynamic.state)
        {
            executingWorkflowIDs.remove(summary.id)
        }
        try persist()
        onWorkflowChanged?(summary.id)
    }

    public func remove(workflowID: UUID) {
        workflows.removeValue(forKey: workflowID)
        resumingWorkflowIDs.remove(workflowID)
        executingWorkflowIDs.remove(workflowID)
        actioningWorkflowIDs.remove(workflowID)
        try? persist()
    }

    private func performDynamicAction(
        workflowID: UUID,
        operation: () async throws -> Void
    ) async {
        guard workflows[workflowID]?.dynamic != nil,
              !actioningWorkflowIDs.contains(workflowID)
        else { return }
        actioningWorkflowIDs.insert(workflowID)
        lastError = nil
        defer { actioningWorkflowIDs.remove(workflowID) }
        do {
            try await operation()
        } catch {
            lastError = "Workflow action failed: \(error.localizedDescription)"
        }
    }

    public func eraseAllData() throws {
        workflows.removeAll()
        resumingWorkflowIDs.removeAll()
        executingWorkflowIDs.removeAll()
        actioningWorkflowIDs.removeAll()
        lastError = nil
        for url in [fileURL, fileURL.appendingPathExtension("tmp"), fileURL.appendingPathExtension("corrupt")] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private func persist() throws {
        let data = try encoder.encode(Array(workflows.values.sorted {
            $0.startTime < $1.startTime
        }))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum WorkflowStoreActionError: LocalizedError {
    case unavailable

    var errorDescription: String? { "This workflow action is unavailable." }
}
