// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import AppRuntime
import LLMCore
import MobileLLMUI

// MARK: - Submission snapshot

/// Everything execution-defining captured synchronously on the main actor at submission time. The
/// agent runtime freezes this snapshot; it never re-reads mutable app stores during recovery.
public struct AgentRunRequestSnapshot: Sendable {
    public let conversationID: UUID
    public let userTurnID: UUID
    public let text: String
    public let imageRefs: [ImageRef]
    public let messages: [Message]
    public let systemPrompt: String
    public let memoryFacts: [MemoryFact]
    public let activeSkill: Skill?
    public let model: LLMModel
    public let variant: LLMVariant
    public let weightsDirectory: URL
    public let thinkingEnabled: Bool
    public let contextLength: Int
    public let maxTokens: Int
    public let temperature: Double
    public let topP: Double
    public let topK: Int
    public let repetitionPenalty: Double
    public let toolsEnabled: Bool
    public let localToolNames: [String]
    /// Whether the app can adapt the app-owned memory tools for this run (the MemoryBook store seam).
    public let memorySeamAvailable: Bool
    /// Whether the EventKit seam is available for calendar/reminder tools (TCC granted lazily).
    public let eventSeamAvailable: Bool
    /// Whether the CoreLocation seam is available for the location tool (TCC granted lazily).
    public let locationSeamAvailable: Bool
    /// MCP tools explicitly discovered by the user's server setup/refresh flow (spec §13: discovery
    /// never happens during prompt compilation).
    public let mcpToolDescriptors: [AgentToolDescriptor]
    /// Host-only destinations of the user's configured web-search engines (run-ceiling enumeration).
    public let webSearchDestinations: [ExternalDestination]
    /// The conversation-persistent tool policy (spec §14). App assembly snapshots the conversation's
    /// materialized policy; the runtime freezes it with the run.
    public let toolPolicy: ConversationToolPolicy?
    /// Whether the run should use the online Responses provider (Settings toggle). The provider still
    /// fails closed at generation time if the key/model are no longer configured.
    public let onlineModelEnabled: Bool
    /// Model identifier on the compatible service; nil keeps the run local even if the toggle is on.
    public let onlineModelID: String?
    /// Stable id of the active online service (approval destination scope + Keychain account).
    public let onlineServiceID: String?
    /// Immutable lookup key for the exact non-secret endpoint configuration accepted with this run.
    public let onlineConfigurationID: String?
    /// Per-service opt-in for the service's own reasoning phase (explicit user setting, not the
    /// composer toggle, which has no meaning for online providers).
    public let onlineReasoningEnabled: Bool
    /// Per-kind context window for online runs (independent of the local `contextLength`).
    public let onlineContextLength: Int
    /// Online output budget is "auto": omit the wire limit so the service uses its own model max.
    public let onlineOutputBudgetAuto: Bool
    /// The active service's declared model output ceiling (nil/0 = unknown).
    public let onlineMaximumOutputTokens: Int?
    /// Per-conversation approval mode frozen with this run.
    public let approvalMode: AgentApprovalMode
    /// Per-conversation reasoning effort (nil = service default; medium is the product default).
    public let onlineReasoningEffort: ReasoningEffort?

