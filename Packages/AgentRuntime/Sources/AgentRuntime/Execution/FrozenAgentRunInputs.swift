// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

extension FrozenAgentRunInputs {
    /// Called only when the user starts a collaboration workflow. External tool selection remains
    /// unchanged; disabled external tools are not re-enabled by adding team-local operations.
    public func addingWorkflowTools() throws -> FrozenAgentRunInputs {
        let additions = try WorkflowAgentToolOperation.allCases.map(WorkflowAgentTool.descriptor)
        let ids = additions.map(\.id.logicalID)
        let catalog = try ToolCatalogSnapshot(revision: toolCatalog.revision,
            descriptors: toolCatalog.descriptors.filter { !ids.contains($0.id.logicalID) } + additions,
            unavailable: toolCatalog.unavailable.filter { !ids.contains($0.logicalID) })
        let allowed = (toolPolicy.masterEnabled ? toolPolicy.allowedToolIDs : []) + ids
        let pinned = (toolPolicy.masterEnabled ? toolPolicy.pinnedToolIDs : []) + ids
        let policy = try ConversationToolPolicy(masterEnabled: true, allowedToolIDs: allowed, pinnedToolIDs: pinned,
            selectionPolicyVersion: toolPolicy.selectionPolicyVersion, materializedFromGlobalTemplate: false)
        return try FrozenAgentRunInputs(modelSelection: modelSelection, generationParameters: generationParameters,
            contextBudget: contextBudget, baseSystem: baseSystem, skills: skills, memories: memories,
            conversation: conversation, currentUser: currentUser, artifactExcerpts: artifactExcerpts,
            toolCatalog: catalog, toolPolicy: policy, availableToolCapabilities: availableToolCapabilities,
            activeSkillToolHints: activeSkillToolHints, explicitlyRequestedToolIDs: explicitlyRequestedToolIDs,
            recentSuccessfulToolChain: recentSuccessfulToolChain, maximumAdvertisedTools: maximumAdvertisedTools,
            contextPolicyVersion: contextPolicyVersion, approvalPolicyVersion: approvalPolicyVersion,
            suppressModelTools: suppressModelTools ?? false)
    }

    func replacingConversation(_ conversation: [ConversationTurnContextSource],
                               currentUser: CurrentUserContextSource) throws -> FrozenAgentRunInputs {
        try FrozenAgentRunInputs(modelSelection: modelSelection, generationParameters: generationParameters,
            contextBudget: contextBudget, baseSystem: baseSystem, skills: skills, memories: memories,
            conversation: conversation, currentUser: currentUser, artifactExcerpts: artifactExcerpts,
            toolCatalog: toolCatalog, toolPolicy: toolPolicy, availableToolCapabilities: availableToolCapabilities,
            activeSkillToolHints: activeSkillToolHints, explicitlyRequestedToolIDs: explicitlyRequestedToolIDs,
            recentSuccessfulToolChain: recentSuccessfulToolChain, maximumAdvertisedTools: maximumAdvertisedTools,
            contextPolicyVersion: contextPolicyVersion, approvalPolicyVersion: approvalPolicyVersion,
            suppressModelTools: suppressModelTools ?? false)
    }
}

/// Complete execution-defining input frozen before the first model pass.
///
/// It deliberately contains exact model/tool revisions and already-frozen context bodies. Recovery
/// decodes this value from the run-input artifact; it never rebuilds it from mutable app stores.
public struct FrozenAgentRunInputs: Hashable, Codable, Sendable {
    public static let formatVersion: UInt16 = 1

    public let version: UInt16
    public let modelSelection: AgentModelSelection
    public let generationParameters: AgentModelGenerationParameters
    public let contextBudget: ContextTokenBudget
    public let baseSystem: BaseSystemContextSource
    public let skills: [SkillInstructionContextSource]
    public let memories: [CanonicalEnglishMemoryContextSource]
    public let conversation: [ConversationTurnContextSource]
    public let currentUser: CurrentUserContextSource
    public let artifactExcerpts: [ArtifactExcerptContextSource]
    public let toolCatalog: ToolCatalogSnapshot
    public let toolPolicy: ConversationToolPolicy
    public let availableToolCapabilities: AgentCapabilitySet
    public let activeSkillToolHints: [AgentToolLogicalID]
    public let explicitlyRequestedToolIDs: [AgentToolLogicalID]
    public let recentSuccessfulToolChain: [AgentToolLogicalID]
    public let maximumAdvertisedTools: UInt16
    public let contextPolicyVersion: UInt32
    public let approvalPolicyVersion: UInt32
    /// Suppresses tools for this model run while retaining the user's frozen catalog/policy for
    /// delegated work. Omitted on ordinary runs for backward-compatible persisted snapshots.
    public let suppressModelTools: Bool?

