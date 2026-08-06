// SPDX-License-Identifier: MIT

import Foundation

/// One of the complete durable run states defined by the agent protocol.
public enum AgentRunState: String, CaseIterable, Hashable, Codable, Sendable {
    /// Run exists but execution-defining input has not been prepared.
    case created
    /// Frozen inputs and context are being prepared.
    case preparing
    /// Run is waiting for a model resource lease.
    case waitingForModel
    /// A model attempt is generating.
    case generating
    /// A normalized action is being validated.
    case validatingAction
    /// A prepared external operation awaits approval.
    case waitingForApproval
    /// One or more validated tool invocations are executing serially.
    case executingTools
    /// A durable interaction request awaits user input.
    case waitingForUser
    /// A tool-free final synthesis attempt is running.
    case synthesizing
    /// The runtime is quiescing toward a durable pause.
    case pausing
    /// Execution is durably paused and owns no active resources.
    case paused
    /// Work requires foreground or unlocked data.
    case waitingForForeground
    /// An uncertain external outcome requires reconciliation.
    case waitingForReconciliation
    /// The run completed successfully.
    case completed
    /// The run ended with a non-cancellation failure.
    case failed
    /// The run was explicitly cancelled.
    case cancelled

    /// Whether this state is terminal.
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

/// Machine-enumerable legal durable state transitions for the first agent protocol.
public enum AgentRunTransitionMatrix {
    /// Returns whether a committed status may move directly between two states.
    public static func allows(from: AgentRunState, to: AgentRunState) -> Bool {
        if from == to { return true }
        let allowed: Set<AgentRunState> = switch from {
        case .created: [.preparing, .failed, .cancelled]
        case .preparing:
            [.waitingForModel, .executingTools, .synthesizing, .waitingForForeground,
             .waitingForReconciliation, .pausing, .failed]
        case .waitingForModel:
            [.generating, .waitingForApproval, .waitingForForeground,
             .waitingForReconciliation, .pausing, .failed]
        case .generating:
            [.waitingForModel, .validatingAction, .waitingForForeground,
             .waitingForReconciliation, .pausing, .failed]
        case .validatingAction:
            [.waitingForModel, .waitingForApproval, .executingTools, .waitingForUser,
             .waitingForReconciliation, .pausing, .completed, .failed]
        case .waitingForApproval:
            [.executingTools, .synthesizing, .waitingForModel, .waitingForForeground,
             .cancelled, .failed]
        case .executingTools:
            [.waitingForModel, .waitingForApproval, .waitingForReconciliation,
             .synthesizing, .pausing, .failed]
        case .waitingForUser: [.waitingForModel, .cancelled, .failed]
        case .synthesizing:
            [.generating, .waitingForApproval, .waitingForForeground,
             .waitingForReconciliation, .pausing, .failed]
        case .pausing:
            [.paused, .waitingForForeground, .waitingForReconciliation, .cancelled, .failed]
        case .paused: [.preparing, .cancelled, .failed]
        case .waitingForForeground: [.preparing, .cancelled, .failed]
        case .waitingForReconciliation: [.synthesizing, .failed]
        case .completed, .failed, .cancelled: []
        }
        return allowed.contains(to)
    }
}

/// Exactly one reason recorded when a run becomes terminal.
public enum AgentTerminalReason: String, CaseIterable, Hashable, Codable, Sendable {
    /// A committed final answer satisfied the output contract.
    case completed
    /// A final answer was committed, but at least one intermediate tool outcome failed or is
    /// uncertain. The run is not a clean success: the UI must never paint it as a plain "Completed".
    case completedWithFailures
    /// The user explicitly cancelled the run.
    case cancelledByUser
    /// A hard resource budget was exhausted.
    case budgetExceeded
    /// Repeated actions failed to make progress.
    case noProgress
    /// Required authority was denied or revoked.
    case permissionDenied
    /// A pinned tool was unavailable.
    case toolUnavailable
    /// A pinned model was unavailable.
    case modelUnavailable
    /// Required context could not fit without violating policy.
    case contextUnsatisfiable
    /// The user abandoned an external result that could not be proven.
    case externalResultUncertain
    /// An internal invariant or implementation failed.
    case internalFailure
}

/// Durable run status returned by an execution handle.
public struct AgentRunStatus: Hashable, Codable, Sendable {
    /// Current run state.
    public let state: AgentRunState
    /// Monotonically increasing compare-and-swap state version.
    public let stateVersion: UInt64
    /// Unique terminal reason, present exactly when the state is terminal.
    public let terminalReason: AgentTerminalReason?
    /// Typed terminal or blocking failure, when applicable.
    public let failure: AgentFailure?
    /// Typed reason and identity blocking progress, when applicable.
    public let blockingReason: AgentBlockingReason?

    /// Creates a status and enforces terminal/nonterminal consistency.
    public init(
        state: AgentRunState,
        stateVersion: UInt64,
        terminalReason: AgentTerminalReason? = nil,
        failure: AgentFailure? = nil,
        blockingReason: AgentBlockingReason? = nil
    ) throws {
        guard stateVersion > 0 else {
            throw AgentContractError.invalidRunStatus("state version must be positive")
        }
        if state.isTerminal {
            guard let terminalReason else {
                throw AgentContractError.invalidRunStatus("terminal state requires one reason")
            }
            switch state {
            case .completed:
                // A completed run may still carry `.completedWithFailures` when an intermediate tool
                // outcome failed or is uncertain; the answer is real, but the run is not a clean win.
                guard terminalReason == .completed || terminalReason == .completedWithFailures,
                      failure == nil
                else {
                    throw AgentContractError.invalidRunStatus("completed state has incompatible outcome")
                }
            case .cancelled:
                guard terminalReason == .cancelledByUser,
                      failure.map({ $0.classification == .cancelled }) ?? true
                else {
                    throw AgentContractError.invalidRunStatus("cancelled state has incompatible outcome")
                }
            case .failed:
                guard terminalReason != .completed, terminalReason != .cancelledByUser,
                      let failure,
                      Self.matches(terminalReason: terminalReason, failure: failure)
                else {
                    throw AgentContractError.invalidRunStatus("failed state has incompatible outcome")
                }
            default:
                break
            }
            guard blockingReason == nil else {
                throw AgentContractError.invalidRunStatus("terminal state cannot remain blocked")
            }
        } else {
            guard terminalReason == nil else {
                throw AgentContractError.invalidRunStatus("nonterminal state cannot have terminal reason")
            }
            let expectedBlockingKind: AgentBlockingReason.Kind? = switch state {
            case .waitingForModel: .modelResource
            case .waitingForApproval: .approval
            case .waitingForUser: .userInput
            case .paused: .paused
            case .waitingForForeground: .foreground
            case .waitingForReconciliation: .reconciliation
            default: nil
            }
            guard expectedBlockingKind == blockingReason?.kind else {
                throw AgentContractError.invalidRunStatus("blocking reason does not match waiting state")
            }
            switch state {
            case .waitingForReconciliation:
                guard failure?.classification == .potentiallySideEffecting,
                      failure?.externalEffect == .uncertain
                else {
                    throw AgentContractError.invalidRunStatus(
                        "reconciliation wait requires an uncertain side-effect failure"
                    )
                }
            case .waitingForModel:
                guard failure.map({ $0.classification == .transient || $0.classification == .budgetRelated })
                        ?? true
                else { throw AgentContractError.invalidRunStatus("invalid model wait failure") }
            case .waitingForForeground:
                guard failure.map({
                    $0.classification == .permissionRelated || $0.classification == .transient
                }) ?? true
                else { throw AgentContractError.invalidRunStatus("invalid foreground wait failure") }
            default:
                guard failure == nil else {
                    throw AgentContractError.invalidRunStatus("active state carries stale failure")
                }
            }
        }
        self.state = state
        self.stateVersion = stateVersion
        self.terminalReason = terminalReason
        self.failure = failure
        self.blockingReason = blockingReason
    }