    public init(
        conversationID: UUID,
        userTurnID: UUID,
        text: String,
        imageRefs: [ImageRef],
        messages: [Message],
        systemPrompt: String,
        memoryFacts: [MemoryFact],
        activeSkill: Skill?,
        model: LLMModel,
        variant: LLMVariant,
        weightsDirectory: URL,
        thinkingEnabled: Bool,
        contextLength: Int,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        topK: Int,
        repetitionPenalty: Double,
        toolsEnabled: Bool,
        localToolNames: [String],
        memorySeamAvailable: Bool,
        eventSeamAvailable: Bool,
        locationSeamAvailable: Bool,
        mcpToolDescriptors: [AgentToolDescriptor],
        webSearchDestinations: [ExternalDestination],
        toolPolicy: ConversationToolPolicy?,
        onlineModelEnabled: Bool,
        onlineModelID: String?,
        onlineServiceID: String?,
        onlineConfigurationID: String?,
        onlineReasoningEnabled: Bool,
        onlineContextLength: Int,
        onlineOutputBudgetAuto: Bool,
        onlineMaximumOutputTokens: Int?,
        approvalMode: AgentApprovalMode,
        onlineReasoningEffort: ReasoningEffort?
    ) {
        self.conversationID = conversationID
        self.userTurnID = userTurnID
        self.text = text
        self.imageRefs = imageRefs
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.memoryFacts = memoryFacts
        self.activeSkill = activeSkill
        self.model = model
        self.variant = variant
        self.weightsDirectory = weightsDirectory
        self.thinkingEnabled = thinkingEnabled
        self.contextLength = contextLength
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.toolsEnabled = toolsEnabled
        self.localToolNames = localToolNames
        self.memorySeamAvailable = memorySeamAvailable
        self.eventSeamAvailable = eventSeamAvailable
        self.locationSeamAvailable = locationSeamAvailable
        self.mcpToolDescriptors = mcpToolDescriptors
        self.webSearchDestinations = webSearchDestinations
        self.toolPolicy = toolPolicy
        self.onlineModelEnabled = onlineModelEnabled
        self.onlineModelID = onlineModelID
        self.onlineServiceID = onlineServiceID
        self.onlineConfigurationID = onlineConfigurationID
        self.onlineReasoningEnabled = onlineReasoningEnabled
        self.onlineContextLength = onlineContextLength
        self.onlineOutputBudgetAuto = onlineOutputBudgetAuto
        self.onlineMaximumOutputTokens = onlineMaximumOutputTokens
        self.approvalMode = approvalMode
        self.onlineReasoningEffort = onlineReasoningEffort
    }
}

extension AgentRunRequestSnapshot {
    /// The input freezer rebuilds snapshots per request instruction; workflow children carry the
    /// same (conversation, userTurn) as their root but a different task text.
    func withText(
        _ text: String,
        maximumOutputTokens: Int? = nil,
        reasoningEnabled: Bool? = nil,
        toolsEnabled: Bool? = nil
    ) -> AgentRunRequestSnapshot {
        let resolvedToolsEnabled = toolsEnabled ?? self.toolsEnabled
        return AgentRunRequestSnapshot(
            conversationID: conversationID,
            userTurnID: userTurnID,
            text: text,
            imageRefs: imageRefs,
            messages: messages,
            systemPrompt: systemPrompt,
            memoryFacts: memoryFacts,
            activeSkill: activeSkill,
            model: model,
            variant: variant,
            weightsDirectory: weightsDirectory,
            thinkingEnabled: reasoningEnabled ?? thinkingEnabled,
            contextLength: contextLength,
            maxTokens: maximumOutputTokens ?? maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            toolsEnabled: resolvedToolsEnabled,
            localToolNames: localToolNames,
            memorySeamAvailable: memorySeamAvailable,
            eventSeamAvailable: eventSeamAvailable,
            locationSeamAvailable: locationSeamAvailable,
            mcpToolDescriptors: mcpToolDescriptors,
            webSearchDestinations: webSearchDestinations,
            // Candidate/repair generation is a pure source-compilation pass. When its caller turns
            // tools off, discard the conversation policy too; otherwise the frozen manifest could
            // still advertise policy entries from the parent even though its catalog is empty.
            toolPolicy: resolvedToolsEnabled ? toolPolicy : nil,
            onlineModelEnabled: onlineModelEnabled,
            onlineModelID: onlineModelID,
            onlineServiceID: onlineServiceID,
            onlineConfigurationID: onlineConfigurationID,
            onlineReasoningEnabled: reasoningEnabled ?? onlineReasoningEnabled,
            onlineContextLength: onlineContextLength,
            onlineOutputBudgetAuto: maximumOutputTokens == nil && onlineOutputBudgetAuto,
            onlineMaximumOutputTokens: onlineMaximumOutputTokens,
            approvalMode: approvalMode,
            onlineReasoningEffort: onlineReasoningEffort
        )
    }
}

/// The input freezer rebuilds snapshots from Settings, which would otherwise lose the workflow's
/// inherited conversation tool policy. This registry lets the assembly's snapshot closure return the
/// workflow template (the conversation's exact policy — never force-enabled, spec §2/§14/§33) for
/// every run anchored to one `/workflow` message.
@MainActor
final class AppWorkflowSnapshotRegistry {
    static let shared = AppWorkflowSnapshotRegistry()
    private var templates: [String: AgentRunRequestSnapshot] = [:]

