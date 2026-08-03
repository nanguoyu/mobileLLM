// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Fail-closed errors emitted while freezing, compiling, or restoring model context.
public enum ContextCompilationError: Error, Hashable, Sendable {
    case invalidInput(String)
    case contextUnsatisfiable(requiredTokens: UInt64, availableTokens: UInt64)
    case manifestMismatch
    case integrityFailure(String)
}

/// Deterministic token-estimator identity persisted with every compiled request.
public struct ContextTokenEstimatorIdentity: Hashable, Codable, Sendable {
    public let identifier: String
    public let version: UInt32
    public let utf8BytesPerToken: UInt8
    public let safetyMarginBasisPoints: UInt16
    public let messageOverheadTokens: UInt16
    public let toolSchemaOverheadTokens: UInt16

    public init(
        identifier: String,
        version: UInt32,
        utf8BytesPerToken: UInt8,
        safetyMarginBasisPoints: UInt16,
        messageOverheadTokens: UInt16,
        toolSchemaOverheadTokens: UInt16
    ) throws {
        guard ContextValidation.isNamespace(identifier), version > 0,
              (1 ... 8).contains(utf8BytesPerToken), safetyMarginBasisPoints <= 10_000,
              messageOverheadTokens > 0, toolSchemaOverheadTokens > 0
        else { throw ContextCompilationError.invalidInput("token estimator identity") }
        self.identifier = identifier
        self.version = version
        self.utf8BytesPerToken = utf8BytesPerToken
        self.safetyMarginBasisPoints = safetyMarginBasisPoints
        self.messageOverheadTokens = messageOverheadTokens
        self.toolSchemaOverheadTokens = toolSchemaOverheadTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                version: container.decode(UInt32.self, forKey: .version),
                utf8BytesPerToken: container.decode(UInt8.self, forKey: .utf8BytesPerToken),
                safetyMarginBasisPoints: container.decode(
                    UInt16.self,
                    forKey: .safetyMarginBasisPoints
                ),
                messageOverheadTokens: container.decode(
                    UInt16.self,
                    forKey: .messageOverheadTokens
                ),
                toolSchemaOverheadTokens: container.decode(
                    UInt16.self,
                    forKey: .toolSchemaOverheadTokens
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, version, utf8BytesPerToken, safetyMarginBasisPoints
        case messageOverheadTokens, toolSchemaOverheadTokens
    }
}

/// Context and output allocation frozen for one model attempt.
public struct ContextTokenBudget: Hashable, Codable, Sendable {
    public let maximumContextTokens: UInt64
    public let reservedOutputTokens: UInt64
    public let maximumToolSchemaTokens: UInt64

    public var maximumInputTokens: UInt64 { maximumContextTokens - reservedOutputTokens }

    public init(
        maximumContextTokens: UInt64,
        reservedOutputTokens: UInt64,
        maximumToolSchemaTokens: UInt64
    ) throws {
        guard maximumContextTokens > 0, reservedOutputTokens < maximumContextTokens,
              maximumToolSchemaTokens <= maximumContextTokens - reservedOutputTokens
        else { throw ContextCompilationError.invalidInput("context token budget") }
        self.maximumContextTokens = maximumContextTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.maximumToolSchemaTokens = maximumToolSchemaTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumContextTokens: container.decode(UInt64.self, forKey: .maximumContextTokens),
                reservedOutputTokens: container.decode(UInt64.self, forKey: .reservedOutputTokens),
                maximumToolSchemaTokens: container.decode(
                    UInt64.self,
                    forKey: .maximumToolSchemaTokens
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumContextTokens, reservedOutputTokens, maximumToolSchemaTokens
    }
}

/// Immutable text with exact source revision and content digest.
public struct FrozenContextText: Hashable, Codable, Sendable {
    public static let maximumUTF8Bytes = 8 * 1_024 * 1_024

    public let sourceID: String
    public let revision: String
    public let content: String
    public let contentDigest: StableDigest

    public init(sourceID: String, revision: String, content: String) throws {
        guard ContextValidation.isIdentifier(sourceID), ContextValidation.isRevision(revision),
              content.utf8.count <= Self.maximumUTF8Bytes
        else { throw ContextCompilationError.invalidInput("frozen context text") }
        self.sourceID = sourceID
        self.revision = revision
        self.content = content
        contentDigest = StableDigest.sha256(Data(content.utf8))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedDigest = try container.decode(StableDigest.self, forKey: .contentDigest)
        do {
            try self.init(
                sourceID: container.decode(String.self, forKey: .sourceID),
                revision: container.decode(String.self, forKey: .revision),
                content: container.decode(String.self, forKey: .content)
            )
            guard contentDigest == encodedDigest else {
                throw ContextCompilationError.integrityFailure("frozen content digest")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case sourceID, revision, content, contentDigest }
}

public struct BaseSystemContextSource: Hashable, Codable, Sendable {
    public let frozen: FrozenContextText

    public init(sourceID: String = "system.base", revision: String, content: String) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextCompilationError.invalidInput("base system policy is empty")
        }
        frozen = try FrozenContextText(sourceID: sourceID, revision: revision, content: content)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(FrozenContextText.self)
        do { try self.init(sourceID: value.sourceID, revision: value.revision, content: value.content) }
        catch { throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(frozen)
    }
}

public struct SkillInstructionContextSource: Hashable, Codable, Sendable {
    public let frozen: FrozenContextText

    public init(skillID: String, version: String, instructions: String) throws {
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextCompilationError.invalidInput("Skill instructions are empty")
        }
        frozen = try FrozenContextText(sourceID: skillID, revision: version, content: instructions)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(FrozenContextText.self)
        do { try self.init(skillID: value.sourceID, version: value.revision, instructions: value.content) }
        catch { throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(frozen)
    }
}

/// Canonical-English long-term Memory. The type deliberately exposes no model-language field.
public struct CanonicalEnglishMemoryContextSource: Hashable, Codable, Sendable {
    public let frozen: FrozenContextText

