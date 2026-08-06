// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Typed subagent admission failures.
public enum SubagentSpawnError: Error, Hashable, Sendable {
    case parentUnavailable
    case parentTerminal
    case ceilingNotStrictlyAttenuated
    case budgetNotAttenuated(BudgetDimension)
    case resultUnavailable
    case invalidResult
}

/// Spawns and collects durable child runs (spec §22). Children inherit only a strict subset of the
/// parent ceiling, carry independent budgets, return structured results and artifacts, and can never
/// approve their own external access.
public protocol SubagentSpawning: Sendable {
    /// Submits one child run under a reserved parent identity and returns its execution handle.
    func spawn(_ request: SubagentSpawnRequest) async throws -> AgentExecutionHandleID
    /// Waits for the child's durable terminal result.
    func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult
}

/// Production spawner over a shared `AgentExecutor` and the run journal.
public struct DurableSubagentSpawner: SubagentSpawning, Sendable {
    private let executor: any AgentExecutor
    private let repository: any RuntimeRepository

    public init(
        executor: any AgentExecutor,
        repository: any RuntimeRepository
    ) {
        self.executor = executor
        self.repository = repository
    }

    public func spawn(_ request: SubagentSpawnRequest) async throws -> AgentExecutionHandleID {
        guard let parentFacts = try await repository.loadRunFacts(for: request.parentRunID) else {
            throw SubagentSpawnError.parentUnavailable
        }
        // Workflow roots are app-orchestrated anchors: their ceiling is frozen at submission and
        // children inherit a strict subset of it even after the placeholder root answers. Parent
        // agents must stay alive; only `.workflow` provenance may anchor on a terminal parent.
        guard !parentFacts.projection.isTerminal || request.source == .workflow else {
            throw SubagentSpawnError.parentTerminal
        }
        guard let parentPayload = parentFacts.submission?.request.payload else {
            throw SubagentSpawnError.parentUnavailable
        }
        // Strict ceiling attenuation against the LIVE parent ceiling, never the caller's word.
        do {
            _ = try parentPayload.capabilityCeiling.attenuating(
                to: request.capabilityCeiling.authority,
                requireStrict: true
            )
        } catch {
            throw SubagentSpawnError.ceilingNotStrictlyAttenuated
        }
        try Self.validateBudgetAttenuation(
            child: request.budget,
            parent: parentPayload.budget
        )
        let childRequest = try AgentRequest(
            id: SubagentStableID.request(
                parentRunID: request.parentRunID,
                requestingStepID: request.requestingStepID,
                childRunID: request.childRunID
            ),
            runID: request.childRunID,
            conversationID: parentPayload.conversationID,
            userTurnID: parentPayload.userTurnID,
            parent: ParentAgentContext(
                runID: request.parentRunID,
                requestingStepID: request.requestingStepID,
                capabilityCeiling: parentPayload.capabilityCeiling
            ),
            role: request.role,
            instruction: request.instruction,
            outputRequirement: request.outputRequirement,
            modelPolicy: request.modelPolicy,
            capabilityCeiling: request.capabilityCeiling,
            budget: request.budget,
            contextReferences: request.contextReferences,
            artifactReferences: request.artifactReferences,
            sandboxRequirement: request.sandboxRequirement,
            labels: request.labels,
            provenance: AgentRequestProvenance(
                source: request.source,
                sourceMessageID: parentPayload.provenance.sourceMessageID,
                parentRequestID: parentPayload.id,
                evidenceDigests: request.evidenceDigests
            ),
            approvalMode: request.approvalMode
        )
        return try await executor.submit(
            childRequest,
            commandID: SubagentStableID.command(
                parentRunID: request.parentRunID,
                childRunID: request.childRunID
            )
        )
    }

    public func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult {
        let handle = try await executor.attach(to: handleID)
        for try await envelope in handle.events(after: nil) {
            guard case .terminal = envelope.payload.event else { continue }
            guard let result = try await handle.result() else {
                throw SubagentSpawnError.resultUnavailable
            }
            return try Self.normalize(result)
        }
        throw SubagentSpawnError.resultUnavailable
    }

    private static func normalize(_ result: AgentResult) throws -> SubagentResult {
        let outcome: SubagentOutcome
        switch result.status.state {
        case .completed:
            guard let answer = result.answer else { throw SubagentSpawnError.invalidResult }
            outcome = .completed(answer: answer, usage: result.usage)
        case .failed:
            guard let failure = result.status.failure else {
                throw SubagentSpawnError.invalidResult
            }
            outcome = .failed(failure: failure, usage: result.usage)
        case .cancelled:
            outcome = .cancelled
        default:
            throw SubagentSpawnError.invalidResult
        }
        return SubagentResult(
            runID: result.runID,
            handleID: result.executionHandleID,
            outcome: outcome
        )
    }