    func removeAll() { templates.removeAll() }

    func register(conversationID: UUID, userTurnID: UUID, template: AgentRunRequestSnapshot) {
        templates[key(conversationID, userTurnID)] = template
    }

    func template(conversationID: UUID, userTurnID: UUID) -> AgentRunRequestSnapshot? {
        templates[key(conversationID, userTurnID)]
    }

    func unregister(conversationID: UUID, userTurnID: UUID) {
        templates.removeValue(forKey: key(conversationID, userTurnID))
    }

    private func key(_ conversationID: UUID, _ userTurnID: UUID) -> String {
        "\(conversationID.uuidString):\(userTurnID.uuidString)"
    }
}

// MARK: - Shared frozen-input construction

/// Shared builder used by both the request builder (submission) and the input freezer (recovery).
/// Both paths produce the exact same immutable snapshot for one request.
struct AppFrozenInputBuilder: Sendable {
    let capabilityVersion: SemanticVersion

    /// App-owned delegation marker. Root runs carry it, while every workflow child removes it.
    /// This supplies the strict authority attenuation required by the subagent boundary without
    /// arbitrarily disabling a user-selected tool capability such as MCP or Memory.
    static let workflowDelegationCapability = try! AgentCapability(
        rawValue: "workflow.delegate"
    )

    /// Stable provider identity for the online Responses API provider. The request builder, the app
    /// assembly, and the provider itself MUST derive it the same way or resolution fails.
    static let onlineProviderID = "openai.responses"
    /// Stable variant identity for the exact accepted endpoint configuration. The digest is created
    /// by the app configuration box and is safe to persist in a model selection.
    static func onlineVariantID(configurationID: String) -> String {
        "responses.config.\(configurationID)"
    }

    /// Whether the snapshot requests the online provider. Both the toggle and a non-empty model id are
    /// required; the key itself is checked later at generation time (never frozen into the run).
    static func isOnline(snapshot: AgentRunRequestSnapshot) -> Bool {
        snapshot.onlineModelEnabled
            && snapshot.onlineModelID.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ?? false
    }

    /// Stable provider identity for one exact (model, variant) registration. The request builder and
    /// the app assembly MUST derive it the same way or the runtime cannot resolve the pinned provider.
    static func providerID(model: LLMModel, variant: LLMVariant) throws -> AgentModelProviderID {
        try AgentModelProviderID(
            "local.mobilellm.\(model.id).\(variant.id.sanitizedProviderComponent)"
                .prefix(120).description
        )
    }

    /// The exact selection pinned for a run: online when the snapshot opted in, otherwise the local
    /// registration. Recovery uses the same derivation so a frozen request re-resolves identically.
    func selection(snapshot: AgentRunRequestSnapshot) throws -> AgentModelSelection {
        if Self.isOnline(snapshot: snapshot) {
            guard let modelID = snapshot.onlineModelID,
                  let configurationID = snapshot.onlineConfigurationID
            else {
                throw AgentExecutionError.internalInvariant(
                    "online snapshot missing immutable configuration identity"
                )
            }
            return try AgentModelSelection(
                providerID: AgentModelProviderID(Self.onlineProviderID),
                modelID: AgentModelID(modelID.trimmingCharacters(in: .whitespacesAndNewlines)),
                variantID: AgentModelVariantID(Self.onlineVariantID(configurationID: configurationID)),
                capabilityVersion: capabilityVersion
            )
        }
        return try registration(snapshot: snapshot).selection
    }

    func registration(
        snapshot: AgentRunRequestSnapshot
    ) throws -> LocalModelRegistration {
        try LocalModelRegistration(
            providerID: try Self.providerID(model: snapshot.model, variant: snapshot.variant),
            capabilityVersion: capabilityVersion,
            model: snapshot.model,
            variant: snapshot.variant,
            weightsDirectory: snapshot.weightsDirectory
        )
    }

