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

    public var json: JSONValue {
        .object(["version": .integer(1), "requestedOutcome": .string(requestedOutcome.rawValue),
            "availableCapabilities": .array(availableCapabilities.map { .string($0.rawValue) })])
    }
}
