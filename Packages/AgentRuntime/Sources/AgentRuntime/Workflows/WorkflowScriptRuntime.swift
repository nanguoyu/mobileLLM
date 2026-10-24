// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// One shared option vocabulary for static analysis and the runtime bridge. Keeping this list in
/// one place prevents a candidate from passing inspection and failing only after execution starts.
enum WorkflowAgentOptionContract {
    static let allowedKeys: Set<String> = [
        "label", "phase", "schema", "model", "agentType", "isolation", "stallMs", "maxToolCalls", "task",
    ]
    static let supportedIsolationValues: Set<String> = ["worktree", "sandbox"]
}

public enum WorkflowAgentBridgeResult: Hashable, Sendable {
    case value(JSONValue)
    case unavailable(String)
    case stopped
}

/// Provider-assigned JavaScript call order. Engines use this sequence to preserve Claude-style
/// started-order replay even when Swift tasks begin executing out of order.
public struct WorkflowAgentInvocation: Hashable, Sendable {
    public let sequence: UInt32
    public let prompt: String
    public let options: WorkflowAgentOptionsV1

    public init(sequence: UInt32, prompt: String, options: WorkflowAgentOptionsV1) {
        self.sequence = sequence
        self.prompt = prompt
        self.options = options
    }
}

public struct WorkflowBudgetSnapshot: Hashable, Sendable {
    public let totalOutputTokens: UInt64?
    public let spentOutputTokens: UInt64

    public init(totalOutputTokens: UInt64?, spentOutputTokens: UInt64) {
        self.totalOutputTokens = totalOutputTokens
        self.spentOutputTokens = spentOutputTokens
    }

    public var remainingOutputTokens: UInt64? {
        totalOutputTokens.map { $0 > spentOutputTokens ? $0 - spentOutputTokens : 0 }
    }
}

/// The only trusted host operations visible to an orchestration script.
public struct WorkflowScriptHost: Sendable {
    public let agent: @Sendable (WorkflowAgentInvocation) async throws -> WorkflowAgentBridgeResult
    public let callSavedWorkflow: (@Sendable (String, CanonicalJSON?) async throws -> JSONValue)?
    public let phase: @Sendable (String) -> Void
    public let log: @Sendable (String) -> Void
    public let budget: @Sendable () -> WorkflowBudgetSnapshot
    /// Actual usage of settled calls already reached by this execution prefix, with frozen limits.
    /// Unlike the live output counter, this is safe to include in replayed coordinator prompts.
    public let settledBudget: @Sendable () async throws -> JSONValue
    /// Bounded, recorded web observations from this workflow's settled children. No new I/O to sites.
    public let webEvidence: @Sendable () async throws -> JSONValue
    public let queryWebEvidence: @Sendable (String) async throws -> JSONValue

    public init(
        agent: @escaping @Sendable (WorkflowAgentInvocation) async throws -> WorkflowAgentBridgeResult,
        callSavedWorkflow: (@Sendable (String, CanonicalJSON?) async throws -> JSONValue)? = nil,
        phase: @escaping @Sendable (String) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in },
        budget: @escaping @Sendable () -> WorkflowBudgetSnapshot = {
            WorkflowBudgetSnapshot(totalOutputTokens: nil, spentOutputTokens: 0)
        },
        settledBudget: @escaping @Sendable () async throws -> JSONValue = {
            throw WorkflowScriptRuntimeError.unsupportedRequirement
        },
        webEvidence: @escaping @Sendable () async throws -> JSONValue = {
            .object(["observations": .array([]), "sources": .array([]), "truncated": .bool(false)])
        },
        queryWebEvidence: (@Sendable (String) async throws -> JSONValue)? = nil
    ) {
        self.agent = agent
        self.callSavedWorkflow = callSavedWorkflow
        self.phase = phase
        self.log = log
        self.budget = budget
        self.settledBudget = settledBudget
        self.webEvidence = webEvidence
        self.queryWebEvidence = queryWebEvidence ?? { _ in try await webEvidence() }
    }
}

public enum WorkflowScriptRuntimeError: Error, Hashable, Sendable, CustomStringConvertible {
    case unsupportedRequirement
    case invalidScript(String)
    case invalidArguments(String)
    case invalidAgentOptions(String)
    case invalidResult(String)
    case collectionLimitExceeded
    case stepLimitExceeded
    case timedOut
    case cancelled
    case hostFailure(String)
    case internalInvariant(String)

    public var description: String {
        switch self {
        case .unsupportedRequirement: "The available workflow runtime does not satisfy this run."
        case .invalidScript(let detail): "Workflow script failed: \(detail)"
        case .invalidArguments(let detail): "Workflow arguments are invalid: \(detail)"
        case .invalidAgentOptions(let detail): "Workflow agent options are invalid: \(detail)"
        case .invalidResult(let detail): "Workflow result is invalid: \(detail)"
        case .collectionLimitExceeded: "Workflow parallel or pipeline input exceeded its hard limit."
        case .stepLimitExceeded: "Workflow script exceeded its deterministic step limit."
        case .timedOut: "Workflow script exceeded its wall-clock limit."
        case .cancelled: "Workflow script was cancelled."
        case .hostFailure(let detail): "Workflow host operation failed: \(detail)"
        case .internalInvariant(let detail): "Workflow runtime invariant failed: \(detail)"
        }
    }
}

public protocol WorkflowScriptRuntimeProvider: Sendable {
    var capabilities: WorkflowRuntimeCapabilitiesV1 { get }

    func execute(
        _ script: AnalyzedWorkflowScriptV1,
        args: CanonicalJSON?,
        limits: WorkflowRunLimitsV1,
        requirement: WorkflowRuntimeRequirementV1,
        host: WorkflowScriptHost
    ) async throws -> CanonicalJSON
}

/// Explicit deterministic provider for orchestration tests and replay/model checking.
public struct ClosureWorkflowScriptRuntime: WorkflowScriptRuntimeProvider, Sendable {
    public let capabilities: WorkflowRuntimeCapabilitiesV1
    private let implementation: @Sendable (
        AnalyzedWorkflowScriptV1, CanonicalJSON?, WorkflowRunLimitsV1, WorkflowScriptHost
    ) async throws -> CanonicalJSON

    public init(
        capabilities: WorkflowRuntimeCapabilitiesV1,
        implementation: @escaping @Sendable (
            AnalyzedWorkflowScriptV1, CanonicalJSON?, WorkflowRunLimitsV1, WorkflowScriptHost
        ) async throws -> CanonicalJSON
    ) {
        self.capabilities = capabilities
        self.implementation = implementation
    }

    public func execute(
        _ script: AnalyzedWorkflowScriptV1,
        args: CanonicalJSON?,
        limits: WorkflowRunLimitsV1,
        requirement: WorkflowRuntimeRequirementV1,
        host: WorkflowScriptHost
    ) async throws -> CanonicalJSON {
        guard capabilities.satisfies(requirement) else {
            throw WorkflowScriptRuntimeError.unsupportedRequirement
        }
        return try await implementation(script, args, limits, host)
    }
}