    /// Decodes and revalidates status invariants.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                state: container.decode(AgentRunState.self, forKey: .state),
                stateVersion: container.decode(UInt64.self, forKey: .stateVersion),
                terminalReason: container.decodeIfPresent(AgentTerminalReason.self, forKey: .terminalReason),
                failure: container.decodeIfPresent(AgentFailure.self, forKey: .failure),
                blockingReason: container.decodeIfPresent(AgentBlockingReason.self, forKey: .blockingReason)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case state, stateVersion, terminalReason, failure, blockingReason
    }

    private static func matches(
        terminalReason: AgentTerminalReason,
        failure: AgentFailure
    ) -> Bool {
        switch terminalReason {
        case .budgetExceeded:
            failure.classification == .budgetRelated
        case .noProgress:
            failure.classification == .permanent
        case .permissionDenied:
            failure.classification == .permissionRelated
        case .toolUnavailable, .modelUnavailable, .contextUnsatisfiable:
            failure.classification == .incompatible
        case .externalResultUncertain:
            failure.classification == .potentiallySideEffecting
                && failure.externalEffect == .uncertain
        case .internalFailure:
            failure.classification == .transient || failure.classification == .permanent
        case .completed, .completedWithFailures, .cancelledByUser:
            false
        }
    }
}

/// Typed durable reason that a nonterminal run cannot currently progress.
public enum AgentBlockingReason: Hashable, Codable, Sendable {
    /// Waiting to acquire the pinned model resource.
    case modelResource
    /// Waiting for approval of one prepared request.
    case approval(approvalID: ApprovalID)
    /// Waiting for one interaction response.
    case userInput(requestID: InteractionRequestID)
    /// Durably paused through explicit command or lifecycle quiescence.
    case paused
    /// Waiting for explicit foreground resume or unlock.
    case foreground
    /// Waiting to reconcile one uncertain invocation.
    case reconciliation(invocationID: ToolInvocationID)

    /// Stable discriminator used by run-status validation.
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        /// Model resource wait.
        case modelResource
        /// Approval wait.
        case approval
        /// User-input wait.
        case userInput
        /// Durable pause.
        case paused
        /// Foreground or unlock wait.
        case foreground
        /// Reconciliation wait.
        case reconciliation
    }

    /// The discriminator of this blocking reason.
    public var kind: Kind {
        switch self {
        case .modelResource: .modelResource
        case .approval: .approval
        case .userInput: .userInput
        case .paused: .paused
        case .foreground: .foreground
        case .reconciliation: .reconciliation
        }
    }
}

/// Output requested from an agent or model attempt.
public enum AgentOutputRequirement: Hashable, Codable, Sendable {
    /// A user-visible text answer.
    case text
    /// Structured JSON matching the supplied bounded schema.
    case structured(JSONSchemaDocument)
    /// One or more durable artifacts with the named semantic type.
    case artifacts(semanticType: String)
    /// Text plus zero or more supporting artifacts.
    case textAndArtifacts

    /// Validates semantic labels and requires structured schemas to be completely enforceable.
    public func validate() throws {
        switch self {
        case .structured(let schema):
            guard schema.enforcement == .fullyEnforced else {
                throw AgentContractError.invalidJSONSchema(
                    "structured output schema has unenforced keywords"
                )
            }
        case .artifacts(let semanticType):
            guard AgentWireValidation.isNonblankControlFree(semanticType, maximumLength: 128) else {
                throw AgentContractError.invalidName("artifact output semantic type")
            }
        case .text, .textAndArtifacts:
            break
        }
    }
}

/// One deterministic source reference supplied to an agent request.
public struct AgentContextReference: Hashable, Codable, Sendable {
    /// Context-source family.
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        /// Durable conversation message.
        case message
        /// Canonical user Memory record.
        case memory
        /// Versioned Skill instructions.
        case skill
        /// Compact durable run state.
        case runState
        /// Bounded excerpt of an artifact.
        case artifactExcerpt
    }

    /// Source family.
    public let kind: Kind
    /// Stable source identity interpreted by the runtime.
    public let sourceID: String
    /// Exact revision or content digest frozen for deterministic recovery.
    public let revisionDigest: StableDigest

    /// Creates one validated context source reference.
    public init(kind: Kind, sourceID: String, revisionDigest: StableDigest) throws {
        guard AgentWireValidation.isNonblankControlFree(sourceID, maximumLength: 512) else {
            throw AgentContractError.invalidName("context source identity")
        }
        self.kind = kind
        self.sourceID = sourceID
        self.revisionDigest = revisionDigest
    }

    /// Decodes and revalidates a context source reference.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(Kind.self, forKey: .kind),
                sourceID: container.decode(String.self, forKey: .sourceID),
                revisionDigest: container.decode(StableDigest.self, forKey: .revisionDigest)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, sourceID, revisionDigest }
}

/// Deterministic metadata describing who submitted an agent request and why.
public struct AgentRequestProvenance: Hashable, Codable, Sendable {
    /// Submission source.
    public enum Source: String, CaseIterable, Hashable, Codable, Sendable {
        /// Direct user turn.
        case user
        /// Explicit user resume command.
        case resume
        /// Reserved future parent agent.
        case parentAgent
        /// Reserved future workflow orchestrator.
        case workflow
    }

    /// Submission source.
    public let source: Source
    /// Accepted user message that originated the request, when applicable.
    public let sourceMessageID: MessageID?
    /// Optional parent request identity.
    public let parentRequestID: AgentRequestID?
    /// Stable evidence references required by a future verifier.
    public let evidenceDigests: [StableDigest]