    /// Finite runtime output ceiling + wire budget mode for one frozen run.
    ///
    /// Local runs always send an explicit budget. Online auto mode keeps a finite accounting
    /// ceiling (the model's declared max when known, else the conversation context window) while
    /// telling the provider to OMIT the wire limit so the service uses its own model default.
    private func outputBudget(
        snapshot: AgentRunRequestSnapshot
    ) -> (mode: AgentOutputBudgetMode, maximumOutputTokens: UInt64) {
        guard Self.isOnline(snapshot: snapshot) else {
            return (.explicit, UInt64(snapshot.maxTokens))
        }
        let context = UInt64(snapshot.onlineContextLength)
        let serviceCap = snapshot.onlineMaximumOutputTokens
            .flatMap { $0 > 0 ? UInt64($0) : nil }
            ?? context
        if snapshot.onlineOutputBudgetAuto {
            return (.auto, min(serviceCap, context))
        }
        return (.explicit, min(UInt64(snapshot.maxTokens), serviceCap, context))
    }

    func frozenInputs(
        snapshot: AgentRunRequestSnapshot,
        artifactReferences: [ArtifactReference],
        historyArtifacts: [UUID: [ArtifactReference]] = [:]
    ) throws -> FrozenAgentRunInputs {
        let online = Self.isOnline(snapshot: snapshot)
        // Online providers report their own ceilings (200k context); clamping to a local checkpoint's
        // native context would silently shorten an online run the user asked to keep long.
        let effectiveContext = online
            ? UInt64(snapshot.onlineContextLength)
            : UInt64(ContextPolicy.effective(requested: snapshot.contextLength, model: snapshot.model))
        let contextBudget = try ContextTokenBudget(
            maximumContextTokens: effectiveContext,
            reservedOutputTokens: 1_024,
            // Tool schemas are charged to this budget during context compilation; with the default
            // 1_024 tokens only ~4-5 built-ins fit and silently drop user-selected tools from the
            // model's actual tools array. Online services have large contexts and receive rich
            // schemas, so give them a generous schema budget. Local runs receive a bounded 4K
            // schema budget so a selected first-release built-in is not silently discarded.
            maximumToolSchemaTokens: online ? 16_384 : 4_096
        )
        // Online reasoning is an explicit per-service setting: `.enabled` lets the service run its own
        // thinking phase (the provider then omits the reasoning field), `.disabled` asks the service
        // to skip it for fast, deterministic replies.
        let thinkingMode: AgentModelThinkingMode = online
            ? (snapshot.onlineReasoningEnabled ? .enabled : .disabled)
            : (snapshot.thinkingEnabled ? .enabled : .disabled)
        let outputBudget = outputBudget(snapshot: snapshot)
        let generationParameters = try AgentModelGenerationParameters(
            maximumOutputTokens: outputBudget.maximumOutputTokens,
            maximumContextTokens: effectiveContext,
            temperature: snapshot.temperature,
            topP: snapshot.topP,
            topK: snapshot.topK > 0 ? UInt32(snapshot.topK) : nil,
            repetitionPenalty: snapshot.repetitionPenalty,
            thinkingMode: thinkingMode,
            seed: nil,
            outputBudgetMode: outputBudget.mode
        )

        let baseSystem = try BaseSystemContextSource(
            sourceID: "system.base",
            revision: "app.system.v1",
            content: snapshot.systemPrompt
        )
        let skills: [SkillInstructionContextSource]
        if let skill = snapshot.activeSkill {
            skills = [try SkillInstructionContextSource(
                skillID: skill.id.uuidString,
                version: "skill.v1",
                instructions: skill.instructions
            )]
        } else {
            skills = []
        }
        let memories = snapshot.memoryFacts.map {
            try? CanonicalEnglishMemoryContextSource(
                memoryID: $0.id,
                revision: String($0.revision),
                canonicalEnglishContent: $0.text
            )
        }.compactMap { $0 }
        let conversation = try snapshot.messages.compactMap { message -> ConversationTurnContextSource? in
            guard message.role != .system else { return nil }
            let role: ConversationContextRole = message.role == .user ? .user : .assistant
            return try ConversationTurnContextSource(
                messageID: MessageID(rawValue: message.id),
                revision: "message.v1",
                role: role,
                content: message.answer,
                attachments: historyArtifacts[message.id] ?? []
            )
        }
        let currentUser = try CurrentUserContextSource(
            userTurnID: UserTurnID(rawValue: snapshot.userTurnID),
            revision: "turn.v1",
            content: snapshot.text,
            attachments: artifactReferences
        )

        let localTools = snapshot.localToolNames
        let toolCatalog = try AppToolCatalog.catalog(
            enabledToolNames: snapshot.toolsEnabled ? localTools : [],
            memoryAvailable: snapshot.memorySeamAvailable,
            eventSeamAvailable: snapshot.eventSeamAvailable,
            locationSeamAvailable: snapshot.locationSeamAvailable,
            mcpDescriptors: snapshot.toolsEnabled ? snapshot.mcpToolDescriptors : []
        )
        let policy = try snapshot.toolPolicy ?? ConversationToolPolicy(
            masterEnabled: snapshot.toolsEnabled,
            allowedToolIDs: toolCatalog.descriptors.map(\.id.logicalID),
            pinnedToolIDs: [],
            selectionPolicyVersion: 1,
            materializedFromGlobalTemplate: false
        )
        // Allowed tools are the conversation's user-selected authority ceiling, not a command to
        // advertise all of them on every pass. Keep local prompts compact and let the deterministic
        // selector rank relevance; online models get a wider, still-bounded relevant subset.
        return try FrozenAgentRunInputs(
            modelSelection: try selection(snapshot: snapshot),
            generationParameters: generationParameters,
            contextBudget: contextBudget,
            baseSystem: baseSystem,
            skills: skills,
            memories: memories,
            conversation: conversation,
            currentUser: currentUser,
            toolCatalog: toolCatalog,
            toolPolicy: policy,
            // The app can execute network reads, app-local memory, and unknownExternal operations
            // behind exact-approval receipts (web/MCP).
            availableToolCapabilities: AgentCapabilitySet([
                .networkRead, .localRead, .localWrite, .unknownExternal,
            ]),
            activeSkillToolHints: [],
            explicitlyRequestedToolIDs: [],
            maximumAdvertisedTools: online ? 16 : 8,
            contextPolicyVersion: 2,
            approvalPolicyVersion: 1
        )
    }

