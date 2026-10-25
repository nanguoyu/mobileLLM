// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

extension FrozenAgentRunInputs {
    /// Collaboration exposes only its scoped internal operations. Disabled external tools stay off.
    public func addingWorkflowTools(availableSkills: [WorkflowSkillDefinition] = []) throws -> FrozenAgentRunInputs {
        let operations = WorkflowAgentToolOperation.allCases.filter { !availableSkills.isEmpty || !$0.isSkillOperation }
        let additions = try operations.map { try WorkflowAgentTool.descriptor($0) }
        let ids = additions.map(\.id.logicalID)
        let catalog = try ToolCatalogSnapshot(revision: toolCatalog.revision,
            descriptors: toolCatalog.descriptors.filter { $0.id.logicalID.providerID != "agent" } + additions,
            unavailable: toolCatalog.unavailable.filter { $0.logicalID.providerID != "agent" })
        let allowed = (toolPolicy.masterEnabled ? toolPolicy.allowedToolIDs.filter { $0.providerID != "agent" } : []) + ids
        let pinned = (toolPolicy.masterEnabled ? toolPolicy.pinnedToolIDs.filter { $0.providerID != "agent" } : []) + ids
        let policy = try ConversationToolPolicy(masterEnabled: true, allowedToolIDs: allowed, pinnedToolIDs: pinned,
            selectionPolicyVersion: toolPolicy.selectionPolicyVersion, materializedFromGlobalTemplate: false)
        return try replacing(toolCatalog: catalog, toolPolicy: policy,
            contextPolicyVersion: 3, skillCatalog: availableSkills,
            availableToolCapabilities: AgentCapabilitySet(availableToolCapabilities.values + [.localRead, .agentMessage]))
    }

    public func applying(profile: WorkflowAgentProfileV1?, online: Bool) throws -> FrozenAgentRunInputs {
        guard let profile else { return self }
        var policy = toolPolicy
        if !profile.toolNames.isEmpty {
            var allowed: [AgentToolLogicalID] = []
            for name in profile.toolNames {
                let matches = toolPolicy.allowedToolIDs.filter { $0.description == name || $0.providerID + "." + $0.name == name }
                guard toolPolicy.masterEnabled, matches.count == 1, let id = matches.first,
                      toolCatalog.descriptor(for: id) != nil else { throw WorkflowAgentProfileError.unavailableTool(name) }
                allowed.append(id)
            }
            policy = try ConversationToolPolicy(masterEnabled: true, allowedToolIDs: allowed,
                pinnedToolIDs: toolPolicy.pinnedToolIDs.filter { allowed.contains($0) },
                selectionPolicyVersion: toolPolicy.selectionPolicyVersion, materializedFromGlobalTemplate: false)
        }
        var selectedSkills = skills
        for id in profile.skillIDs {
            if selectedSkills.contains(where: { $0.frozen.sourceID.caseInsensitiveCompare(id) == .orderedSame }) { continue }
            let matches = (skillCatalog ?? []).filter { $0.id.caseInsensitiveCompare(id) == .orderedSame || $0.name == id }
            guard matches.count == 1, let skill = matches.first else { throw WorkflowAgentProfileError.unavailableSkill(id) }
            if !selectedSkills.contains(where: { $0.frozen.sourceID == skill.id }) {
                selectedSkills.append(try SkillInstructionContextSource(skillID: skill.id, version: skill.digest.rawValue, instructions: skill.instructions))
            }
        }
        var generation = generationParameters
        if let effort = profile.reasoningEffort {
            guard online, generation.thinkingMode != .disabled,
                  generation.reasoningEffort.map({ effort <= $0 }) ?? true else { throw WorkflowAgentProfileError.reasoningCeiling }
            generation = try AgentModelGenerationParameters(maximumOutputTokens: generation.maximumOutputTokens,
                maximumContextTokens: generation.maximumContextTokens, temperature: generation.temperature, topP: generation.topP,
                topK: generation.topK, repetitionPenalty: generation.repetitionPenalty, thinkingMode: .enabled,
                seed: generation.seed, outputBudgetMode: generation.outputBudgetMode, reasoningEffort: effort)
        }
        return try replacing(generationParameters: generation, skills: selectedSkills, toolPolicy: policy)
    }