    public init(memoryID: String, revision: String, canonicalEnglishContent: String) throws {
        guard !canonicalEnglishContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContextCompilationError.invalidInput("canonical Memory is empty")
        }
        frozen = try FrozenContextText(
            sourceID: memoryID,
            revision: revision,
            content: canonicalEnglishContent
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(FrozenContextText.self)
        do {
            try self.init(
                memoryID: value.sourceID,
                revision: value.revision,
                canonicalEnglishContent: value.content
            )
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(frozen)
    }
}

public enum ConversationContextRole: String, CaseIterable, Hashable, Codable, Sendable {
    case user
    case assistant
}

public struct ConversationTurnContextSource: Hashable, Codable, Sendable {
    public let frozen: FrozenContextText
    public let role: ConversationContextRole
    /// Artifacts (e.g. images) that travelled with this turn; replayed for multi-turn vision history.
    public let attachments: [ArtifactReference]

    public init(
        messageID: MessageID,
        revision: String,
        role: ConversationContextRole,
        content: String,
        attachments: [ArtifactReference] = []
    ) throws {
        self.frozen = try FrozenContextText(
            sourceID: messageID.description,
            revision: revision,
            content: content
        )
        self.role = role
        self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(FrozenContextText.self, forKey: .frozen)
        do {
            guard let messageID = MessageID(value.sourceID) else {
                throw ContextCompilationError.invalidInput("conversation message identity")
            }
            try self.init(
                messageID: messageID,
                revision: value.revision,
                role: container.decode(ConversationContextRole.self, forKey: .role),
                content: value.content,
                attachments: container.decodeIfPresent(
                    [ArtifactReference].self,
                    forKey: .attachments
                ) ?? []
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case frozen, role, attachments }
}

public struct CurrentUserContextSource: Hashable, Codable, Sendable {
    public let frozen: FrozenContextText
    public let attachments: [ArtifactReference]

    public init(
        userTurnID: UserTurnID,
        revision: String,
        content: String,
        attachments: [ArtifactReference] = []
    ) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              attachments.count <= 64,
              Set(attachments.map(\.id)).count == attachments.count
        else { throw ContextCompilationError.invalidInput("current user request") }
        frozen = try FrozenContextText(
            sourceID: userTurnID.description,
            revision: revision,
            content: content
        )
        self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frozen = try container.decode(FrozenContextText.self, forKey: .frozen)
        let attachments = try container.decode([ArtifactReference].self, forKey: .attachments)
        do {
            guard let userTurnID = UserTurnID(frozen.sourceID) else {
                throw ContextCompilationError.invalidInput("current user identity")
            }
            try self.init(
                userTurnID: userTurnID,
                revision: frozen.revision,
                content: frozen.content,
                attachments: attachments
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case frozen, attachments }
}

public struct RunStateContextSource: Hashable, Codable, Sendable {
    public let frozen: FrozenContextText

    public init(revision: String, canonicalState: CanonicalJSON) throws {
        frozen = try FrozenContextText(
            sourceID: "run.state",
            revision: revision,
            content: canonicalState.string
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(FrozenContextText.self)
        do {
            guard value.sourceID == "run.state" else {
                throw ContextCompilationError.invalidInput("run-state identity")
            }
            try self.init(
                revision: value.revision,
                canonicalState: CanonicalJSON(canonicalData: Data(value.content.utf8))
            )
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(frozen)
    }
}

public struct ArtifactExcerptContextSource: Hashable, Codable, Sendable {
    public let frozen: FrozenContextText
    public let artifact: ArtifactReference

    public init(artifact: ArtifactReference, excerptRevision: String, excerpt: String) throws {
        frozen = try FrozenContextText(
            sourceID: artifact.id.description,
            revision: excerptRevision,
            content: excerpt
        )
        self.artifact = artifact
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(FrozenContextText.self, forKey: .frozen)
        let artifact = try container.decode(ArtifactReference.self, forKey: .artifact)
        do {
            guard value.sourceID == artifact.id.description else {
                throw ContextCompilationError.invalidInput("artifact excerpt identity")
            }
            try self.init(artifact: artifact, excerptRevision: value.revision, excerpt: value.content)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case frozen, artifact }
}

public struct UntrustedToolResultContextSource: Hashable, Codable, Sendable {
    public let frozen: FrozenContextText
    public let invocationID: ToolInvocationID
    public let descriptorID: AgentToolDescriptorID
    public let resultDigest: StableDigest

    public init(
        invocationID: ToolInvocationID,
        descriptorID: AgentToolDescriptorID,
        resultRevision: String,
        resultContent: String,
        resultDigest: StableDigest? = nil
    ) throws {
        frozen = try FrozenContextText(
            sourceID: invocationID.description,
            revision: resultRevision,
            content: resultContent
        )
        self.invocationID = invocationID
        self.descriptorID = descriptorID
        self.resultDigest = resultDigest ?? frozen.contentDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(FrozenContextText.self, forKey: .frozen)
        let invocationID = try container.decode(ToolInvocationID.self, forKey: .invocationID)
        do {
            guard value.sourceID == invocationID.description else {
                throw ContextCompilationError.invalidInput("tool-result identity")
            }
            try self.init(
                invocationID: invocationID,
                descriptorID: container.decode(AgentToolDescriptorID.self, forKey: .descriptorID),
                resultRevision: value.revision,
                resultContent: value.content,
                resultDigest: container.decode(StableDigest.self, forKey: .resultDigest)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case frozen, invocationID, descriptorID, resultDigest
    }
}

/// Every mutable source needed for one attempt, frozen before compilation.
public struct FrozenContextSnapshot: Hashable, Codable, Sendable {
    public let runID: AgentRunID
    public let requestID: AgentRequestID
    public let stepID: AgentStepID
    public let baseSystem: BaseSystemContextSource
    public let skills: [SkillInstructionContextSource]
    public let memories: [CanonicalEnglishMemoryContextSource]
    public let conversation: [ConversationTurnContextSource]
    public let currentUser: CurrentUserContextSource
    public let runState: RunStateContextSource?
    public let artifactExcerpts: [ArtifactExcerptContextSource]
    public let untrustedToolResults: [UntrustedToolResultContextSource]
    public let advertisedTools: [AgentToolDescriptor]
    public let selectorID: String
    public let selectorPolicyVersion: UInt32
    public let contextPolicyVersion: UInt32
    public let approvalPolicyVersion: UInt32

    public init(
        runID: AgentRunID,
        requestID: AgentRequestID,
        stepID: AgentStepID,
        baseSystem: BaseSystemContextSource,
        skills: [SkillInstructionContextSource] = [],
        memories: [CanonicalEnglishMemoryContextSource] = [],
        conversation: [ConversationTurnContextSource] = [],
        currentUser: CurrentUserContextSource,
        runState: RunStateContextSource? = nil,
        artifactExcerpts: [ArtifactExcerptContextSource] = [],
        untrustedToolResults: [UntrustedToolResultContextSource] = [],
        advertisedTools: [AgentToolDescriptor] = [],
        selectorID: String,
        selectorPolicyVersion: UInt32,
        contextPolicyVersion: UInt32,
        approvalPolicyVersion: UInt32
    ) throws {
        var sourceKeys = ["base:\(baseSystem.frozen.sourceID)"]
        sourceKeys.append(contentsOf: skills.map { "skill:\($0.frozen.sourceID)" })
        sourceKeys.append(contentsOf: memories.map { "memory:\($0.frozen.sourceID)" })
        sourceKeys.append(contentsOf: conversation.map { "conversation:\($0.frozen.sourceID)" })
        sourceKeys.append("current-user:\(currentUser.frozen.sourceID)")
        if let runState { sourceKeys.append("run-state:\(runState.frozen.sourceID)") }
        sourceKeys.append(contentsOf: artifactExcerpts.map { "artifact:\($0.frozen.sourceID)" })
        sourceKeys.append(
            contentsOf: untrustedToolResults.map { "tool-result:\($0.frozen.sourceID)" }
        )
        let exactToolIDs = advertisedTools.map(\.id)
        guard skills.count <= 64, memories.count <= 512, conversation.count <= 4_096,
              artifactExcerpts.count <= 512, untrustedToolResults.count <= 512,
              advertisedTools.count <= 64,
              Set(sourceKeys).count == sourceKeys.count,
              Set(exactToolIDs).count == exactToolIDs.count,
              Set(exactToolIDs.map(\.logicalID)).count == exactToolIDs.count,
              ContextValidation.isNamespace(selectorID), selectorPolicyVersion > 0,
              contextPolicyVersion > 0, approvalPolicyVersion > 0
        else { throw ContextCompilationError.invalidInput("frozen context snapshot") }
        self.runID = runID
        self.requestID = requestID
        self.stepID = stepID
        self.baseSystem = baseSystem
        self.skills = skills
        self.memories = memories
        self.conversation = conversation
        self.currentUser = currentUser
        self.runState = runState
        self.artifactExcerpts = artifactExcerpts
        self.untrustedToolResults = untrustedToolResults
        self.advertisedTools = advertisedTools
        self.selectorID = selectorID
        self.selectorPolicyVersion = selectorPolicyVersion
        self.contextPolicyVersion = contextPolicyVersion
        self.approvalPolicyVersion = approvalPolicyVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                runID: container.decode(AgentRunID.self, forKey: .runID),
                requestID: container.decode(AgentRequestID.self, forKey: .requestID),
                stepID: container.decode(AgentStepID.self, forKey: .stepID),
                baseSystem: container.decode(BaseSystemContextSource.self, forKey: .baseSystem),
                skills: container.decode([SkillInstructionContextSource].self, forKey: .skills),
                memories: container.decode(
                    [CanonicalEnglishMemoryContextSource].self,
                    forKey: .memories
                ),
                conversation: container.decode(
                    [ConversationTurnContextSource].self,
                    forKey: .conversation
                ),
                currentUser: container.decode(CurrentUserContextSource.self, forKey: .currentUser),
                runState: container.decodeIfPresent(RunStateContextSource.self, forKey: .runState),
                artifactExcerpts: container.decode(
                    [ArtifactExcerptContextSource].self,
                    forKey: .artifactExcerpts
                ),
                untrustedToolResults: container.decode(
                    [UntrustedToolResultContextSource].self,
                    forKey: .untrustedToolResults
                ),
                advertisedTools: container.decode(
                    [AgentToolDescriptor].self,
                    forKey: .advertisedTools
                ),
                selectorID: container.decode(String.self, forKey: .selectorID),
                selectorPolicyVersion: container.decode(UInt32.self, forKey: .selectorPolicyVersion),
                contextPolicyVersion: container.decode(UInt32.self, forKey: .contextPolicyVersion),
                approvalPolicyVersion: container.decode(UInt32.self, forKey: .approvalPolicyVersion)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runID, requestID, stepID, baseSystem, skills, memories, conversation, currentUser
        case runState, artifactExcerpts, untrustedToolResults, advertisedTools, selectorID
        case selectorPolicyVersion, contextPolicyVersion, approvalPolicyVersion
    }
}

public enum ContextSourceKind: String, CaseIterable, Hashable, Codable, Sendable {
    case baseSystem
    case skill
    case canonicalEnglishMemory
    case conversationUser
    case conversationAssistant
    case currentUser
    case runState
    case artifactExcerpt
    case untrustedToolResult
}

public enum ContextSourceDisposition: String, CaseIterable, Hashable, Codable, Sendable {
    case included
    case truncated
    case omitted
}

public enum ContextOmissionReason: String, CaseIterable, Hashable, Codable, Sendable {
    case inputBudgetExhausted
    case toolSchemaBudgetExhausted
}

/// Byte range over valid UTF-8 boundaries in the original frozen source.
public struct ContextUTF8Range: Hashable, Codable, Sendable {
    public let offset: UInt64
    public let length: UInt64

    public init(offset: UInt64, length: UInt64) throws {
        guard offset <= UInt64.max - length else {
            throw ContextCompilationError.invalidInput("UTF-8 range")
        }
        self.offset = offset
        self.length = length
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                offset: container.decode(UInt64.self, forKey: .offset),
                length: container.decode(UInt64.self, forKey: .length)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case offset, length }
}

/// Auditable disposition of one frozen text source.
public struct CompiledContextSourceRecord: Hashable, Codable, Sendable {
    public let kind: ContextSourceKind
    public let sourceID: String
    public let revision: String
    public let role: AgentModelMessageRole
    public let isUntrustedData: Bool
    public let originalContentDigest: StableDigest
    public let originalUTF8ByteCount: UInt64
    public let originalEstimatedTokens: UInt64
    public let disposition: ContextSourceDisposition
    public let selectedUTF8Range: ContextUTF8Range?
    public let selectedContentDigest: StableDigest?
    public let renderedMessageDigest: StableDigest?
    public let adoptedEstimatedTokens: UInt64
    public let omissionReason: ContextOmissionReason?
    public let artifactID: ArtifactID?
    public let artifactContentDigest: StableDigest?
    public let toolInvocationID: ToolInvocationID?
    public let toolDescriptorID: AgentToolDescriptorID?
    public let toolResultDigest: StableDigest?

    public init(
        kind: ContextSourceKind,
        sourceID: String,
        revision: String,
        role: AgentModelMessageRole,
        isUntrustedData: Bool,
        originalContentDigest: StableDigest,
        originalUTF8ByteCount: UInt64,
        originalEstimatedTokens: UInt64,
        disposition: ContextSourceDisposition,
        selectedUTF8Range: ContextUTF8Range?,
        selectedContentDigest: StableDigest?,
        renderedMessageDigest: StableDigest?,
        adoptedEstimatedTokens: UInt64,
        omissionReason: ContextOmissionReason?,
        artifactID: ArtifactID? = nil,
        artifactContentDigest: StableDigest? = nil,
        toolInvocationID: ToolInvocationID? = nil,
        toolDescriptorID: AgentToolDescriptorID? = nil,
        toolResultDigest: StableDigest? = nil
    ) throws {
        let rangeIsValid = selectedUTF8Range.map {
            $0.offset <= originalUTF8ByteCount && $0.length <= originalUTF8ByteCount - $0.offset
        } ?? false
        let selectedFieldsPresent = selectedContentDigest != nil && renderedMessageDigest != nil
        let sourceStateIsValid = switch disposition {
        case .included:
            rangeIsValid && selectedUTF8Range?.offset == 0
                && selectedUTF8Range?.length == originalUTF8ByteCount
                && selectedFieldsPresent && adoptedEstimatedTokens > 0 && omissionReason == nil
        case .truncated:
            rangeIsValid && selectedUTF8Range!.length < originalUTF8ByteCount
                && selectedFieldsPresent && adoptedEstimatedTokens > 0 && omissionReason == nil
        case .omitted:
            selectedUTF8Range == nil && !selectedFieldsPresent
                && adoptedEstimatedTokens == 0 && omissionReason != nil
        }
        let artifactFieldsValid = kind == .artifactExcerpt
            ? artifactID != nil && artifactContentDigest != nil
            : artifactID == nil && artifactContentDigest == nil
        let toolFieldsValid = kind == .untrustedToolResult
            ? toolInvocationID != nil && toolDescriptorID != nil && toolResultDigest != nil
            : toolInvocationID == nil && toolDescriptorID == nil && toolResultDigest == nil
        guard ContextValidation.isIdentifier(sourceID), ContextValidation.isRevision(revision),
              originalUTF8ByteCount <= UInt64(FrozenContextText.maximumUTF8Bytes),
              originalEstimatedTokens > 0, adoptedEstimatedTokens <= originalEstimatedTokens,
              sourceStateIsValid, artifactFieldsValid, toolFieldsValid,
              role != .tool || isUntrustedData,
              ![.artifactExcerpt, .untrustedToolResult].contains(kind) || isUntrustedData
        else { throw ContextCompilationError.invalidInput("compiled source record") }
        self.kind = kind
        self.sourceID = sourceID
        self.revision = revision
        self.role = role
        self.isUntrustedData = isUntrustedData
        self.originalContentDigest = originalContentDigest
        self.originalUTF8ByteCount = originalUTF8ByteCount
        self.originalEstimatedTokens = originalEstimatedTokens
        self.disposition = disposition
        self.selectedUTF8Range = selectedUTF8Range
        self.selectedContentDigest = selectedContentDigest
        self.renderedMessageDigest = renderedMessageDigest
        self.adoptedEstimatedTokens = adoptedEstimatedTokens
        self.omissionReason = omissionReason
        self.artifactID = artifactID
        self.artifactContentDigest = artifactContentDigest
        self.toolInvocationID = toolInvocationID
        self.toolDescriptorID = toolDescriptorID
        self.toolResultDigest = toolResultDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(ContextSourceKind.self, forKey: .kind),
                sourceID: container.decode(String.self, forKey: .sourceID),
                revision: container.decode(String.self, forKey: .revision),
                role: container.decode(AgentModelMessageRole.self, forKey: .role),
                isUntrustedData: container.decode(Bool.self, forKey: .isUntrustedData),
                originalContentDigest: container.decode(
                    StableDigest.self,
                    forKey: .originalContentDigest
                ),
                originalUTF8ByteCount: container.decode(UInt64.self, forKey: .originalUTF8ByteCount),
                originalEstimatedTokens: container.decode(
                    UInt64.self,
                    forKey: .originalEstimatedTokens
                ),
                disposition: container.decode(ContextSourceDisposition.self, forKey: .disposition),
                selectedUTF8Range: container.decodeIfPresent(
                    ContextUTF8Range.self,
                    forKey: .selectedUTF8Range
                ),
                selectedContentDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .selectedContentDigest
                ),
                renderedMessageDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .renderedMessageDigest
                ),
                adoptedEstimatedTokens: container.decode(UInt64.self, forKey: .adoptedEstimatedTokens),
                omissionReason: container.decodeIfPresent(
                    ContextOmissionReason.self,
                    forKey: .omissionReason
                ),
                artifactID: container.decodeIfPresent(ArtifactID.self, forKey: .artifactID),
                artifactContentDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .artifactContentDigest
                ),
                toolInvocationID: container.decodeIfPresent(
                    ToolInvocationID.self,
                    forKey: .toolInvocationID
                ),
                toolDescriptorID: container.decodeIfPresent(
                    AgentToolDescriptorID.self,
                    forKey: .toolDescriptorID
                ),
                toolResultDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .toolResultDigest
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sourceID, revision, role, isUntrustedData, originalContentDigest
        case originalUTF8ByteCount, originalEstimatedTokens, disposition, selectedUTF8Range
        case selectedContentDigest, renderedMessageDigest, adoptedEstimatedTokens, omissionReason
        case artifactID, artifactContentDigest, toolInvocationID, toolDescriptorID, toolResultDigest
    }
}

/// Auditable budget and integrity facts for one exact advertised tool descriptor.
public struct CompiledToolSchemaRecord: Hashable, Codable, Sendable {
    public let descriptorID: AgentToolDescriptorID
    public let descriptorDigest: StableDigest
    public let serializedSchemaDigest: StableDigest
    public let inputSchemaDigest: StableDigest
    public let outputSchemaDigest: StableDigest?
    public let trustRevisionDigest: StableDigest
    public let serializedUTF8ByteCount: UInt64
    public let originalEstimatedTokens: UInt64
    public let disposition: ContextSourceDisposition
    public let adoptedEstimatedTokens: UInt64
    public let omissionReason: ContextOmissionReason?

    public init(
        descriptorID: AgentToolDescriptorID,
        descriptorDigest: StableDigest,
        serializedSchemaDigest: StableDigest,
        inputSchemaDigest: StableDigest,
        outputSchemaDigest: StableDigest?,
        trustRevisionDigest: StableDigest,
        serializedUTF8ByteCount: UInt64,
        originalEstimatedTokens: UInt64,
        disposition: ContextSourceDisposition,
        adoptedEstimatedTokens: UInt64,
        omissionReason: ContextOmissionReason?
    ) throws {
        guard serializedUTF8ByteCount > 0, originalEstimatedTokens > 0,
              descriptorID.schemaDigest == inputSchemaDigest,
              disposition != .truncated,
              (disposition == .included
                  ? adoptedEstimatedTokens == originalEstimatedTokens && omissionReason == nil
                  : adoptedEstimatedTokens == 0 && omissionReason != nil)
        else { throw ContextCompilationError.invalidInput("compiled tool schema record") }
        self.descriptorID = descriptorID
        self.descriptorDigest = descriptorDigest
        self.serializedSchemaDigest = serializedSchemaDigest
        self.inputSchemaDigest = inputSchemaDigest
        self.outputSchemaDigest = outputSchemaDigest
        self.trustRevisionDigest = trustRevisionDigest
        self.serializedUTF8ByteCount = serializedUTF8ByteCount
        self.originalEstimatedTokens = originalEstimatedTokens
        self.disposition = disposition
        self.adoptedEstimatedTokens = adoptedEstimatedTokens
        self.omissionReason = omissionReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                descriptorID: container.decode(AgentToolDescriptorID.self, forKey: .descriptorID),
                descriptorDigest: container.decode(StableDigest.self, forKey: .descriptorDigest),
                serializedSchemaDigest: container.decode(
                    StableDigest.self,
                    forKey: .serializedSchemaDigest
                ),
                inputSchemaDigest: container.decode(StableDigest.self, forKey: .inputSchemaDigest),
                outputSchemaDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .outputSchemaDigest
                ),
                trustRevisionDigest: container.decode(
                    StableDigest.self,
                    forKey: .trustRevisionDigest
                ),
                serializedUTF8ByteCount: container.decode(
                    UInt64.self,
                    forKey: .serializedUTF8ByteCount
                ),
                originalEstimatedTokens: container.decode(
                    UInt64.self,
                    forKey: .originalEstimatedTokens
                ),
                disposition: container.decode(ContextSourceDisposition.self, forKey: .disposition),
                adoptedEstimatedTokens: container.decode(UInt64.self, forKey: .adoptedEstimatedTokens),
                omissionReason: container.decodeIfPresent(
                    ContextOmissionReason.self,
                    forKey: .omissionReason
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case descriptorID, descriptorDigest, serializedSchemaDigest, inputSchemaDigest
        case outputSchemaDigest, trustRevisionDigest, serializedUTF8ByteCount
        case originalEstimatedTokens, disposition, adoptedEstimatedTokens, omissionReason
    }
}

/// Immutable, self-digesting evidence for an exact compiled model request.
public struct CompiledRequestManifest: Hashable, Codable, Sendable {
    public static let formatVersion: UInt16 = 1

    public let version: UInt16
    public let runID: AgentRunID
    public let requestID: AgentRequestID
    public let stepID: AgentStepID
    public let frozenSnapshotDigest: StableDigest
    public let estimator: ContextTokenEstimatorIdentity
    public let budget: ContextTokenBudget
    public let sourceRecords: [CompiledContextSourceRecord]
    public let toolSchemaRecords: [CompiledToolSchemaRecord]
    public let selectorID: String
    public let selectorPolicyVersion: UInt32
    public let contextPolicyVersion: UInt32
    public let approvalPolicyVersion: UInt32
    public let renderedPromptDigest: StableDigest
    public let promptEstimatedTokens: UInt64
    public let toolSchemaEstimatedTokens: UInt64
    public let totalEstimatedInputTokens: UInt64
    public let manifestDigest: StableDigest

    public init(
        runID: AgentRunID,
        requestID: AgentRequestID,
        stepID: AgentStepID,
        frozenSnapshotDigest: StableDigest,
        estimator: ContextTokenEstimatorIdentity,
        budget: ContextTokenBudget,
        sourceRecords: [CompiledContextSourceRecord],
        toolSchemaRecords: [CompiledToolSchemaRecord],
        selectorID: String,
        selectorPolicyVersion: UInt32,
        contextPolicyVersion: UInt32,
        approvalPolicyVersion: UInt32,
        renderedPromptDigest: StableDigest,
        promptEstimatedTokens: UInt64,
        toolSchemaEstimatedTokens: UInt64,
        totalEstimatedInputTokens: UInt64
    ) throws {
        try Self.validate(
            budget: budget,
            sourceRecords: sourceRecords,
            toolSchemaRecords: toolSchemaRecords,
            selectorID: selectorID,
            selectorPolicyVersion: selectorPolicyVersion,
            contextPolicyVersion: contextPolicyVersion,
            approvalPolicyVersion: approvalPolicyVersion,
            promptEstimatedTokens: promptEstimatedTokens,
            toolSchemaEstimatedTokens: toolSchemaEstimatedTokens,
            totalEstimatedInputTokens: totalEstimatedInputTokens
        )
        version = Self.formatVersion
        self.runID = runID
        self.requestID = requestID
        self.stepID = stepID
        self.frozenSnapshotDigest = frozenSnapshotDigest
        self.estimator = estimator
        self.budget = budget
        self.sourceRecords = sourceRecords
        self.toolSchemaRecords = toolSchemaRecords
        self.selectorID = selectorID
        self.selectorPolicyVersion = selectorPolicyVersion
        self.contextPolicyVersion = contextPolicyVersion
        self.approvalPolicyVersion = approvalPolicyVersion
        self.renderedPromptDigest = renderedPromptDigest
        self.promptEstimatedTokens = promptEstimatedTokens
        self.toolSchemaEstimatedTokens = toolSchemaEstimatedTokens
        self.totalEstimatedInputTokens = totalEstimatedInputTokens
        manifestDigest = Self.computeDigest(
            version: Self.formatVersion,
            runID: runID,
            requestID: requestID,
            stepID: stepID,
            frozenSnapshotDigest: frozenSnapshotDigest,
            estimator: estimator,
            budget: budget,
            sourceRecords: sourceRecords,
            toolSchemaRecords: toolSchemaRecords,
            selectorID: selectorID,
            selectorPolicyVersion: selectorPolicyVersion,
            contextPolicyVersion: contextPolicyVersion,
            approvalPolicyVersion: approvalPolicyVersion,
            renderedPromptDigest: renderedPromptDigest,
            promptEstimatedTokens: promptEstimatedTokens,
            toolSchemaEstimatedTokens: toolSchemaEstimatedTokens,
            totalEstimatedInputTokens: totalEstimatedInputTokens
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedVersion = try container.decode(UInt16.self, forKey: .version)
        let encodedDigest = try container.decode(StableDigest.self, forKey: .manifestDigest)
        guard encodedVersion == Self.formatVersion else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown manifest version")
            )
        }
        do {
            try self.init(
                runID: container.decode(AgentRunID.self, forKey: .runID),
                requestID: container.decode(AgentRequestID.self, forKey: .requestID),
                stepID: container.decode(AgentStepID.self, forKey: .stepID),
                frozenSnapshotDigest: container.decode(
                    StableDigest.self,
                    forKey: .frozenSnapshotDigest
                ),
                estimator: container.decode(ContextTokenEstimatorIdentity.self, forKey: .estimator),
                budget: container.decode(ContextTokenBudget.self, forKey: .budget),
                sourceRecords: container.decode(
                    [CompiledContextSourceRecord].self,
                    forKey: .sourceRecords
                ),
                toolSchemaRecords: container.decode(
                    [CompiledToolSchemaRecord].self,
                    forKey: .toolSchemaRecords
                ),
                selectorID: container.decode(String.self, forKey: .selectorID),
                selectorPolicyVersion: container.decode(UInt32.self, forKey: .selectorPolicyVersion),
                contextPolicyVersion: container.decode(UInt32.self, forKey: .contextPolicyVersion),
                approvalPolicyVersion: container.decode(UInt32.self, forKey: .approvalPolicyVersion),
                renderedPromptDigest: container.decode(
                    StableDigest.self,
                    forKey: .renderedPromptDigest
                ),
                promptEstimatedTokens: container.decode(UInt64.self, forKey: .promptEstimatedTokens),
                toolSchemaEstimatedTokens: container.decode(
                    UInt64.self,
                    forKey: .toolSchemaEstimatedTokens
                ),
                totalEstimatedInputTokens: container.decode(
                    UInt64.self,
                    forKey: .totalEstimatedInputTokens
                )
            )
            guard manifestDigest == encodedDigest else {
                throw ContextCompilationError.integrityFailure("manifest digest")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private static func validate(
        budget: ContextTokenBudget,
        sourceRecords: [CompiledContextSourceRecord],
        toolSchemaRecords: [CompiledToolSchemaRecord],
        selectorID: String,
        selectorPolicyVersion: UInt32,
        contextPolicyVersion: UInt32,
        approvalPolicyVersion: UInt32,
        promptEstimatedTokens: UInt64,
        toolSchemaEstimatedTokens: UInt64,
        totalEstimatedInputTokens: UInt64
    ) throws {
        var adoptedPrompt: UInt64 = 0
        for record in sourceRecords {
            let addition = adoptedPrompt.addingReportingOverflow(record.adoptedEstimatedTokens)
            guard !addition.overflow else {
                throw ContextCompilationError.invalidInput("compiled prompt token overflow")
            }
            adoptedPrompt = addition.partialValue
        }
        var adoptedTools: UInt64 = 0
        for record in toolSchemaRecords {
            let addition = adoptedTools.addingReportingOverflow(record.adoptedEstimatedTokens)
            guard !addition.overflow else {
                throw ContextCompilationError.invalidInput("compiled tool token overflow")
            }
            adoptedTools = addition.partialValue
        }
        let mandatory = sourceRecords.filter {
            $0.kind == .baseSystem || $0.kind == .currentUser
        }
        guard !sourceRecords.isEmpty, sourceRecords.count <= 8_192,
              toolSchemaRecords.count <= 64,
              mandatory.count == 2,
              mandatory.allSatisfy({ $0.disposition == .included }),
              Set(sourceRecords.map { "\($0.kind.rawValue):\($0.sourceID)" }).count
                  == sourceRecords.count,
              Set(toolSchemaRecords.map(\.descriptorID)).count == toolSchemaRecords.count,
              ContextValidation.isNamespace(selectorID), selectorPolicyVersion > 0,
              contextPolicyVersion > 0, approvalPolicyVersion > 0,
              adoptedPrompt == promptEstimatedTokens,
              adoptedTools == toolSchemaEstimatedTokens,
              promptEstimatedTokens <= UInt64.max - toolSchemaEstimatedTokens,
              promptEstimatedTokens + toolSchemaEstimatedTokens == totalEstimatedInputTokens,
              toolSchemaEstimatedTokens <= budget.maximumToolSchemaTokens,
              totalEstimatedInputTokens <= budget.maximumInputTokens
        else { throw ContextCompilationError.invalidInput("compiled request manifest") }
    }

    private static func computeDigest(
        version: UInt16,
        runID: AgentRunID,
        requestID: AgentRequestID,
        stepID: AgentStepID,
        frozenSnapshotDigest: StableDigest,
        estimator: ContextTokenEstimatorIdentity,
        budget: ContextTokenBudget,
        sourceRecords: [CompiledContextSourceRecord],
        toolSchemaRecords: [CompiledToolSchemaRecord],
        selectorID: String,
        selectorPolicyVersion: UInt32,
        contextPolicyVersion: UInt32,
        approvalPolicyVersion: UInt32,
        renderedPromptDigest: StableDigest,
        promptEstimatedTokens: UInt64,
        toolSchemaEstimatedTokens: UInt64,
        totalEstimatedInputTokens: UInt64
    ) -> StableDigest {
        var components = [
            Data(String(version).utf8), Data(runID.description.utf8), Data(requestID.description.utf8),
            Data(stepID.description.utf8), Data(frozenSnapshotDigest.rawValue.utf8),
            Data(estimator.identifier.utf8), Data(String(estimator.version).utf8),
            Data(String(estimator.utf8BytesPerToken).utf8),
            Data(String(estimator.safetyMarginBasisPoints).utf8),
            Data(String(estimator.messageOverheadTokens).utf8),
            Data(String(estimator.toolSchemaOverheadTokens).utf8),
            Data(String(budget.maximumContextTokens).utf8),
            Data(String(budget.reservedOutputTokens).utf8),
            Data(String(budget.maximumToolSchemaTokens).utf8),
            Data(selectorID.utf8), Data(String(selectorPolicyVersion).utf8),
            Data(String(contextPolicyVersion).utf8), Data(String(approvalPolicyVersion).utf8),
            Data(renderedPromptDigest.rawValue.utf8), Data(String(promptEstimatedTokens).utf8),
            Data(String(toolSchemaEstimatedTokens).utf8),
            Data(String(totalEstimatedInputTokens).utf8),
        ]
        components.append(Data(String(sourceRecords.count).utf8))
        components.append(contentsOf: sourceRecords.map { Data($0.contextDigest.rawValue.utf8) })
        components.append(Data(String(toolSchemaRecords.count).utf8))
        components.append(contentsOf: toolSchemaRecords.map { Data($0.contextDigest.rawValue.utf8) })
        return StableDigest.fingerprint(domain: "compiled-request-manifest.v1", components: components)
    }

    private enum CodingKeys: String, CodingKey {
        case version, runID, requestID, stepID, frozenSnapshotDigest, estimator, budget
        case sourceRecords, toolSchemaRecords, selectorID, selectorPolicyVersion
        case contextPolicyVersion, approvalPolicyVersion, renderedPromptDigest
        case promptEstimatedTokens, toolSchemaEstimatedTokens, totalEstimatedInputTokens
        case manifestDigest
    }
}

/// Persistable compiled payload. Decoding verifies every body against its manifest.
public struct CompiledContext: Hashable, Codable, Sendable {
    public let manifest: CompiledRequestManifest
    public let messages: [AgentModelMessage]
    public let advertisedTools: [AgentToolDescriptor]
    public let renderedPrompt: String

    public init(
        manifest: CompiledRequestManifest,
        messages: [AgentModelMessage],
        advertisedTools: [AgentToolDescriptor],
        renderedPrompt: String
    ) throws {
        let rendered = ContextRendering.renderPrompt(messages)
        let estimator = DeterministicUTF8TokenEstimator(identity: manifest.estimator)
        let messageDigests = messages.map(ContextRendering.messageDigest)
        let includedSourceRecords = manifest.sourceRecords.filter { $0.disposition != .omitted }
        let expectedMessageDigests = includedSourceRecords.compactMap { record in
            record.disposition == .omitted ? nil : record.renderedMessageDigest
        }
        let expectedToolIDs = manifest.toolSchemaRecords.compactMap { record in
            record.disposition == .omitted ? nil : record.descriptorID
        }
        guard rendered == renderedPrompt,
              StableDigest.sha256(Data(renderedPrompt.utf8)) == manifest.renderedPromptDigest,
              messageDigests == expectedMessageDigests,
              zip(messages, includedSourceRecords).allSatisfy({ pair in
                  estimator.estimateMessage(pair.0) == pair.1.adoptedEstimatedTokens
              }),
              advertisedTools.map(\.id) == expectedToolIDs,
              zip(advertisedTools, manifest.toolSchemaRecords.filter { $0.disposition != .omitted })
                .allSatisfy({ pair in
                    let evidence = ContextRendering.toolEvidence(pair.0)
                    return evidence.descriptorDigest == pair.1.descriptorDigest
                        && evidence.serializedSchemaDigest == pair.1.serializedSchemaDigest
                        && pair.0.inputSchema.digest == pair.1.inputSchemaDigest
                        && pair.0.outputSchema?.digest == pair.1.outputSchemaDigest
                        && StableDigest.sha256(Data(pair.0.id.trustRevision.utf8))
                            == pair.1.trustRevisionDigest
                        && UInt64(evidence.serializedSchema.utf8.count)
                            == pair.1.serializedUTF8ByteCount
                        && estimator.estimateToolSchema(serializedSchema: evidence.serializedSchema)
                            == pair.1.adoptedEstimatedTokens
                })
        else { throw ContextCompilationError.integrityFailure("compiled context payload") }
        self.manifest = manifest
        self.messages = messages
        self.advertisedTools = advertisedTools
        self.renderedPrompt = renderedPrompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                manifest: container.decode(CompiledRequestManifest.self, forKey: .manifest),
                messages: container.decode([AgentModelMessage].self, forKey: .messages),
                advertisedTools: container.decode([AgentToolDescriptor].self, forKey: .advertisedTools),
                renderedPrompt: container.decode(String.self, forKey: .renderedPrompt)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case manifest, messages, advertisedTools, renderedPrompt }
}

extension CompiledContextSourceRecord {
    fileprivate var contextDigest: StableDigest {
        let range = selectedUTF8Range.map { "\($0.offset):\($0.length)" } ?? "none"
        return StableDigest.fingerprint(
            domain: "compiled-context-source-record.v1",
            components: [
                Data(kind.rawValue.utf8), Data(sourceID.utf8), Data(revision.utf8),
                Data(role.rawValue.utf8), Data(String(isUntrustedData).utf8),
                Data(originalContentDigest.rawValue.utf8), Data(String(originalUTF8ByteCount).utf8),
                Data(String(originalEstimatedTokens).utf8), Data(disposition.rawValue.utf8),
                Data(range.utf8), Data((selectedContentDigest?.rawValue ?? "none").utf8),
                Data((renderedMessageDigest?.rawValue ?? "none").utf8),
                Data(String(adoptedEstimatedTokens).utf8),
                Data((omissionReason?.rawValue ?? "none").utf8),
                Data((artifactID?.description ?? "none").utf8),
                Data((artifactContentDigest?.rawValue ?? "none").utf8),
                Data((toolInvocationID?.description ?? "none").utf8),
                Data((toolDescriptorID?.description ?? "none").utf8),
                Data((toolResultDigest?.rawValue ?? "none").utf8),
            ]
        )
    }
}

extension CompiledToolSchemaRecord {
    fileprivate var contextDigest: StableDigest {
        StableDigest.fingerprint(
            domain: "compiled-tool-schema-record.v1",
            components: [
                Data(descriptorID.description.utf8), Data(descriptorDigest.rawValue.utf8),
                Data(serializedSchemaDigest.rawValue.utf8), Data(inputSchemaDigest.rawValue.utf8),
                Data((outputSchemaDigest?.rawValue ?? "none").utf8),
                Data(trustRevisionDigest.rawValue.utf8), Data(String(serializedUTF8ByteCount).utf8),
                Data(String(originalEstimatedTokens).utf8), Data(disposition.rawValue.utf8),
                Data(String(adoptedEstimatedTokens).utf8),
                Data((omissionReason?.rawValue ?? "none").utf8),
            ]
        )
    }
}

enum ContextValidation {
    static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isRevision(_ value: String) -> Bool {
        isIdentifier(value) && value.utf8.count <= 256
    }

    static func isNamespace(_ value: String) -> Bool {
        guard isIdentifier(value), value.utf8.count <= 128, value.contains(".") else { return false }
        return value.unicodeScalars.allSatisfy {
            (0x61 ... 0x7A).contains($0.value) || (0x30 ... 0x39).contains($0.value)
                || $0.value == 0x2D || $0.value == 0x2E
        }
    }
}