    func request(
        snapshot: AgentRunRequestSnapshot,
        artifactReferences: [ArtifactReference],
        responseMessageID: UUID? = nil
    ) throws -> AgentRequest {
        let selection = try selection(snapshot: snapshot)
        let online = Self.isOnline(snapshot: snapshot)
        let runID = AgentRunID(rawValue: UUID())
        let effectiveContext = online
            ? UInt64(snapshot.onlineContextLength)
            : UInt64(ContextPolicy.effective(requested: snapshot.contextLength, model: snapshot.model))
        let budget = try AgentBudget.firstReleaseDefaults(
            contextTokensPerAttempt: effectiveContext,
            outputTokens: outputBudget(snapshot: snapshot).maximumOutputTokens,
            // Observed on device: the Gemma 4 E2B vision path peaks at ~1.30 GB (weights + mmproj +
            // KV + image encode), so a 1 GiB run ceiling fails settlement even though the model
            // answered correctly. 2 GiB covers every first-release curated model; it is a hard
            // per-run ceiling, not a residency admission check.
            peakMemoryBytes: 2_147_483_648
        )
        var ceilingCapabilities = AgentCapabilitySet([
            .networkRead, .localRead, .localWrite, .unknownExternal,
            Self.workflowDelegationCapability,
        ])
        var ceilingDestinations = snapshot.webSearchDestinations
        if snapshot.memorySeamAvailable {
            ceilingDestinations.append(try ExternalDestination(
                kind: .privateDataStore,
                normalizedIdentity: "mobilellm.memory"
            ))
        }
        var ceilingDataCategories = [
            try AgentDataCategory(rawValue: "web.search"),
            try AgentDataCategory(rawValue: "user.memory"),
            try AgentDataCategory(rawValue: "mcp.call"),
        ]
        if online, let modelID = snapshot.onlineModelID {
            // The online model is data egress (spec §15.1): the run ceiling must grant exactly the
            // destination the Responses provider's prepared plan names, or approval fails closed.
            ceilingCapabilities = AgentCapabilitySet([
                .externalCommunication, .networkRead, .localRead, .localWrite, .unknownExternal,
                Self.workflowDelegationCapability,
            ])
            ceilingDestinations.append(try ExternalDestination(
                kind: .modelProvider,
                normalizedIdentity: "\(AppFrozenInputBuilder.onlineProviderID):"
                    + "\(snapshot.onlineServiceID ?? ResponsesAPIConfiguration.defaultServiceID):"
                    + "\(modelID.trimmingCharacters(in: .whitespacesAndNewlines))"
            ))
            ceilingDataCategories.append(try AgentDataCategory(rawValue: "model.inference"))
        }
        let enabledTools = Set(snapshot.localToolNames)
        if enabledTools.contains("wikipedia") {
            ceilingDestinations.append(contentsOf: try ["en", "zh"].map {
                try AppWikipediaToolAdapter.destination(lang: $0)
            })
            ceilingDataCategories.append(try AgentDataCategory(rawValue: "web.wikipedia"))
        }
        if enabledTools.contains("fetch_webpage") {
            // The webpage reader reads user-supplied links: any public https host, enforced by the
            // tool's SSRF guards inside the boundary. http is never covered by this wildcard.
            ceilingDestinations.append(try ExternalDestination(
                kind: .networkEndpoint,
                normalizedIdentity: ExternalDestination.anyHTTPSNetworkEndpoint
            ))
            ceilingDataCategories.append(try AgentDataCategory(rawValue: "web.page"))
        }
        if snapshot.eventSeamAvailable {
            if enabledTools.contains("create_calendar_event")
                || enabledTools.contains("list_calendar_events")
            {
                ceilingDestinations.append(try ExternalDestination(
                    kind: .privateDataStore,
                    normalizedIdentity: "mobilellm.calendar"
                ))
                ceilingDataCategories.append(try AgentDataCategory(rawValue: "user.calendar"))
            }
            if enabledTools.contains("create_reminder") {
                ceilingDestinations.append(try ExternalDestination(
                    kind: .privateDataStore,
                    normalizedIdentity: "mobilellm.reminders"
                ))
                ceilingDataCategories.append(try AgentDataCategory(rawValue: "user.reminders"))
            }
        }
        if snapshot.locationSeamAvailable, enabledTools.contains("current_location") {
            ceilingDestinations.append(try ExternalDestination(
                kind: .privateDataStore,
                normalizedIdentity: "mobilellm.location"
            ))
            ceilingDataCategories.append(try AgentDataCategory(rawValue: "user.location"))
        }
        for descriptor in snapshot.mcpToolDescriptors {
            let providerID = descriptor.id.logicalID.providerID
            let prefix = "mcp."
            guard providerID.hasPrefix(prefix),
                  let stableID = UUID(uuidString: String(providerID.dropFirst(prefix.count)))
            else { continue }
            ceilingDestinations.append(try ExternalDestination(
                kind: .mcpServer,
                normalizedIdentity: stableID.uuidString
            ))
        }
        let ceilingAuthority = try AgentAuthorityScope(
            capabilities: ceilingCapabilities,
            destinations: ceilingDestinations,
            dataCategories: ceilingDataCategories
        )
        return try AgentRequest(
            id: AgentRequestID(rawValue: UUID()),
            runID: runID,
            conversationID: ConversationID(rawValue: snapshot.conversationID),
            userTurnID: UserTurnID(rawValue: snapshot.userTurnID),
            role: "assistant",
            instruction: snapshot.text,
            outputRequirement: .text,
            modelPolicy: AgentModelPolicy(
                localOnly: !online,
                allowedSelections: [selection],
                strategy: .pinned,
                requiredCapabilities: AgentModelCapabilitySet([])
            ),
            // The run ceiling enumerates every bounded destination the app may call (web engines,
            // app-owned memory, explicitly discovered MCP servers) and grants the matching
            // capabilities, so step plans validate against it exactly.
            capabilityCeiling: RunCapabilityCeiling(authority: ceilingAuthority),
            budget: budget,
            artifactReferences: artifactReferences,
            provenance: AgentRequestProvenance(
                source: .user,
                sourceMessageID: MessageID(rawValue: snapshot.userTurnID),
                responseMessageID: responseMessageID.map(MessageID.init(rawValue:))
            ),
            approvalMode: snapshot.approvalMode
        )
    }
}


private extension String {
    /// Lowercase namespace-safe component derived from a repo id.
    var sanitizedProviderComponent: String {
        lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            .replacingOccurrences(of: "..", with: ".")
    }
}