    func replacingConversation(_ conversation: [ConversationTurnContextSource], currentUser: CurrentUserContextSource,
                               maximumHistoryBytes: Int = 131_072, maximumHistoryTurns: Int = 24) throws -> FrozenAgentRunInputs {
        let retained = AgentSessionContextWindow.retain(conversation, maximumBytes: maximumHistoryBytes, maximumTurns: maximumHistoryTurns)
        var system = baseSystem
        if !conversation.isEmpty && !baseSystem.frozen.content.contains(AgentSessionContextWindow.marker) {
            system = try BaseSystemContextSource(sourceID: baseSystem.frozen.sourceID,
                revision: baseSystem.frozen.revision + ".session-window.v1",
                content: baseSystem.frozen.content + "\n\n" + AgentSessionContextWindow.notice)
        }
        return try replacing(baseSystem: system, conversation: retained, currentUser: currentUser)
    }

    private func replacing(generationParameters: AgentModelGenerationParameters? = nil,
                           baseSystem: BaseSystemContextSource? = nil, skills: [SkillInstructionContextSource]? = nil,
                           conversation: [ConversationTurnContextSource]? = nil, currentUser: CurrentUserContextSource? = nil,
                           toolCatalog: ToolCatalogSnapshot? = nil, toolPolicy: ConversationToolPolicy? = nil,
                           contextPolicyVersion: UInt32? = nil, skillCatalog: [WorkflowSkillDefinition]? = nil,
                           availableToolCapabilities: AgentCapabilitySet? = nil) throws -> FrozenAgentRunInputs {
        try FrozenAgentRunInputs(modelSelection: modelSelection, generationParameters: generationParameters ?? self.generationParameters,
            contextBudget: contextBudget, baseSystem: baseSystem ?? self.baseSystem, skills: skills ?? self.skills, memories: memories,
            conversation: conversation ?? self.conversation, currentUser: currentUser ?? self.currentUser, artifactExcerpts: artifactExcerpts,
            toolCatalog: toolCatalog ?? self.toolCatalog, toolPolicy: toolPolicy ?? self.toolPolicy, availableToolCapabilities: availableToolCapabilities ?? self.availableToolCapabilities,
            activeSkillToolHints: activeSkillToolHints, explicitlyRequestedToolIDs: explicitlyRequestedToolIDs,
            recentSuccessfulToolChain: recentSuccessfulToolChain, maximumAdvertisedTools: maximumAdvertisedTools,
            contextPolicyVersion: contextPolicyVersion ?? self.contextPolicyVersion, approvalPolicyVersion: approvalPolicyVersion,
            suppressModelTools: suppressModelTools ?? false, skillCatalog: skillCatalog ?? self.skillCatalog ?? [])
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
    public let skillCatalog: [WorkflowSkillDefinition]?

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
        suppressModelTools: Bool = false,
        skillCatalog: [WorkflowSkillDefinition] = []
    ) throws {
        let hints = Array(Set(activeSkillToolHints)).sorted()
        let explicit = Array(Set(explicitlyRequestedToolIDs)).sorted()
        guard maximumAdvertisedTools > 0,
              maximumAdvertisedTools <= 64,
              contextPolicyVersion > 0,
              approvalPolicyVersion > 0,
              currentUser.attachments.count <= 64,
              Set(recentSuccessfulToolChain).count == recentSuccessfulToolChain.count,
              skillCatalog.count <= 32, Set(skillCatalog.map(\.id)).count == skillCatalog.count,
              skillCatalog.reduce(0, { $0 + $1.instructions.utf8.count }) <= 1_048_576
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
        self.skillCatalog = skillCatalog.isEmpty ? nil : skillCatalog
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
                suppressModelTools: container.decodeIfPresent(Bool.self, forKey: .suppressModelTools) ?? false,
                skillCatalog: container.decodeIfPresent([WorkflowSkillDefinition].self, forKey: .skillCatalog) ?? []
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
        case approvalPolicyVersion, suppressModelTools, skillCatalog
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
