// SPDX-License-Identifier: MIT

import Foundation

/// A model-authored acceptance plan, frozen when its required review task is created.
/// A review is an agent judgement; recorded tool evidence is a separate execution fact.
public struct WorkflowReviewCriterion: Hashable, Codable, Sendable {
    public let id: String
    public let requirement: String
    public let targetTaskIDs: [String]

    public init(id: String, requirement: String, targetTaskIDs: [String]) {
        self.id = id; self.requirement = requirement; self.targetTaskIDs = targetTaskIDs
    }
}

public struct WorkflowTaskReview: Hashable, Codable, Sendable {
    public let criteria: [WorkflowReviewCriterion]
    /// Exact enabled tool IDs whose successful execution must be recorded by this reviewer.
    public let requiredTools: [String]

    public init(criteria: [WorkflowReviewCriterion], requiredTools: [String] = []) {
        self.criteria = criteria; self.requiredTools = requiredTools
    }

    public var targetTaskIDs: Set<String> { Set(criteria.flatMap(\.targetTaskIDs)) }

    public func validate() throws {
        guard (1...12).contains(criteria.count), Set(criteria.map(\.id)).count == criteria.count,
              criteria.allSatisfy({
                  AgentWireValidation.isNonblankControlFree($0.id, maximumLength: 48)
                      && AgentWireValidation.isNonblankControlFree($0.requirement, maximumLength: 2_000)
                      && (1...8).contains($0.targetTaskIDs.count)
                      && Set($0.targetTaskIDs).count == $0.targetTaskIDs.count
              }), requiredTools.count <= 6, Set(requiredTools).count == requiredTools.count,
              requiredTools.allSatisfy({ AgentWireValidation.isNonblankControlFree($0, maximumLength: 256) })
        else { throw WorkflowTaskGraphError.invalid }
    }
}

public enum WorkflowReviewStatus: String, Hashable, Codable, Sendable {
    case pass, revise, blocked
}

public struct WorkflowReviewCheck: Hashable, Codable, Sendable {
    public let id: String
    public let status: WorkflowReviewStatus
    public let detail: String

    public init(id: String, status: WorkflowReviewStatus, detail: String) {
        self.id = id; self.status = status; self.detail = detail
    }
}

/// Only this report is model-authored. Artifact identities and tool receipts are attached by the host.
public struct WorkflowReviewReport: Hashable, Codable, Sendable {
    public let checks: [WorkflowReviewCheck]
    public init(checks: [WorkflowReviewCheck]) { self.checks = checks }

    public func validate(against contract: WorkflowTaskReview) throws {
        guard checks.count == contract.criteria.count, Set(checks.map(\.id)) == Set(contract.criteria.map(\.id)),
              checks.allSatisfy({ !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.detail.utf8.count <= 4_000 }) else { throw WorkflowTaskGraphError.invalidReview }
    }
}

public struct WorkflowReviewToolEvidence: Hashable, Codable, Sendable {
    public let toolID: String
    public let invocationID: ToolInvocationID
    public let recordDigest: StableDigest
    public let execution: WorkflowSandboxEvidence?
    public let completedAt: AgentTimestamp?
    /// Older evidence records contain only successful invocations.
    public let succeeded: Bool?

    public init(toolID: String, invocationID: ToolInvocationID, recordDigest: StableDigest,
                execution: WorkflowSandboxEvidence? = nil, completedAt: AgentTimestamp? = nil, succeeded: Bool? = nil) {
        self.toolID = toolID; self.invocationID = invocationID; self.recordDigest = recordDigest
        self.execution = execution; self.completedAt = completedAt; self.succeeded = succeeded
    }
}

/// Host-attested facts from a sandbox tool result. No model-authored review can create these.
public struct WorkflowSandboxEvidence: Hashable, Codable, Sendable {
    public let workspaceID: SandboxWorkspaceHandleID
    public let sourceDigest: StableDigest?
    public let operation: String
    public let port: Int?
    public let processID: String?
    public let running: Bool?
    public let artifacts: [ArtifactReference]

    public init(workspaceID: SandboxWorkspaceHandleID, sourceDigest: StableDigest?, operation: String,
                port: Int? = nil, processID: String? = nil, running: Bool? = nil, artifacts: [ArtifactReference] = []) {
        self.workspaceID = workspaceID; self.sourceDigest = sourceDigest; self.operation = operation
        self.port = port; self.processID = processID; self.running = running; self.artifacts = artifacts
    }
}

public struct WorkflowTaskReviewResult: Hashable, Codable, Sendable {
    public let contract: WorkflowTaskReview
    public let report: WorkflowReviewReport
    public let inputArtifactIDs: [String]
    public let toolEvidence: [WorkflowReviewToolEvidence]
    public let goalAmendmentCount: Int
    public let missingTools: [String]

    public var status: WorkflowReviewStatus {
        if !missingTools.isEmpty || report.checks.contains(where: { $0.status == .blocked }) { return .blocked }
        return report.checks.contains(where: { $0.status == .revise }) ? .revise : .pass
    }
}

public struct WorkflowReviewCorrectionBudget: Hashable, Codable, Sendable {
    public let goalAmendmentCount: Int
    public let attempts: Int
}