    /// Creates normalized provenance.
    public init(
        source: Source,
        sourceMessageID: MessageID? = nil,
        parentRequestID: AgentRequestID? = nil,
        evidenceDigests: some Sequence<StableDigest> = []
    ) {
        self.source = source
        self.sourceMessageID = sourceMessageID
        self.parentRequestID = parentRequestID
        self.evidenceDigests = Array(Set(evidenceDigests)).sorted { $0.rawValue < $1.rawValue }
    }

    /// Decodes and rejects duplicate or noncanonically ordered evidence digests.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let evidence = try container.decode([StableDigest].self, forKey: .evidenceDigests)
        self.init(
            source: try container.decode(Source.self, forKey: .source),
            sourceMessageID: try container.decodeIfPresent(MessageID.self, forKey: .sourceMessageID),
            parentRequestID: try container.decodeIfPresent(AgentRequestID.self, forKey: .parentRequestID),
            evidenceDigests: evidence
        )
        guard evidenceDigests == evidence else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Noncanonical evidence digests")
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case source, sourceMessageID, parentRequestID, evidenceDigests
    }
}

/// One stable request label without relying on dictionary serialization order.
public struct AgentRequestLabel: Hashable, Codable, Sendable, Comparable {
    /// Label key.
    public let key: String
    /// Label value.
    public let value: String

    /// Creates a bounded control-free label.
    public init(key: String, value: String) throws {
        guard AgentWireValidation.isLowercaseNamespace(key, maximumLength: 128),
              AgentWireValidation.isNonblankControlFree(value, maximumLength: 512)
        else { throw AgentContractError.invalidName("agent request label") }
        self.key = key
        self.value = value
    }

    /// Orders labels by key and then value.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key ? lhs.value < rhs.value : lhs.key < rhs.key
    }

    /// Decodes and revalidates a deterministic request label.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                key: container.decode(String.self, forKey: .key),
                value: container.decode(String.self, forKey: .value)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case key, value }
}

/// Frozen parent authority supplied only for a reserved future child request.
public struct ParentAgentContext: Hashable, Codable, Sendable {
    /// Parent run identity.
    public let runID: AgentRunID
    /// Parent step requesting the child.
    public let requestingStepID: AgentStepID
    /// Parent's immutable capability ceiling used to prove strict attenuation.
    public let capabilityCeiling: RunCapabilityCeiling

    /// Creates parent execution context.
    public init(
        runID: AgentRunID,
        requestingStepID: AgentStepID,
        capabilityCeiling: RunCapabilityCeiling
    ) {
        self.runID = runID
        self.requestingStepID = requestingStepID
        self.capabilityCeiling = capabilityCeiling
    }
}

/// Complete provider-neutral request accepted by the future `AgentExecutor` protocol.
public struct AgentRequest: Hashable, Codable, Sendable, AgentContractPayload {
    /// Stable wire schema identity.
    public static let schemaID = "com.mobilellm.agent.request"

    /// Stable request identity.
    public let id: AgentRequestID
    /// Stable run identity selected before submission.
    public let runID: AgentRunID
    /// Conversation that owns visible projection and reusable bounded-read approvals.
    public let conversationID: ConversationID
    /// User turn that initiated this request.
    public let userTurnID: UserTurnID
    /// Reserved parent context; nil for the first-release root agent.
    public let parent: ParentAgentContext?
    /// Bounded role label.
    public let role: String
    /// Trusted user/runtime instruction for this agent.
    public let instruction: String
    /// Required structured output form.
    public let outputRequirement: AgentOutputRequirement
    /// Provider-neutral model policy.
    public let modelPolicy: AgentModelPolicy
    /// Immutable maximum authority for this run.
    public let capabilityCeiling: RunCapabilityCeiling
    /// Independent immutable resource budget.
    public let budget: AgentBudget
    /// Frozen context references.
    public let contextReferences: [AgentContextReference]
    /// Durable artifact inputs.
    public let artifactReferences: [ArtifactReference]
    /// Optional requirement for a future injected sandbox provider.
    public let sandboxRequirement: SandboxRequirement?
    /// Deterministically ordered metadata labels.
    public let labels: [AgentRequestLabel]
    /// Submission provenance and verification evidence.
    public let provenance: AgentRequestProvenance
    /// Per-conversation approval mode frozen with this run (decides asking, never authority).
    public let approvalMode: AgentApprovalMode
    /// Bounded fan-out cap for one tool batch. 1 (default) keeps the proven serial barrier; values
    /// 2...4 opt this run into bounded concurrent tool execution (spec §12 roadmap step 2).
    public let parallelToolBatchLimit: UInt16

    /// Creates a root or strictly attenuated future-child request.
    public init(
        id: AgentRequestID,
        runID: AgentRunID,
        conversationID: ConversationID,
        userTurnID: UserTurnID,
        parent: ParentAgentContext? = nil,
        role: String,
        instruction: String,
        outputRequirement: AgentOutputRequirement,
        modelPolicy: AgentModelPolicy,
        capabilityCeiling: RunCapabilityCeiling,
        budget: AgentBudget,
        contextReferences: [AgentContextReference] = [],
        artifactReferences: [ArtifactReference] = [],
        sandboxRequirement: SandboxRequirement? = nil,
        labels: some Sequence<AgentRequestLabel> = [],
        provenance: AgentRequestProvenance,
        approvalMode: AgentApprovalMode = .ask,
        parallelToolBatchLimit: UInt16 = 1
    ) throws {
        let normalizedLabels = Array(Set(labels)).sorted()
        try outputRequirement.validate()
        guard (1 ... 4).contains(parallelToolBatchLimit) else {
            throw AgentContractError.invalidName("parallel tool batch limit")
        }
        guard AgentWireValidation.isNonblankControlFree(role, maximumLength: 128),
              Self.isValidInstruction(instruction),
              Set(normalizedLabels.map(\.key)).count == normalizedLabels.count,
              Set(contextReferences).count == contextReferences.count,
              Set(artifactReferences.map(\.id)).count == artifactReferences.count
        else { throw AgentContractError.invalidName("agent request") }
        if let parent {
            _ = try parent.capabilityCeiling.attenuating(to: capabilityCeiling.authority, requireStrict: true)
            guard provenance.source == .parentAgent || provenance.source == .workflow else {
                throw AgentContractError.invalidName("child request provenance")
            }
        } else if provenance.source == .parentAgent {
            throw AgentContractError.invalidName("parent provenance without parent context")
        }
        if let sandboxRequirement,
           !sandboxRequirement.authority.isSubset(of: capabilityCeiling.authority)
        {
            throw AgentContractError.capabilityEscalation(
                sandboxRequirement.authority.capabilities.values.filter {
                    !capabilityCeiling.capabilities.contains($0)
                }
            )
        }
        if let sandboxRequirement {
            _ = try budget.attenuating(to: sandboxRequirement.budget)
        }
        self.id = id
        self.runID = runID
        self.conversationID = conversationID
        self.userTurnID = userTurnID
        self.parent = parent
        self.role = role
        self.instruction = instruction
        self.outputRequirement = outputRequirement
        self.modelPolicy = modelPolicy
        self.capabilityCeiling = capabilityCeiling
        self.budget = budget
        self.contextReferences = contextReferences
        self.artifactReferences = artifactReferences
        self.sandboxRequirement = sandboxRequirement
        self.labels = normalizedLabels
        self.provenance = provenance
        self.approvalMode = approvalMode
        self.parallelToolBatchLimit = parallelToolBatchLimit
    }

