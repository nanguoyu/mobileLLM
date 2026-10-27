// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public enum WorkflowRequestedOutcome: String, CaseIterable, Codable, Sendable {
    case answer, sourceText, workspaceArtifact, runningApplication, publishedService
}

public enum WorkflowDeliveryCapability: String, Codable, Sendable {
    case workspaceFiles, codeExecution, applicationInspection, publication

    var title: String {
        switch self {
        case .workspaceFiles: "workspace file access"
        case .codeExecution: "code execution"
        case .applicationInspection: "application interaction and testing"
        case .publication: "service publication"
        }
    }
}

/// The requested outcome is declared during preparation. Available capabilities are supplied by
/// the app's registered execution environment, never by a model's plan or claimed tool execution.
public struct WorkflowDeliveryPolicy: Codable, Sendable, Equatable {
    public let version: UInt16
    public let requestedOutcome: WorkflowRequestedOutcome
    public let availableCapabilities: [WorkflowDeliveryCapability]

    public init(requestedOutcome: WorkflowRequestedOutcome, availableCapabilities: [WorkflowDeliveryCapability]) {
        version = 1; self.requestedOutcome = requestedOutcome; self.availableCapabilities = availableCapabilities
    }

    public var missingCapabilities: [WorkflowDeliveryCapability] {
        let required: [WorkflowDeliveryCapability]
        switch requestedOutcome {
        case .answer, .sourceText: required = []
        case .workspaceArtifact: required = [.workspaceFiles]
        case .runningApplication: required = [.workspaceFiles, .codeExecution, .applicationInspection]
        case .publishedService: required = [.workspaceFiles, .codeExecution, .applicationInspection, .publication]
        }
        return required.filter { !availableCapabilities.contains($0) }
    }

    public var blocker: String? {
        guard !missingCapabilities.isEmpty else { return nil }
        return "The requested deliverable requires " + missingCapabilities.map(\.title).joined(separator: ", ")
            + ". No configured execution provider supplies these capabilities. The goal remains unfinished; a plan or source text cannot satisfy this delivery requirement."
    }

    /// Compare execution receipts with the latest observed source, including failed commands that
    /// changed files. Review prose, old revisions and unrelated goal workspaces cannot satisfy this.
    public func completionBlocker(workspaceID: SandboxWorkspaceHandleID,
                                  evidence: [WorkflowReviewToolEvidence]) -> String? {
        if let blocker { return blocker }
        guard requestedOutcome == .workspaceArtifact || requestedOutcome == .runningApplication else { return nil }
        let records = evidence.filter { $0.execution?.workspaceID == workspaceID }
            .sorted { ($0.completedAt?.rawValue ?? 0) < ($1.completedAt?.rawValue ?? 0) }
        guard let source = records.last(where: { $0.execution?.sourceDigest != nil })?.execution?.sourceDigest else {
            return "Execute the requested work in this goal's workspace before delivering it."
        }
        if let unknown = records.last(where: { $0.succeeded == false && $0.execution?.sourceDigest == nil
            && !["sandbox_process", "sandbox_stop"].contains($0.execution?.operation ?? "") }),
           (unknown.completedAt?.rawValue ?? 0) >= (records.last(where: { $0.execution?.sourceDigest != nil })?.completedAt?.rawValue ?? 0) {
            return "A failed operation left the current source snapshot unavailable. Inspect the workspace and obtain fresh review/export evidence before delivery."
        }
        let current = records.filter { $0.succeeded != false && $0.execution?.sourceDigest == source }
        guard current.contains(where: { $0.execution?.operation == "sandbox_export" &&
            $0.execution?.artifacts.contains(where: { $0.semanticType == "sandbox.project-source" && $0.mimeType == "application/zip" }) == true }) else {
            return "Export the current source once with sandbox_export. The archive must match the latest executed source version."
        }
        guard requestedOutcome == .runningApplication else { return nil }
        guard let inspection = current.last(where: { $0.execution?.operation == "sandbox_browser" &&
            $0.execution?.artifacts.contains(where: { $0.semanticType == "sandbox.browser-screenshot" }) == true }),
              let port = inspection.execution?.port,
              let start = current.last(where: { $0.execution?.operation == "sandbox_start" && $0.execution?.port == port && $0.execution?.running == true }),
              let process = start.execution?.processID,
              (start.completedAt?.rawValue ?? 0) <= (inspection.completedAt?.rawValue ?? 0),
              !records.contains(where: { $0.execution?.processID == process && $0.execution?.running == false
                  && ($0.completedAt?.rawValue ?? 0) > (start.completedAt?.rawValue ?? 0) }) else {
            return "Start the current source with sandbox_start, then test it with sandbox_browser. Reuse existing receipts for unchanged source; source changes require a fresh start and browser check."
        }
        return nil
    }

    public var json: JSONValue {
        .object(["version": .integer(1), "requestedOutcome": .string(requestedOutcome.rawValue),
            "availableCapabilities": .array(availableCapabilities.map { .string($0.rawValue) })])
    }
}