    public init(
        modelSelection: AgentModelSelection,
        generationParameters: AgentModelGenerationParameters,
        contextBudget: ContextTokenBudget,
        baseSystem: BaseSystemContextSource,
        skills: [SkillInstructionContextSource] = [],
        memories: [CanonicalEnglishMemoryContextSource] = [],
        conversation: [ConversationTurnContextSource] = [],
        currentUser: CurrentUserContextSource,
        artifactExcerpts: [ArtifactExcerptContextSource] = [],
        toolCatalog: ToolCatalogSnapshot,
        toolPolicy: ConversationToolPolicy,
        availableToolCapabilities: AgentCapabilitySet,
        activeSkillToolHints: some Sequence<AgentToolLogicalID> = [],
        explicitlyRequestedToolIDs: some Sequence<AgentToolLogicalID> = [],
        recentSuccessfulToolChain: [AgentToolLogicalID] = [],
        maximumAdvertisedTools: UInt16 = 8,
        contextPolicyVersion: UInt32,
        approvalPolicyVersion: UInt32,
        suppressModelTools: Bool = false
    ) throws {
        let hints = Array(Set(activeSkillToolHints)).sorted()
        let explicit = Array(Set(explicitlyRequestedToolIDs)).sorted()
        guard maximumAdvertisedTools > 0,
              maximumAdvertisedTools <= 64,
              contextPolicyVersion > 0,
              approvalPolicyVersion > 0,
              currentUser.attachments.count <= 64,
              Set(recentSuccessfulToolChain).count == recentSuccessfulToolChain.count
        else { throw AgentExecutionError.internalInvariant("invalid frozen run inputs") }
        version = Self.formatVersion
        self.modelSelection = modelSelection
        self.generationParameters = generationParameters
        self.contextBudget = contextBudget
        self.baseSystem = baseSystem
        self.skills = skills
        self.memories = memories
        self.conversation = conversation
        self.currentUser = currentUser
        self.artifactExcerpts = artifactExcerpts
        self.toolCatalog = toolCatalog
        self.toolPolicy = toolPolicy
        self.availableToolCapabilities = availableToolCapabilities
        self.activeSkillToolHints = hints
        self.explicitlyRequestedToolIDs = explicit
        self.recentSuccessfulToolChain = recentSuccessfulToolChain
        self.maximumAdvertisedTools = maximumAdvertisedTools
        self.contextPolicyVersion = contextPolicyVersion
        self.approvalPolicyVersion = approvalPolicyVersion
        self.suppressModelTools = suppressModelTools ? true : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt16.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "unsupported frozen run input version"
            )
        }
        do {
            try self.init(
                modelSelection: container.decode(AgentModelSelection.self, forKey: .modelSelection),
                generationParameters: container.decode(
                    AgentModelGenerationParameters.self,
                    forKey: .generationParameters
                ),
                contextBudget: container.decode(ContextTokenBudget.self, forKey: .contextBudget),
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
                artifactExcerpts: container.decode(
                    [ArtifactExcerptContextSource].self,
                    forKey: .artifactExcerpts
                ),
                toolCatalog: container.decode(ToolCatalogSnapshot.self, forKey: .toolCatalog),
                toolPolicy: container.decode(ConversationToolPolicy.self, forKey: .toolPolicy),
                availableToolCapabilities: container.decode(
                    AgentCapabilitySet.self,
                    forKey: .availableToolCapabilities
                ),
                activeSkillToolHints: container.decode(
                    [AgentToolLogicalID].self,
                    forKey: .activeSkillToolHints
                ),
                explicitlyRequestedToolIDs: container.decode(
                    [AgentToolLogicalID].self,
                    forKey: .explicitlyRequestedToolIDs
                ),
                recentSuccessfulToolChain: container.decode(
                    [AgentToolLogicalID].self,
                    forKey: .recentSuccessfulToolChain
                ),
                maximumAdvertisedTools: container.decode(
                    UInt16.self,
                    forKey: .maximumAdvertisedTools
                ),
                contextPolicyVersion: container.decode(
                    UInt32.self,
                    forKey: .contextPolicyVersion
                ),
                approvalPolicyVersion: container.decode(
                    UInt32.self,
                    forKey: .approvalPolicyVersion
                ),
                suppressModelTools: container.decodeIfPresent(Bool.self, forKey: .suppressModelTools) ?? false
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, modelSelection, generationParameters, contextBudget, baseSystem, skills
        case memories, conversation, currentUser, artifactExcerpts, toolCatalog, toolPolicy
        case availableToolCapabilities, activeSkillToolHints, explicitlyRequestedToolIDs
        case recentSuccessfulToolChain, maximumAdvertisedTools, contextPolicyVersion
        case approvalPolicyVersion, suppressModelTools
    }

    func selectedTools(latestUserRequest: String) throws -> ToolSelectionResult {
        let policy: ConversationToolPolicy
        if suppressModelTools == true {
            policy = try ConversationToolPolicy(masterEnabled: false,
                allowedToolIDs: toolPolicy.allowedToolIDs, pinnedToolIDs: toolPolicy.pinnedToolIDs,
                selectionPolicyVersion: toolPolicy.selectionPolicyVersion,
                materializedFromGlobalTemplate: toolPolicy.materializedFromGlobalTemplate)
        } else { policy = toolPolicy }
        return try DeterministicToolSelector().select(
            ToolSelectionInput(
                policy: policy,
                catalog: toolCatalog,
                availableCapabilities: availableToolCapabilities,
                latestUserRequest: latestUserRequest,
                attachmentMIMETypes: currentUser.attachments.map(\.mimeType),
                activeSkillToolHints: activeSkillToolHints,
                recentSuccessfulToolChain: recentSuccessfulToolChain,
                explicitlyRequestedToolIDs: explicitlyRequestedToolIDs,
                maximumAdvertisedTools: maximumAdvertisedTools
            )
        )
    }
}

/// Simple immutable freezer useful for app composition after app-owned stores have already been
/// snapshotted, and for deterministic integration tests.
public struct StaticAgentRunInputFreezer: AgentRunInputFreezing, Sendable {
    public let inputs: FrozenAgentRunInputs

    public init(inputs: FrozenAgentRunInputs) { self.inputs = inputs }

    public func freeze(_ request: AgentRequest) async throws -> FrozenAgentRunInputs {
        guard request.modelPolicy.allowedSelections.contains(inputs.modelSelection),
              request.userTurnID.description == inputs.currentUser.frozen.sourceID,
              request.artifactReferences == inputs.currentUser.attachments
        else { throw AgentExecutionError.internalInvariant("frozen input does not match request") }
        return inputs
    }
}