    /// User instructions are ordinary chat text: line breaks and tabs are legitimate content, while
    /// other control characters and empty/oversized payloads remain rejected.
    private static func isValidInstruction(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 * 1_024,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        let forbidden = CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)
        return !value.unicodeScalars.contains { forbidden.contains($0) }
    }

    /// Decodes and revalidates root/child attenuation, labels, artifacts, and sandbox budget.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let labels = try container.decode([AgentRequestLabel].self, forKey: .labels)
        let contexts = try container.decode([AgentContextReference].self, forKey: .contextReferences)
        let artifacts = try container.decode([ArtifactReference].self, forKey: .artifactReferences)
        do {
            try self.init(
                id: container.decode(AgentRequestID.self, forKey: .id),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                conversationID: container.decode(ConversationID.self, forKey: .conversationID),
                userTurnID: container.decode(UserTurnID.self, forKey: .userTurnID),
                parent: container.decodeIfPresent(ParentAgentContext.self, forKey: .parent),
                role: container.decode(String.self, forKey: .role),
                instruction: container.decode(String.self, forKey: .instruction),
                outputRequirement: container.decode(AgentOutputRequirement.self, forKey: .outputRequirement),
                modelPolicy: container.decode(AgentModelPolicy.self, forKey: .modelPolicy),
                capabilityCeiling: container.decode(RunCapabilityCeiling.self, forKey: .capabilityCeiling),
                budget: container.decode(AgentBudget.self, forKey: .budget),
                contextReferences: contexts,
                artifactReferences: artifacts,
                sandboxRequirement: container.decodeIfPresent(SandboxRequirement.self, forKey: .sandboxRequirement),
                labels: labels,
                provenance: container.decode(AgentRequestProvenance.self, forKey: .provenance),
                approvalMode: container.decodeIfPresent(AgentApprovalMode.self, forKey: .approvalMode)
                    ?? .ask,
                parallelToolBatchLimit: container.decodeIfPresent(
                    UInt16.self,
                    forKey: .parallelToolBatchLimit
                ) ?? 1
            )
            guard self.labels == labels else { throw AgentContractError.invalidName("noncanonical labels") }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, runID, conversationID, userTurnID, parent, role, instruction, outputRequirement
        case modelPolicy, capabilityCeiling, budget, contextReferences, artifactReferences
        case sandboxRequirement, labels, provenance
        case approvalMode, parallelToolBatchLimit
    }
}

/// Durable request for additional user input inside the same run.
public struct UserInputRequest: Hashable, Codable, Sendable {
    /// Stable interaction request identity.
    public let id: InteractionRequestID
    /// Owning run.
    public let runID: AgentRunID
    /// Prompt shown to the user.
    public let prompt: String
    /// Optional schema for the user's structured response.
    public let responseSchema: JSONSchemaDocument?
    /// Expected run-state version against which a response must compare-and-swap.
    public let creationStateVersion: UInt64

    /// Creates a durable user-input request.
    public init(
        id: InteractionRequestID,
        runID: AgentRunID,
        prompt: String,
        responseSchema: JSONSchemaDocument? = nil,
        creationStateVersion: UInt64
    ) throws {
        guard AgentWireValidation.isNonblankControlFree(prompt, maximumLength: 8 * 1_024),
              creationStateVersion > 0
        else {
            throw AgentContractError.invalidName("user input prompt")
        }
        self.id = id
        self.runID = runID
        self.prompt = prompt
        self.responseSchema = responseSchema
        self.creationStateVersion = creationStateVersion
    }

    /// Decodes and revalidates a bounded interaction prompt.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(InteractionRequestID.self, forKey: .id),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                prompt: container.decode(String.self, forKey: .prompt),
                responseSchema: container.decodeIfPresent(JSONSchemaDocument.self, forKey: .responseSchema),
                creationStateVersion: container.decode(UInt64.self, forKey: .creationStateVersion)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case id, runID, prompt, responseSchema, creationStateVersion }
}

/// User response bound to one durable interaction request and expected run version.
public struct UserInputResponse: Hashable, Codable, Sendable {
    /// Interaction request being answered.
    public let requestID: InteractionRequestID
    /// Expected run state version copied from the current projection.
    public let expectedRunStateVersion: UInt64
    /// Provider-neutral text or structured response.
    public let value: JSONValue

    /// Creates a response that can be applied idempotently by runtime CAS.
    public init(
        requestID: InteractionRequestID,
        expectedRunStateVersion: UInt64,
        value: JSONValue
    ) throws {
        guard expectedRunStateVersion > 0 else {
            throw AgentContractError.invalidCommand("interaction response state version must be positive")
        }
        _ = try CanonicalJSON(value)
        self.requestID = requestID
        self.expectedRunStateVersion = expectedRunStateVersion
        self.value = value
    }

    /// Decodes and revalidates the compare-and-swap state version.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                requestID: container.decode(InteractionRequestID.self, forKey: .requestID),
                expectedRunStateVersion: container.decode(UInt64.self, forKey: .expectedRunStateVersion),
                value: container.decode(JSONValue.self, forKey: .value)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case requestID, expectedRunStateVersion, value }
}

/// A committed agent answer with optional structured data and artifacts.
public struct AgentAnswer: Hashable, Codable, Sendable {
    /// User-visible final text.
    public let text: String?
    /// Structured final output.
    public let structuredOutput: JSONValue?
    /// Durable output artifacts.
    public let artifacts: [ArtifactReference]

    /// Creates a nonempty final answer value.
    public init(
        text: String? = nil,
        structuredOutput: JSONValue? = nil,
        artifacts: [ArtifactReference] = []
    ) throws {
        if let structuredOutput {
            _ = try CanonicalJSON(structuredOutput)
        }
        guard text.map({ !$0.isEmpty && $0.utf8.count <= 8 * 1_024 * 1_024 }) ?? true,
              text != nil || structuredOutput != nil || !artifacts.isEmpty,
              Set(artifacts.map(\.id)).count == artifacts.count
        else { throw AgentContractError.invalidName("agent answer") }
        self.text = text
        self.structuredOutput = structuredOutput
        self.artifacts = artifacts
    }