    private static func validateBudgetAttenuation(
        child: AgentBudget,
        parent: AgentBudget
    ) throws {
        var strictlySmaller = false
        for dimension in BudgetDimension.allCases {
            let childValue = child.limits[dimension]
            let parentValue = parent.limits[dimension]
            guard childValue <= parentValue else {
                throw SubagentSpawnError.budgetNotAttenuated(dimension)
            }
            if childValue < parentValue { strictlySmaller = true }
        }
        guard strictlySmaller else {
            throw SubagentSpawnError.budgetNotAttenuated(.activeMilliseconds)
        }
    }
}

/// Deterministic child identities so relaunch can reconstruct the same run tree.
enum SubagentStableID {
    static func request(
        parentRunID: AgentRunID,
        requestingStepID: AgentStepID,
        childRunID: AgentRunID
    ) -> AgentRequestID {
        AgentRequestID(rawValue: uuid(
            domain: "subagent-request.v1",
            components: [
                parentRunID.description,
                requestingStepID.description,
                childRunID.description,
            ]
        ))
    }

    static func command(parentRunID: AgentRunID, childRunID: AgentRunID) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(
            domain: "subagent-command.v1",
            components: [parentRunID.description, childRunID.description]
        ))
    }

    static func childRun(workflowID: UUID, phase: UInt64, child: Int) -> AgentRunID {
        AgentRunID(rawValue: uuid(
            domain: "workflow-child.v1",
            components: [workflowID.uuidString, String(phase), String(child)]
        ))
    }

    static func rootRun(workflowID: UUID) -> AgentRunID {
        AgentRunID(rawValue: uuid(
            domain: "workflow-root.v1",
            components: [workflowID.uuidString]
        ))
    }

    static func rootCommand(workflowID: UUID) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(
            domain: "workflow-root-command.v1",
            components: [workflowID.uuidString]
        ))
    }

    private static func uuid(domain: String, components: [String]) -> UUID {
        let digest = StableDigest.fingerprint(
            domain: "mobilellm.\(domain)",
            components: components.map { Data($0.utf8) }
        )
        let bytes = stride(from: 0, to: 32, by: 2).map { index -> UInt8 in
            let start = digest.rawValue.index(digest.rawValue.startIndex, offsetBy: index)
            let end = digest.rawValue.index(start, offsetBy: 2)
            return UInt8(digest.rawValue[start ..< end], radix: 16)!
        }
        var value = bytes
        value[6] = (value[6] & 0x0f) | 0x50
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }
}

/// Public stable identities for workflow roots and children (spec §23): relaunch can reconstruct
/// the exact run tree from the workflow id alone.
public enum WorkflowIdentity {
    public static func rootRun(workflowID: UUID) -> AgentRunID {
        AgentRunID(rawValue: uuid(
            domain: "workflow-root.v1",
            components: [workflowID.uuidString]
        ))
    }

    public static func rootCommand(workflowID: UUID) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(
            domain: "workflow-root-command.v1",
            components: [workflowID.uuidString]
        ))
    }

    public static func rootStep(workflowID: UUID) -> AgentStepID {
        AgentStepID(rawValue: uuid(
            domain: "workflow-root-step.v1",
            components: [workflowID.uuidString]
        ))
    }

    public static func childRun(workflowID: UUID, phase: UInt64, child: Int) -> AgentRunID {
        AgentRunID(rawValue: uuid(
            domain: "workflow-child.v1",
            components: [workflowID.uuidString, String(phase), String(child)]
        ))
    }

    private static func uuid(domain: String, components: [String]) -> UUID {
        let digest = StableDigest.fingerprint(
            domain: "mobilellm.\(domain)",
            components: components.map { Data($0.utf8) }
        )
        let bytes = stride(from: 0, to: 32, by: 2).map { index -> UInt8 in
            let start = digest.rawValue.index(digest.rawValue.startIndex, offsetBy: index)
            let end = digest.rawValue.index(start, offsetBy: 2)
            return UInt8(digest.rawValue[start ..< end], radix: 16)!
        }
        var value = bytes
        value[6] = (value[6] & 0x0f) | 0x50
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }
}
