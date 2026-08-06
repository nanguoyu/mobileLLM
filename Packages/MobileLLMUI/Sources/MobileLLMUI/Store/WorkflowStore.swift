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
    public var onWorkflowChanged: (@MainActor (UUID) -> Void)?

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
        workflows[workflowID].map(WorkflowMessageRecord.init)
    }

    /// Loads the durable snapshot once at bootstrap. Missing/corrupt snapshots degrade to empty
    /// (workflow records are recoverable from the initiating message's persisted record).
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try decoder.decode([WorkflowSummary].self, from: data)
            workflows = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } catch {
            lastError = "Workflow snapshot could not be read: \(error.localizedDescription)"
        }
    }

    // MARK: - WorkflowRecording (called by the orchestrator)

    public func load(workflowID: UUID) async throws -> WorkflowSummary? {
        workflows[workflowID]
    }

    public func save(_ summary: WorkflowSummary) async throws {
        workflows[summary.id] = summary
        try persist()
        onWorkflowChanged?(summary.id)
    }

    public func remove(workflowID: UUID) {
        workflows.removeValue(forKey: workflowID)
        try? persist()
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