    /// Decodes and revalidates a nonempty final answer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                text: container.decodeIfPresent(String.self, forKey: .text),
                structuredOutput: container.decodeIfPresent(JSONValue.self, forKey: .structuredOutput),
                artifacts: container.decode([ArtifactReference].self, forKey: .artifacts)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case text, structuredOutput, artifacts }
}

/// The single normalized action resolved from one complete model pass.
public enum AgentAction: Hashable, Codable, Sendable {
    /// Execute one or more validated calls serially in model-provided order.
    case callTools([ProposedToolCall])
    /// Ask the user for additional input without creating a new run.
    case requestUserInput(UserInputRequest)
    /// Commit a final answer.
    case finalAnswer(AgentAnswer)

    /// Validates nonempty tool batches and unique invocation identities.
    public func validate() throws {
        if case .callTools(let calls) = self {
            guard !calls.isEmpty, Set(calls.map(\.invocationID)).count == calls.count else {
                throw AgentContractError.invalidCommand("invalid tool-call action")
            }
        }
    }
}

/// Reconciliation result supplied for an uncertain external invocation.
public enum AgentReconciliationDecision: String, CaseIterable, Hashable, Codable, Sendable {
    /// External effect is confirmed to have succeeded.
    case succeeded
    /// External effect is confirmed not to have succeeded.
    case failed
    /// User abandons unresolved work, producing an uncertain terminal reason.
    case abandoned
}

/// Why a run must cooperatively quiesce at its next stable boundary.
public enum AgentQuiescenceReason: String, CaseIterable, Hashable, Codable, Sendable {
    /// The user explicitly requested a durable pause.
    case userRequested
    /// The application lost the foreground required by the active work.
    case foregroundLost
    /// Finite iOS background execution time expired.
    case backgroundExpired
    /// Memory, thermal, or another bounded runtime resource requires release.
    case resourcePressure
}

/// Explicit state-changing command action sent through an execution handle.
public enum AgentCommandAction: Hashable, Codable, Sendable {
    /// Quiesce durably at a stable boundary.
    case pause(reason: AgentQuiescenceReason)
    /// Resume an eligible paused or waiting run through explicit user intent.
    case resume
    /// Cancel the run through explicit user intent.
    case cancel
    /// Decide an approval request and, only when approved, choose its grant scope.
    case decideApproval(
        approvalID: ApprovalID,
        decision: ApprovalDecision,
        approvedScope: ApprovalScope?
    )
    /// Reconcile one uncertain external invocation.
    case reconcile(invocationID: ToolInvocationID, decision: AgentReconciliationDecision)
    /// Respond to one durable user-input request.
    case respond(UserInputResponse)

    /// Rejects approval decisions whose authority scope does not match their disposition.
    public func validate() throws {
        guard case .decideApproval(_, let decision, let approvedScope) = self else { return }
        switch decision {
        case .approved:
            guard approvedScope != nil else {
                throw AgentContractError.invalidCommand("approved decision requires a grant scope")
            }
        case .denied, .cancelled:
            guard approvedScope == nil else {
                throw AgentContractError.invalidCommand("non-approval decision cannot grant scope")
            }
        }
    }
}

/// Versioned command payload accepted by a future `AgentExecutionHandle`.
public struct AgentCommand: Hashable, Codable, Sendable, AgentContractPayload {
    /// Stable wire schema identity.
    public static let schemaID = "com.mobilellm.agent.command"

    /// Idempotency identity for this command.
    public let commandID: AgentCommandID
    /// Target run.
    public let runID: AgentRunID
    /// Expected state version for compare-and-swap.
    public let expectedRunStateVersion: UInt64
    /// Explicit command action.
    public let action: AgentCommandAction
    /// Deterministic issue time for expiry and audit policy.
    public let issuedAt: AgentTimestamp

    /// Creates one explicitly targeted command.
    public init(
        commandID: AgentCommandID,
        runID: AgentRunID,
        expectedRunStateVersion: UInt64,
        action: AgentCommandAction,
        issuedAt: AgentTimestamp
    ) throws {
        guard expectedRunStateVersion > 0 else {
            throw AgentContractError.invalidCommand("expected state version must be positive")
        }
        try action.validate()
        if case .respond(let response) = action,
           response.expectedRunStateVersion != expectedRunStateVersion
        {
            throw AgentContractError.invalidCommand("response version differs from command version")
        }
        self.commandID = commandID
        self.runID = runID
        self.expectedRunStateVersion = expectedRunStateVersion
        self.action = action
        self.issuedAt = issuedAt
    }

    /// Decodes and revalidates command target and expected-version consistency.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                commandID: container.decode(AgentCommandID.self, forKey: .commandID),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                expectedRunStateVersion: container.decode(UInt64.self, forKey: .expectedRunStateVersion),
                action: container.decode(AgentCommandAction.self, forKey: .action),
                issuedAt: container.decode(AgentTimestamp.self, forKey: .issuedAt)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case commandID, runID, expectedRunStateVersion, action, issuedAt
    }
}

/// Disposition returned for an idempotent state-changing command.
public enum AgentCommandDisposition: String, CaseIterable, Hashable, Codable, Sendable {
    /// Command atomically advanced the run.
    case accepted
    /// Expected state version was stale and no mutation occurred.
    case stale
    /// Command was invalid for current state or policy and no mutation occurred.
    case rejected
}

/// Versioned receipt returned for one state-changing command.
public struct AgentCommandReceipt: Hashable, Codable, Sendable, AgentContractPayload {
    /// Stable wire schema identity.
    public static let schemaID = "com.mobilellm.agent.command-receipt"

    /// Command identity to which this receipt belongs.
    public let commandID: AgentCommandID
    /// Target run.
    public let runID: AgentRunID
    /// Command disposition.
    public let disposition: AgentCommandDisposition
    /// Complete current run status after processing or rejecting the command.
    ///
    /// Keeping state, version, terminal reason, blocking reason, and run failure in one validated
    /// value prevents a stale command receipt from publishing an internally inconsistent projection.
    public let currentStatus: AgentRunStatus
    /// Typed command-processing failure for stale or rejected commands.
    public let failure: AgentFailure?

    /// Current compare-and-swap version, projected from `currentStatus`.
    public var currentRunStateVersion: UInt64 { currentStatus.stateVersion }

    /// Current durable run state, projected from `currentStatus`.
    public var currentRunState: AgentRunState { currentStatus.state }

    /// Creates an internally consistent command receipt.
    public init(
        commandID: AgentCommandID,
        runID: AgentRunID,
        disposition: AgentCommandDisposition,
        currentStatus: AgentRunStatus,
        failure: AgentFailure? = nil
    ) throws {
        switch disposition {
        case .accepted:
            guard failure == nil else { throw AgentContractError.invalidCommand("success receipt has failure") }
        case .stale, .rejected:
            guard failure != nil else { throw AgentContractError.invalidCommand("rejection receipt lacks failure") }
        }
        self.commandID = commandID
        self.runID = runID
        self.disposition = disposition
        self.currentStatus = currentStatus
        self.failure = failure
    }

    /// Decodes and revalidates receipt disposition/failure consistency.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                commandID: container.decode(AgentCommandID.self, forKey: .commandID),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                disposition: container.decode(AgentCommandDisposition.self, forKey: .disposition),
                currentStatus: container.decode(AgentRunStatus.self, forKey: .currentStatus),
                failure: container.decodeIfPresent(AgentFailure.self, forKey: .failure)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case commandID, runID, disposition, currentStatus, failure
    }
}

/// One machine-readable verification or evidence reference returned by an agent.
public struct AgentEvidence: Hashable, Codable, Sendable, Comparable {
    /// Stable evidence kind.
    public let kind: String
    /// Digest of evidence content held elsewhere.
    public let digest: StableDigest
    /// Optional artifact carrying the evidence.
    public let artifactID: ArtifactID?

    /// Creates a bounded evidence reference.
    public init(kind: String, digest: StableDigest, artifactID: ArtifactID? = nil) throws {
        guard AgentWireValidation.isLowercaseNamespace(kind, maximumLength: 128) else {
            throw AgentContractError.invalidName("evidence kind")
        }
        self.kind = kind
        self.digest = digest
        self.artifactID = artifactID
    }

    /// Orders evidence by kind, digest, and artifact identity.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.digest != rhs.digest { return lhs.digest.rawValue < rhs.digest.rawValue }
        return (lhs.artifactID?.description ?? "") < (rhs.artifactID?.description ?? "")
    }

    /// Decodes and revalidates one evidence reference.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(String.self, forKey: .kind),
                digest: container.decode(StableDigest.self, forKey: .digest),
                artifactID: container.decodeIfPresent(ArtifactID.self, forKey: .artifactID)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, digest, artifactID }
}

/// Complete optional terminal result returned by an execution handle.
public struct AgentResult: Hashable, Codable, Sendable, AgentContractPayload {
    /// Stable wire schema identity.
    public static let schemaID = "com.mobilellm.agent.result"

    /// Request that produced the result.
    public let requestID: AgentRequestID
    /// Execution handle returning this result.
    public let executionHandleID: AgentExecutionHandleID
    /// Owning run.
    public let runID: AgentRunID
    /// Terminal status.
    public let status: AgentRunStatus
    /// Committed answer, required for successful completion.
    public let answer: AgentAnswer?
    /// Final cumulative usage.
    public let usage: AgentUsage
    /// Structured verification evidence.
    public let evidence: [AgentEvidence]

    /// Creates a terminal result consistent with the terminal reason.
    public init(
        requestID: AgentRequestID,
        executionHandleID: AgentExecutionHandleID,
        runID: AgentRunID,
        status: AgentRunStatus,
        answer: AgentAnswer?,
        usage: AgentUsage,
        evidence: some Sequence<AgentEvidence> = []
    ) throws {
        guard status.state.isTerminal else {
            throw AgentContractError.invalidRunStatus("result status must be terminal")
        }
        let answerableCompletion = status.terminalReason == .completed
            || status.terminalReason == .completedWithFailures
        guard answerableCompletion == (answer != nil) else {
            throw AgentContractError.invalidRunStatus("answer and terminal reason disagree")
        }
        self.requestID = requestID
        self.executionHandleID = executionHandleID
        self.runID = runID
        self.status = status
        self.answer = answer
        self.usage = usage
        self.evidence = Array(Set(evidence)).sorted()
    }

    /// Decodes and revalidates terminal-result consistency and canonical evidence order.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let evidence = try container.decode([AgentEvidence].self, forKey: .evidence)
        do {
            try self.init(
                requestID: container.decode(AgentRequestID.self, forKey: .requestID),
                executionHandleID: container.decode(AgentExecutionHandleID.self, forKey: .executionHandleID),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                status: container.decode(AgentRunStatus.self, forKey: .status),
                answer: container.decodeIfPresent(AgentAnswer.self, forKey: .answer),
                usage: container.decode(AgentUsage.self, forKey: .usage),
                evidence: evidence
            )
            guard self.evidence == evidence else {
                throw AgentContractError.invalidRunStatus("noncanonical result evidence")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, executionHandleID, runID, status, answer, usage, evidence
    }
}

/// Body-free content-addressed reference used by durable stable-boundary events.
public struct AgentStableBoundaryReference: Hashable, Codable, Sendable, AgentContractPayload {
    /// Stable wire schema identity.
    public static let schemaID = "com.mobilellm.agent.stable-boundary-reference"

    /// Version of the referenced summary format.
    public let formatVersion: UInt16
    /// Digest of the complete canonical stable-boundary summary.
    public let digest: StableDigest
    /// Optional protected artifact containing the referenced summary body.
    public let artifactID: ArtifactID?

    /// Creates a body-free, content-addressed stable-boundary reference.
    public init(
        formatVersion: UInt16 = 1,
        digest: StableDigest,
        artifactID: ArtifactID? = nil
    ) throws {
        guard formatVersion > 0 else {
            throw AgentContractError.invalidEventSequence("stable-boundary format version must be positive")
        }
        self.formatVersion = formatVersion
        self.digest = digest
        self.artifactID = artifactID
    }

    /// Decodes and revalidates the summary format version.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                formatVersion: container.decode(UInt16.self, forKey: .formatVersion),
                digest: container.decode(StableDigest.self, forKey: .digest),
                artifactID: container.decodeIfPresent(ArtifactID.self, forKey: .artifactID)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, digest, artifactID }
}

/// One durable operational event payload for an agent run.
public enum AgentEvent: Hashable, Codable, Sendable {
    /// Immutable run-input snapshot was committed; sensitive bodies remain behind the reference.
    case runInputSnapshotCommitted(AgentStableBoundaryReference)
    /// Immutable compiled-request manifest was committed for a model-attempt step.
    case compiledManifestCommitted(stepID: AgentStepID, reference: AgentStableBoundaryReference)
    /// One normalized action passed validation and was committed for its step.
    case validatedActionCommitted(stepID: AgentStepID, reference: AgentStableBoundaryReference)
    /// A CAS-accepted user response was committed without placing its body in the event.
    case userInputResponseCommitted(
        requestID: InteractionRequestID,
        reference: AgentStableBoundaryReference
    )
    /// Durable status transition.
    case statusChanged(AgentRunStatus)
    /// Stable model-attempt outcome; token deltas remain on a separate ephemeral stream.
    case modelAttemptOutcome(AgentModelAttemptOutcome)
    /// Tool intent was recorded before execution crossed its boundary.
    case toolIntentRecorded(PreparedExternalOperationRequest)
    /// Stable tool outcome was recorded in proposal order.
    case toolOutcomeRecorded(invocationID: ToolInvocationID, outcome: AgentToolInvocationOutcome)
    /// Approval request was durably recorded.
    case approvalRequested(AgentApprovalRequest)
    /// Approval decision was durably recorded.
    case approvalDecided(ApprovalReceipt)
    /// User interaction was durably requested.
    case userInputRequested(UserInputRequest)
    /// Artifact was atomically committed before its reference event.
    case artifactCommitted(ArtifactReference)
    /// Cumulative usage ledger changed at a stable boundary.
    case usageUpdated(AgentUsage)
    /// Redacted diagnostic with stable code.
    case diagnostic(AgentFailure)
    /// The one terminal run result.
    case terminal(AgentResult)

    /// Whether this event terminates the owning run.
    public var isRunTerminal: Bool {
        if case .terminal = self { true } else { false }
    }
}

/// Sequenced event record carried by a versioned agent-event envelope.
public struct AgentEventRecord: Hashable, Codable, Sendable, AgentContractPayload {
    /// Stable wire schema identity.
    public static let schemaID = "com.mobilellm.agent.event"

    /// Globally unique event identity.
    public let eventID: AgentEventID
    /// Agent request that owns this execution stream.
    public let requestID: AgentRequestID
    /// Execution stream identity to which cursors are bound.
    public let executionHandleID: AgentExecutionHandleID
    /// Owning run.
    public let runID: AgentRunID
    /// Monotonic per-run event sequence.
    public let sequence: UInt64
    /// Run state version after this event was committed.
    public let runStateVersion: UInt64
    /// Durable projected state after this event.
    public let runState: AgentRunState
    /// Deterministic commit timestamp.
    public let timestamp: AgentTimestamp
    /// Operational event payload.
    public let event: AgentEvent
    /// Redaction metadata applied before this record was persisted or emitted.
    public let redaction: RedactionMetadata
    /// Cumulative usage after this event, enabling monotonic page validation.
    public let cumulativeUsage: AgentUsage
    /// Digest of the preceding event record, nil only for sequence one.
    public let previousRecordDigest: StableDigest?
    /// Digest binding this record and its predecessor into a durable hash chain.
    public let recordDigest: StableDigest

    /// Creates one sequenced event record.
    public init(
        eventID: AgentEventID,
        requestID: AgentRequestID,
        executionHandleID: AgentExecutionHandleID,
        runID: AgentRunID,
        sequence: UInt64,
        runStateVersion: UInt64,
        runState: AgentRunState,
        timestamp: AgentTimestamp,
        event: AgentEvent,
        redaction: RedactionMetadata,
        cumulativeUsage: AgentUsage,
        previousRecordDigest: StableDigest?
    ) throws {
        guard sequence > 0, runStateVersion > 0 else {
            throw AgentContractError.invalidEventSequence("sequence and state version must be positive")
        }
        guard (sequence == 1) == (previousRecordDigest == nil) else {
            throw AgentContractError.invalidEventSequence("event predecessor does not match sequence")
        }
        guard runState.isTerminal == event.isRunTerminal else {
            throw AgentContractError.invalidEventSequence("terminal state and event disagree")
        }
        switch event {
        case .toolOutcomeRecorded(_, let outcome):
            try outcome.validate()
        case .userInputRequested(let request) where request.runID != runID:
            throw AgentContractError.invalidEventSequence("interaction belongs to another run")
        case .approvalRequested(let request)
            where request.prepared.runID != runID || request.prepared.requestID != requestID:
            throw AgentContractError.invalidEventSequence("approval request belongs to another run")
        case .toolIntentRecorded(let request)
            where request.runID != runID || request.requestID != requestID:
            throw AgentContractError.invalidEventSequence("tool intent belongs to another run")
        case .approvalDecided(let receipt)
            where receipt.runID != runID || receipt.requestID != requestID:
            throw AgentContractError.invalidEventSequence("approval receipt belongs to another request")
        case .artifactCommitted(let artifact) where artifact.provenance.runID != runID:
            throw AgentContractError.invalidEventSequence("artifact belongs to another run")
        case .statusChanged(let status)
            where status.stateVersion != runStateVersion || status.state != runState:
            throw AgentContractError.invalidEventSequence("status event disagrees with projection")
        case .modelAttemptOutcome(.completed(let completion)):
            if case .requestUserInput(let interaction) = completion.action,
               interaction.runID != runID
            {
                throw AgentContractError.invalidEventSequence("model interaction belongs to another run")
            }
        case .terminal(let result)
            where result.requestID != requestID
                || result.runID != runID
                || result.executionHandleID != executionHandleID
                || result.status.stateVersion != runStateVersion
                || result.status.state != runState
                || result.usage != cumulativeUsage:
            throw AgentContractError.invalidEventSequence("terminal result belongs to another execution")
        case .usageUpdated(let usage) where usage != cumulativeUsage:
            throw AgentContractError.invalidEventSequence("usage event disagrees with projection")
        default:
            break
        }
        self.eventID = eventID
        self.requestID = requestID
        self.executionHandleID = executionHandleID
        self.runID = runID
        self.sequence = sequence
        self.runStateVersion = runStateVersion
        self.runState = runState
        self.timestamp = timestamp
        self.event = event
        self.redaction = redaction
        self.cumulativeUsage = cumulativeUsage
        self.previousRecordDigest = previousRecordDigest
        recordDigest = try Self.makeDigest(
            eventID: eventID,
            requestID: requestID,
            executionHandleID: executionHandleID,
            runID: runID,
            sequence: sequence,
            runStateVersion: runStateVersion,
            runState: runState,
            timestamp: timestamp,
            event: event,
            redaction: redaction,
            cumulativeUsage: cumulativeUsage,
            previousRecordDigest: previousRecordDigest
        )
    }

    /// Decodes and revalidates sequence numbers and payload identities.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedDigest = try container.decode(StableDigest.self, forKey: .recordDigest)
        do {
            try self.init(
                eventID: container.decode(AgentEventID.self, forKey: .eventID),
                requestID: container.decode(AgentRequestID.self, forKey: .requestID),
                executionHandleID: container.decode(
                    AgentExecutionHandleID.self,
                    forKey: .executionHandleID
                ),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                sequence: container.decode(UInt64.self, forKey: .sequence),
                runStateVersion: container.decode(UInt64.self, forKey: .runStateVersion),
                runState: container.decode(AgentRunState.self, forKey: .runState),
                timestamp: container.decode(AgentTimestamp.self, forKey: .timestamp),
                event: container.decode(AgentEvent.self, forKey: .event),
                redaction: container.decode(RedactionMetadata.self, forKey: .redaction),
                cumulativeUsage: container.decode(AgentUsage.self, forKey: .cumulativeUsage),
                previousRecordDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .previousRecordDigest
                )
            )
            guard recordDigest == encodedDigest else {
                throw AgentContractError.invalidEventSequence("event record digest mismatch")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case eventID, requestID, executionHandleID, runID, sequence, runStateVersion, runState
        case timestamp, event, redaction, cumulativeUsage, previousRecordDigest, recordDigest
    }

    /// Cursor that resumes immediately after this event.
    public var cursor: AgentEventCursor {
        try! AgentEventCursor(
            executionHandleID: executionHandleID,
            eventID: eventID,
            sequence: sequence,
            runStateVersion: runStateVersion,
            runState: runState,
            timestamp: timestamp,
            cumulativeUsage: cumulativeUsage,
            recordDigest: recordDigest,
            isTerminal: event.isRunTerminal
        )
    }

    private static func makeDigest(
        eventID: AgentEventID,
        requestID: AgentRequestID,
        executionHandleID: AgentExecutionHandleID,
        runID: AgentRunID,
        sequence: UInt64,
        runStateVersion: UInt64,
        runState: AgentRunState,
        timestamp: AgentTimestamp,
        event: AgentEvent,
        redaction: RedactionMetadata,
        cumulativeUsage: AgentUsage,
        previousRecordDigest: StableDigest?
    ) throws -> StableDigest {
        let material = AgentEventDigestMaterial(
            eventID: eventID,
            requestID: requestID,
            executionHandleID: executionHandleID,
            runID: runID,
            sequence: sequence,
            runStateVersion: runStateVersion,
            runState: runState,
            timestamp: timestamp,
            event: event,
            redaction: redaction,
            cumulativeUsage: cumulativeUsage,
            previousRecordDigest: previousRecordDigest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return StableDigest.sha256(try encoder.encode(material))
    }
}

private struct AgentEventDigestMaterial: Encodable {
    let eventID: AgentEventID
    let requestID: AgentRequestID
    let executionHandleID: AgentExecutionHandleID
    let runID: AgentRunID
    let sequence: UInt64
    let runStateVersion: UInt64
    let runState: AgentRunState
    let timestamp: AgentTimestamp
    let event: AgentEvent
    let redaction: RedactionMetadata
    let cumulativeUsage: AgentUsage
    let previousRecordDigest: StableDigest?
}

/// Versioned agent request envelope.
public typealias AgentRequestEnvelope = AgentEnvelope<AgentRequest>
/// Versioned agent command envelope.
public typealias AgentCommandEnvelope = AgentEnvelope<AgentCommand>
/// Versioned command-receipt envelope.
public typealias AgentCommandReceiptEnvelope = AgentEnvelope<AgentCommandReceipt>
/// Versioned approval-request envelope.
public typealias AgentApprovalRequestEnvelope = AgentEnvelope<AgentApprovalRequest>
/// Versioned agent result envelope.
public typealias AgentResultEnvelope = AgentEnvelope<AgentResult>
/// Versioned durable agent event envelope.
public typealias AgentEventEnvelope = AgentEnvelope<AgentEventRecord>

/// Pure validator for cursor, ordering, identity, state-version, and terminal stream invariants.
public enum AgentEventSequenceValidator {
    /// Validates one contiguous event page for an expected execution and run.
    public static func validate(
        _ envelopes: [AgentEventEnvelope],
        requestID: AgentRequestID,
        executionHandleID: AgentExecutionHandleID,
        runID: AgentRunID,
        after trustedCursor: TrustedAgentEventCursor? = nil,
        requireTerminal: Bool = false
    ) throws {
        let cursor = trustedCursor?.cursor
        if let cursor, cursor.executionHandleID != executionHandleID {
            throw AgentContractError.invalidEventSequence("cursor belongs to another execution")
        }
        if cursor?.isTerminal == true, !envelopes.isEmpty {
            throw AgentContractError.invalidEventSequence("event page follows an earlier terminal result")
        }
        var previousSequence = cursor?.sequence
        var previousStateVersion = cursor?.runStateVersion
        var previousState = cursor?.runState
        var previousTimestamp = cursor?.timestamp
        var previousUsage = cursor?.cumulativeUsage
        var previousDigest = cursor?.recordDigest
        var terminalSeen = cursor?.isTerminal ?? false
        var eventIDs: Set<AgentEventID> = []
        for envelope in envelopes {
            let record = envelope.payload
            guard record.requestID == requestID,
                  record.executionHandleID == executionHandleID,
                  record.runID == runID
            else {
                throw AgentContractError.invalidEventSequence("event belongs to another stream or run")
            }
            guard eventIDs.insert(record.eventID).inserted else {
                throw AgentContractError.invalidEventSequence("duplicate event identity")
            }
            if terminalSeen {
                throw AgentContractError.invalidEventSequence("event follows terminal result")
            }
            if let previousSequence {
                guard previousSequence != UInt64.max, record.sequence == previousSequence + 1 else {
                    throw AgentContractError.invalidEventSequence("noncontiguous event sequence")
                }
            }
            if let previousStateVersion, record.runStateVersion < previousStateVersion {
                throw AgentContractError.invalidEventSequence("state version moved backwards")
            }
            if let previousState {
                guard AgentRunTransitionMatrix.allows(from: previousState, to: record.runState),
                      previousState == record.runState
                        || record.runStateVersion > (previousStateVersion ?? 0)
                else { throw AgentContractError.invalidEventSequence("illegal run-state transition") }
            }
            if let previousTimestamp, record.timestamp < previousTimestamp {
                throw AgentContractError.invalidEventSequence("event timestamp moved backwards")
            }
            if let previousUsage,
               !previousUsage.quantities.isComponentwiseAtMost(record.cumulativeUsage.quantities)
            {
                throw AgentContractError.invalidEventSequence("cumulative usage moved backwards")
            }
            guard record.previousRecordDigest == previousDigest else {
                throw AgentContractError.invalidEventSequence("event hash chain is discontinuous")
            }
            if case .terminal(let result) = record.event {
                guard result.executionHandleID == executionHandleID, result.runID == runID else {
                    throw AgentContractError.invalidEventSequence("terminal result identity mismatch")
                }
                terminalSeen = true
            }
            previousSequence = record.sequence
            previousStateVersion = record.runStateVersion
            previousState = record.runState
            previousTimestamp = record.timestamp
            previousUsage = record.cumulativeUsage
            previousDigest = record.recordDigest
        }
        if cursor == nil, let first = envelopes.first, first.payload.sequence != 1 {
            throw AgentContractError.invalidEventSequence("initial event page must start at sequence one")
        }
        if requireTerminal, !terminalSeen {
            throw AgentContractError.invalidEventSequence("terminal event required")
        }
    }
}
