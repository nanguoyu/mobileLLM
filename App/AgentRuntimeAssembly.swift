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
@MainActor
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
        onlineModelID: String?
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
    }
}

// MARK: - Shared frozen-input construction

/// Shared builder used by both the request builder (submission) and the input freezer (recovery).
/// Both paths produce the exact same immutable snapshot for one request.
struct AppFrozenInputBuilder: Sendable {
    let capabilityVersion: SemanticVersion

    /// Stable provider identity for the online Responses API provider. The request builder, the app
    /// assembly, and the provider itself MUST derive it the same way or resolution fails.
    static let onlineProviderID = "openai.responses"
    /// Stable variant identity for the online selection (the service model id is the real identity).
    static let onlineVariantID = "responses.default"

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
        if Self.isOnline(snapshot: snapshot), let modelID = snapshot.onlineModelID {
            return try AgentModelSelection(
                providerID: AgentModelProviderID(Self.onlineProviderID),
                modelID: AgentModelID(modelID.trimmingCharacters(in: .whitespacesAndNewlines)),
                variantID: AgentModelVariantID(Self.onlineVariantID),
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

    func frozenInputs(
        snapshot: AgentRunRequestSnapshot,
        artifactReferences: [ArtifactReference],
        historyArtifacts: [UUID: [ArtifactReference]] = [:]
    ) throws -> FrozenAgentRunInputs {
        let online = Self.isOnline(snapshot: snapshot)
        // Online providers report their own ceilings (200k context); clamping to a local checkpoint's
        // native context would silently shorten an online run the user asked to keep long.
        let effectiveContext = online
            ? UInt64(snapshot.contextLength)
            : UInt64(ContextPolicy.effective(requested: snapshot.contextLength, model: snapshot.model))
        let contextBudget = try ContextTokenBudget(
            maximumContextTokens: effectiveContext,
            reservedOutputTokens: 1_024,
            maximumToolSchemaTokens: 1_024
        )
        // Online providers never advertise `.reasoning` (compatible gateways decide internally), so an
        // explicit `.enabled` request would fail capability validation. `.automatic` lets the provider
        // keep its default while still honoring an explicit user "off".
        let thinkingMode: AgentModelThinkingMode = online
            ? (snapshot.thinkingEnabled ? .automatic : .disabled)
            : (snapshot.thinkingEnabled ? .enabled : .disabled)
        let generationParameters = try AgentModelGenerationParameters(
            maximumOutputTokens: UInt64(snapshot.maxTokens),
            maximumContextTokens: effectiveContext,
            temperature: snapshot.temperature,
            topP: snapshot.topP,
            topK: snapshot.topK > 0 ? UInt32(snapshot.topK) : nil,
            repetitionPenalty: snapshot.repetitionPenalty,
            thinkingMode: thinkingMode,
            seed: nil
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
            pinnedToolIDs: toolCatalog.descriptors.map(\.id.logicalID),
            selectionPolicyVersion: 1,
            materializedFromGlobalTemplate: false
        )
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
            explicitlyRequestedToolIDs: toolCatalog.descriptors.map(\.id.logicalID),
            maximumAdvertisedTools: 8,
            contextPolicyVersion: 1,
            approvalPolicyVersion: 1
        )
    }

    func request(
        snapshot: AgentRunRequestSnapshot,
        artifactReferences: [ArtifactReference]
    ) throws -> AgentRequest {
        let selection = try selection(snapshot: snapshot)
        let online = Self.isOnline(snapshot: snapshot)
        let runID = AgentRunID(rawValue: UUID())
        let effectiveContext = online
            ? UInt64(snapshot.contextLength)
            : UInt64(ContextPolicy.effective(requested: snapshot.contextLength, model: snapshot.model))
        let budget = try AgentBudget.firstReleaseDefaults(
            contextTokensPerAttempt: effectiveContext,
            outputTokens: UInt64(snapshot.maxTokens),
            // Observed on device: the Gemma 4 E2B vision path peaks at ~1.30 GB (weights + mmproj +
            // KV + image encode), so a 1 GiB run ceiling fails settlement even though the model
            // answered correctly. 2 GiB covers every first-release curated model; it is a hard
            // per-run ceiling, not a residency admission check.
            peakMemoryBytes: 2_147_483_648
        )
        var ceilingCapabilities = AgentCapabilitySet([.networkRead, .localRead, .localWrite, .unknownExternal])
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
            ])
            ceilingDestinations.append(try ExternalDestination(
                kind: .modelProvider,
                normalizedIdentity: "\(AppFrozenInputBuilder.onlineProviderID):\(modelID.trimmingCharacters(in: .whitespacesAndNewlines))"
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
            provenance: AgentRequestProvenance(source: .user)
        )
    }
}

// MARK: - Attachment resolver

/// Pre-authorized attachment bytes keyed by the artifact id the submission committed. The local model
/// provider verifies byte count and SHA-256 before handing bytes to the engine.
actor AppAttachmentResolver: LocalModelArtifactBytesResolving {
    private let store: ContentAddressedArtifactStore
    private var references: [ArtifactID: ArtifactReference] = [:]

    init(store: ContentAddressedArtifactStore) {
        self.store = store
    }

    func store(_ reference: ArtifactReference) {
        references[reference.id] = reference
    }

    func preauthorizedBytes(for reference: ArtifactReference) async throws -> Data {
        // Keep only the reference in memory; read the bytes from the content-addressed store on
        // demand. Retaining every image's Data across multi-turn runs doubled each image in RAM and
        // contributed to device memory pressure on the vision path.
        guard references[reference.id] == reference else {
            throw LocalModelAdapterError.artifactUnavailable(reference.id)
        }
        return try await store.data(for: reference.id, maximumBytes: reference.byteCount)
    }
}

/// Commits app-owned attachment bytes into the content-addressed artifact store and preloads them for
/// the local model provider. Used for BOTH the current turn's images and the history replay: a
/// follow-up turn must see the earlier user message's pixels again, so each run resolves every user
/// attachment still referenced by the conversation.
struct AppAgentArtifactResolver: Sendable {
    let artifactStore: ContentAddressedArtifactStore
    let attachmentResolver: AppAttachmentResolver
    let attachmentDirectory: URL

    func resolveCurrent(
        _ imageRefs: [ImageRef],
        conversationID: UUID
    ) async throws -> [ArtifactReference] {
        var references: [ArtifactReference] = []
        for image in imageRefs {
            references.append(try await commit(image, conversationID: conversationID))
        }
        return references
    }

    func resolveHistory(
        in snapshot: AgentRunRequestSnapshot,
        excluding userTurnID: UUID
    ) async throws -> [UUID: [ArtifactReference]] {
        var resolved: [UUID: [ArtifactReference]] = [:]
        for message in snapshot.messages where message.role == .user {
            guard message.id != userTurnID, let refs = message.attachments, !refs.isEmpty else {
                continue
            }
            var artifacts: [ArtifactReference] = []
            for image in refs {
                let url = attachmentDirectory.appending(component: image.fileName)
                // A purged/deleted attachment falls back to text-only history; the conversation UI
                // already removes the ref alongside the bytes, so this is a recovery safety net.
                guard let data = try? Data(contentsOf: url) else { continue }
                artifacts.append(try await commit(image, conversationID: snapshot.conversationID, data: data))
            }
            if !artifacts.isEmpty { resolved[message.id] = artifacts }
        }
        return resolved
    }

    private func commit(
        _ image: ImageRef,
        conversationID: UUID,
        data: Data? = nil
    ) async throws -> ArtifactReference {
        let url = attachmentDirectory.appending(component: image.fileName)
        let bytes = try data ?? Data(contentsOf: url)
        let runID = AgentRunID(rawValue: UUID())
        let committed = try await artifactStore.commit(
            ArtifactCommitRequest(
                data: bytes,
                mimeType: "image/jpeg",
                semanticType: "user-image",
                provenance: ArtifactProvenance(
                    runID: runID,
                    providerID: "mobilellm.app-attachments"
                ),
                retentionPolicy: .conversation,
                sensitivity: .personalData,
                initialOwner: .conversation(ConversationID(rawValue: conversationID))
            )
        )
        await attachmentResolver.store(committed)
        return committed
    }
}

// MARK: - Tool catalog

/// The app's Tool V2 catalog: every built-in the UI can enable has a Tool V2 adapter, so the agent
/// runtime advertises exactly what it can execute. Network tools (web search, Wikipedia, webpage
/// reading) cross approved network boundaries; memory/calendar/reminders/location cross private-data
/// boundaries gated on their app seams; MCP tools come from explicit discovery.
final class AppToolCatalog: ExecutableToolCatalog, @unchecked Sendable {
    static let adaptedToolNames = AppLocalToolIDs.names

    let snapshot: ToolCatalogSnapshot
    let adapters: [AgentToolDescriptorID: any ToolV2]
    private let mcpCache: MCPDiscoveryCache

    static func catalog(
        enabledToolNames: [String],
        memoryAvailable: Bool,
        eventSeamAvailable: Bool,
        locationSeamAvailable: Bool,
        mcpDescriptors: [AgentToolDescriptor] = [],
        trustRevision: String = "builtin.v1"
    ) throws -> ToolCatalogSnapshot {
        let builtIns = ToolRegistry.standard.tools
        var descriptors: [AgentToolDescriptor] = []
        var unavailable: [UnavailableTool] = []
        for tool in builtIns {
            let logicalID = try AgentToolLogicalID(providerID: "builtin", name: tool.schema.name)
            let enabled = enabledToolNames.contains(tool.schema.name)
            let seamMissing = (tool.schema.name == "remember" || tool.schema.name == "recall")
                && !memoryAvailable
            if Self.adaptedToolNames.contains(tool.schema.name), enabled, !seamMissing
            {
                let inputSchema = try AppToolV2Support.inputSchema(for: tool.schema)
                descriptors.append(try AgentToolDescriptor(
                    id: AgentToolDescriptorID(
                        logicalID: logicalID,
                        version: SemanticVersion("1.0.0")!,
                        schemaDigest: inputSchema.digest,
                        trustRevision: trustRevision
                    ),
                    title: tool.schema.name,
                    summary: tool.schema.description,
                    inputSchema: inputSchema,
                    outputSchema: nil,
                    effects: Self.effects(for: tool.schema.name),
                    requiredCapabilities: Self.requiredCapabilities(for: tool.schema.name),
                    timeoutPolicy: ToolTimeoutPolicy(
                        maximumMilliseconds: Self.timeoutMilliseconds(for: tool.schema.name)
                    ),
                    retryPolicy: .never,
                    idempotency: Self.idempotency(for: tool.schema.name),
                    supportsProgress: false,
                    supportsCancellation: true
                ))
            } else {
                unavailable.append(
                    UnavailableTool(
                        logicalID: logicalID,
                        reason: .providerUnavailable
                    )
                )
            }
        }
        // Memory tools are opt-in seams and therefore absent from `ToolRegistry.standard`; the frozen
        // catalog must advertise them explicitly or the selector reports `descriptorMissing` for a
        // perfectly valid `remember`/`recall` call (the executor adapters exist, the descriptors did not).
        for (name, schema) in [("remember", RememberTool.schema), ("recall", RecallTool.schema)] {
            let logicalID = try AgentToolLogicalID(providerID: "builtin", name: name)
            if enabledToolNames.contains(name), memoryAvailable {
                let inputSchema = try AppToolV2Support.inputSchema(for: schema)
                descriptors.append(try AgentToolDescriptor(
                    id: AgentToolDescriptorID(
                        logicalID: logicalID,
                        version: SemanticVersion("1.0.0")!,
                        schemaDigest: inputSchema.digest,
                        trustRevision: trustRevision
                    ),
                    title: schema.name,
                    summary: schema.description,
                    inputSchema: inputSchema,
                    outputSchema: nil,
                    effects: Self.effects(for: name),
                    requiredCapabilities: Self.requiredCapabilities(for: name),
                    timeoutPolicy: ToolTimeoutPolicy(
                        maximumMilliseconds: Self.timeoutMilliseconds(for: name)
                    ),
                    retryPolicy: .never,
                    idempotency: Self.idempotency(for: name),
                    supportsProgress: false,
                    supportsCancellation: true
                ))
            } else {
                unavailable.append(
                    UnavailableTool(
                        logicalID: logicalID,
                        reason: .providerUnavailable
                    )
                )
            }
        }
        // Calendar, reminders and location are also opt-in system seams (EventKit / CoreLocation),
        // absent from `ToolRegistry.standard`; advertise them exactly when their seam is available.
        let systemDataTools: [(name: String, schema: ToolSchema, seam: Bool)] = [
            ("create_calendar_event", CreateCalendarEventTool.schema, eventSeamAvailable),
            ("list_calendar_events", ListCalendarEventsTool.schema, eventSeamAvailable),
            ("create_reminder", CreateReminderTool.schema, eventSeamAvailable),
            ("current_location", CurrentLocationTool.schema, locationSeamAvailable),
        ]
        for entry in systemDataTools {
            let logicalID = try AgentToolLogicalID(providerID: "builtin", name: entry.name)
            if enabledToolNames.contains(entry.name), entry.seam {
                let inputSchema = try AppToolV2Support.inputSchema(for: entry.schema)
                descriptors.append(try AgentToolDescriptor(
                    id: AgentToolDescriptorID(
                        logicalID: logicalID,
                        version: SemanticVersion("1.0.0")!,
                        schemaDigest: inputSchema.digest,
                        trustRevision: trustRevision
                    ),
                    title: entry.schema.name,
                    summary: entry.schema.description,
                    inputSchema: inputSchema,
                    outputSchema: nil,
                    effects: Self.effects(for: entry.name),
                    requiredCapabilities: Self.requiredCapabilities(for: entry.name),
                    timeoutPolicy: ToolTimeoutPolicy(
                        maximumMilliseconds: Self.timeoutMilliseconds(for: entry.name)
                    ),
                    retryPolicy: .never,
                    idempotency: Self.idempotency(for: entry.name),
                    supportsProgress: false,
                    supportsCancellation: true
                ))
            } else {
                unavailable.append(
                    UnavailableTool(
                        logicalID: logicalID,
                        reason: .providerUnavailable
                    )
                )
            }
        }
        descriptors.append(contentsOf: mcpDescriptors.sorted { $0.id.description < $1.id.description })
        return try ToolCatalogSnapshot(
            revision: 1,
            descriptors: descriptors,
            unavailable: unavailable
        )
    }

    init(
        enabledToolNames: [String],
        memoryStore: (any MemoryStoring)?,
        eventStore: (any EventStoring)?,
        locationProvider: (any LocationProviding)?,
        mcpCache: MCPDiscoveryCache,
        session: URLSession = .shared
    ) throws {
        let enabled = Set(enabledToolNames)
        var adapters: [AgentToolDescriptorID: any ToolV2] = [:]
        func register(_ adapter: any ToolV2) {
            adapters[adapter.descriptor.id] = adapter
        }
        if enabled.contains("calculator") {
            try register(LegacyLocalToolAdapter(
                tool: CalculatorTool(),
                providerID: "builtin",
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("current_datetime") {
            try register(LegacyLocalToolAdapter(
                tool: DateTimeTool(),
                providerID: "builtin",
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("web_search") {
            try register(AppWebSearchToolAdapter(
                tool: WebSearchTool(session: session),
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("wikipedia") {
            try register(AppWikipediaToolAdapter(
                tool: WikipediaTool(session: session),
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("fetch_webpage") {
            try register(AppWebScraperToolAdapter(
                tool: WebScraperTool(session: session),
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("create_calendar_event"), let eventStore {
            try register(AppSystemDataToolAdapter(
                tool: CreateCalendarEventTool(store: eventStore),
                effects: [.localWrite],
                destinationIdentity: "mobilellm.calendar",
                dataCategory: "user.calendar",
                userPreview: "Add an event to the user's calendar",
                trustRevision: "builtin.v1",
                timeoutMilliseconds: 5_000
            ))
        }
        if enabled.contains("list_calendar_events"), let eventStore {
            try register(AppSystemDataToolAdapter(
                tool: ListCalendarEventsTool(store: eventStore),
                effects: [.localRead],
                destinationIdentity: "mobilellm.calendar",
                dataCategory: "user.calendar",
                userPreview: "List the user's upcoming calendar events",
                trustRevision: "builtin.v1",
                timeoutMilliseconds: 5_000
            ))
        }
        if enabled.contains("create_reminder"), let eventStore {
            try register(AppSystemDataToolAdapter(
                tool: CreateReminderTool(store: eventStore),
                effects: [.localWrite],
                destinationIdentity: "mobilellm.reminders",
                dataCategory: "user.reminders",
                userPreview: "Create a reminder for the user",
                trustRevision: "builtin.v1",
                timeoutMilliseconds: 5_000
            ))
        }
        if enabled.contains("current_location"), let locationProvider {
            try register(AppSystemDataToolAdapter(
                tool: CurrentLocationTool(provider: locationProvider),
                effects: [.localRead],
                destinationIdentity: "mobilellm.location",
                dataCategory: "user.location",
                userPreview: "Get the user's approximate current location",
                trustRevision: "builtin.v1",
                timeoutMilliseconds: 15_000
            ))
        }
        if enabled.contains("remember"), let memoryStore {
            try register(AppMemoryToolAdapter(
                tool: RememberTool(store: memoryStore),
                effects: [.localWrite],
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("recall"), let memoryStore {
            try register(AppMemoryToolAdapter(
                tool: RecallTool(store: memoryStore),
                effects: [.localRead],
                trustRevision: "builtin.v1"
            ))
        }
        self.snapshot = try Self.catalog(
            enabledToolNames: enabledToolNames,
            memoryAvailable: memoryStore != nil,
            eventSeamAvailable: eventStore != nil,
            locationSeamAvailable: locationProvider != nil
        )
        self.adapters = adapters
        self.mcpCache = mcpCache
    }

    private static func effects(for name: String) -> [AgentEffect] {
        switch name {
        case "web_search": [.networkRead]
        case "wikipedia", "fetch_webpage": [.networkRead]
        case "remember": [.localWrite]
        case "recall": [.localRead]
        case "create_calendar_event", "create_reminder": [.localWrite]
        case "list_calendar_events", "current_location": [.localRead]
        default: [.localPure]
        }
    }

    private static func requiredCapabilities(for name: String) -> AgentCapabilitySet {
        AgentCapabilitySet(effects(for: name).compactMap(\.minimumCapability))
    }

    private static func idempotency(for name: String) -> ExternalIdempotency {
        // A write tool cannot declare pure-read idempotency (descriptor semantics validation).
        name == "remember" || name == "create_calendar_event" || name == "create_reminder"
            ? .nonIdempotent : .pureRead
    }

    private static func timeoutMilliseconds(for name: String) -> UInt64 {
        switch name {
        case "web_search", "wikipedia", "fetch_webpage": 30_000
        case "current_location": 15_000
        default: 5_000
        }
    }

    func localSnapshot() async throws -> ToolCatalogSnapshot { snapshot }

    func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)? {
        if let adapter = adapters[descriptorID] { return adapter }
        // MCP adapters are built lazily from the explicit discovery cache; a descriptor can only
        // appear in a frozen run if the user's setup/refresh flow discovered that server.
        let providerPrefix = "mcp."
        let providerID = descriptorID.logicalID.providerID
        guard providerID.hasPrefix(providerPrefix),
              let stableID = UUID(uuidString: String(providerID.dropFirst(providerPrefix.count))),
              let server = mcpCache.server(serverStableID: stableID)
        else { return nil }
        guard let spec = mcpCache.specs(serverStableID: stableID).first(where: {
            $0.name == descriptorID.logicalID.name
        }) else { return nil }
        return try MCPToolV2Adapter(
            client: MCPClient(server: server),
            spec: spec,
            serverStableID: stableID,
            trustRevision: "mcp.v1"
        )
    }
}

// MARK: - Request builder + freezer

struct AppAgentRunRequestBuilder: AgentRunRequestBuilding {
    let frozenBuilder: AppFrozenInputBuilder
    let snapshot: @MainActor (UUID, UUID, String, [ImageRef]) -> AgentRunRequestSnapshot?
    let artifacts: AppAgentArtifactResolver
    let lastSubmission: LastSubmissionBox

    func buildSubmission(
        conversationID: UUID,
        userTurnID: UUID,
        text: String,
        imageRefs: [ImageRef]
    ) async throws -> AgentRunSubmission {
        guard let snapshot = await snapshot(conversationID, userTurnID, text, imageRefs) else {
            throw AgentExecutionError.internalInvariant("agent snapshot unavailable")
        }
        let artifactReferences = try await artifacts.resolveCurrent(imageRefs, conversationID: conversationID)
        let historyArtifacts = try await artifacts.resolveHistory(
            in: snapshot,
            excluding: userTurnID
        )
        let request = try frozenBuilder.request(
            snapshot: snapshot,
            artifactReferences: artifactReferences
        )
        let frozen = try frozenBuilder.frozenInputs(
            snapshot: snapshot,
            artifactReferences: artifactReferences,
            historyArtifacts: historyArtifacts
        )
        let submission = AgentRunSubmission(request: request, frozenInputs: frozen)
        lastSubmission.store(submission)
        return submission
    }
}

struct AppAgentRunInputFreezer: AgentRunInputFreezing {
    let frozenBuilder: AppFrozenInputBuilder
    let snapshot: @MainActor (UUID, UUID, String, [ImageRef]) -> AgentRunRequestSnapshot?
    let artifacts: AppAgentArtifactResolver
    let lastSubmission: LastSubmissionBox

    func freeze(_ request: AgentRequest) async throws -> FrozenAgentRunInputs {
        if let last = lastSubmission.value, last.request == request {
            return last.frozenInputs
        }
        guard let snapshot = await snapshot(
            request.conversationID.rawValue,
            request.userTurnID.rawValue,
            request.instruction,
            []
        ) else {
            throw AgentExecutionError.internalInvariant("agent snapshot unavailable")
        }
        let historyArtifacts = try await artifacts.resolveHistory(
            in: snapshot,
            excluding: request.userTurnID.rawValue
        )
        return try frozenBuilder.frozenInputs(
            snapshot: snapshot,
            artifactReferences: request.artifactReferences,
            historyArtifacts: historyArtifacts
        )
    }
}

/// Small thread-safe holder for the most recent submission so the recovery freezer can reuse the
/// exact frozen inputs without re-reading mutable app stores.
final class LastSubmissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentRunSubmission?

    var value: AgentRunSubmission? {
        lock.withLock { stored }
    }

    func store(_ submission: AgentRunSubmission) {
        lock.withLock { stored = submission }
    }
}

// MARK: - Recovery listing

struct SQLiteJournalRecoveryLister: AgentRunRecoveryListing {
    let repository: SQLiteRunJournal

    func recoverableRuns() async throws -> [RecoverableAgentRun] {
        try await repository.listRuns().compactMap { summary in
            guard !summary.state.isTerminal,
                  let conversationID = summary.conversationID
            else { return nil }
            return RecoverableAgentRun(
                conversationID: conversationID.rawValue,
                runID: summary.runID,
                handleID: summary.executionHandleID,
                state: summary.state,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(summary.updatedAt.rawValue) / 1_000)
            )
        }
    }
}

// MARK: - Assembly

/// Thread-safe holder for the online Responses service configuration. The app refreshes the non-secret
/// values (base URL, model id) from Settings on the main actor at each submission; the runtime provider
/// reads a complete configuration on a worker thread and loads the API key from the Keychain on demand,
/// so the secret is never retained by this box or frozen into a run.
public final class OpenAIOnlineConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var baseURL: String
    private var modelID: String?
    private let credentials: any OpenAICredentialStoring

    public init(
        baseURL: String,
        modelID: String?,
        credentials: any OpenAICredentialStoring
    ) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.credentials = credentials
    }

    /// Refresh non-secret settings before a submission (called on the main actor).
    public func update(baseURL: String, modelID: String?) {
        lock.withLock {
            self.baseURL = baseURL
            self.modelID = modelID
        }
    }

    /// Provider-side read: returns a complete configuration only when the service is configured.
    func configuration() -> ResponsesAPIConfiguration? {
        lock.withLock {
            guard let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let key = try? credentials.loadAPIKey(),
                  !key.isEmpty
            else { return nil }
            return ResponsesAPIConfiguration(baseURL: baseURL, apiKey: key)
        }
    }
}

/// Composes the durable agent runtime at app assembly: SQLite journal, content-addressed artifacts,
/// local model providers over the app's routing engine, the local-pure tool catalog, the approval
/// engine, and the run store the UI projects.
@MainActor
public final class AgentRuntimeAssembly {
    public let runStore: AgentRunStore
    public let repository: SQLiteRunJournal
    public let artifactStore: ContentAddressedArtifactStore
    public let executor: DurableAgentExecutor
    /// Bounded redacted operational log (diagnostics only; never persisted as user history).
    public let diagnosticLogger: AgentDiagnosticLogger

    /// Debug-only assembly diagnostics; never part of the product's user history.
    nonisolated public static func logger(_ message: String) {
        #if DEBUG
        print("[AgentRuntimeAssembly] \(message)")
        #endif
    }

    public init(
        engine: any LLMEngine,
        downloadBase: URL,
        conversationDirectory: URL,
        snapshot: @escaping @MainActor (UUID, UUID, String, [ImageRef]) -> AgentRunRequestSnapshot?,
        memoryStore: (any MemoryStoring)? = nil,
        eventStore: (any EventStoring)? = nil,
        locationProvider: (any LocationProviding)? = nil,
        mcpDiscovery: MCPDiscoveryCache = MCPDiscoveryCache(),
        session: URLSession = .shared,
        onlineConfiguration: @escaping @Sendable () -> ResponsesAPIConfiguration? = { nil }
    ) throws {
        let fileManager = FileManager.default
        let support = conversationDirectory.appending(component: "agent")
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let journalURL = support.appending(component: "journal.sqlite")
        let artifactRoot = support.appending(component: "artifacts")

        repository = SQLiteRunJournal(databaseURL: journalURL)
        let names = AppArtifactNames()
        artifactStore = try ContentAddressedArtifactStore(
            configuration: ArtifactStoreConfiguration(
                rootURL: artifactRoot,
                excludeFromBackup: true,
                verifyPlatformProtection: false
            ),
            clock: { try! AgentTimestamp(Date()) },
            idGenerator: { names.nextID() },
            temporaryNameGenerator: { names.nextName() }
        )
        let payloadStore = ContentAddressedExecutionPayloadStore(store: artifactStore)
        let attachmentResolver = AppAttachmentResolver(store: artifactStore)
        let sanitizer = try LocalSanitizationAttestor(
            key: Data("mobilellm.agent-runtime.sanitization.v1".utf8.prefix(32)),
            policyRevision: 1
        )
        let policyEngine = try DefaultApprovalPolicyEngine(
            policyVersion: 1,
            sanitizationValidator: sanitizer
        )
        let diagnosticLogger = AgentDiagnosticLogger()

        let capabilityVersion = SemanticVersion("1.0.0")!
        let registrations = try LLMCatalog.all.flatMap { model -> [LocalModelRegistration] in
            try model.variants.map { variant in
                try LocalModelRegistration(
                    providerID: try AppFrozenInputBuilder.providerID(model: model, variant: variant),
                    capabilityVersion: capabilityVersion,
                    model: model,
                    variant: variant,
                    weightsDirectory: ModelDownloader(downloadBase: downloadBase)
                        .localURL(repoId: variant.source.huggingFaceRepo)
                )
            }
        }
        let residencyDriver = try LLMCoreModelResidencyDriver(engine: engine, registrations: registrations)
        var providers: [any AgentModelProvider] = try registrations.map { registration in
            try LocalModelProvider(
                descriptor: AgentModelProviderDescriptor(
                    id: registration.selection.providerID,
                    adapterVersion: capabilityVersion,
                    capabilityVersion: capabilityVersion,
                    location: .onDevice
                ),
                residencyDriver: residencyDriver,
                artifactResolver: attachmentResolver,
                configuration: try LocalModelAdapterConfiguration(
                    recordDiagnostic: { code, metadata in
                        await diagnosticLogger.record(code: code, metadata: metadata)
                    }
                )
            )
        }
        // Registered unconditionally so a recovered online run still resolves its provider even if the
        // user turned the toggle off before relaunch; generation then fails closed with a clear message.
        providers.append(try ResponsesAPIModelProvider(
            configurationProvider: onlineConfiguration,
            capabilityVersion: capabilityVersion
        ))
        let providerCatalog = try StaticAgentModelProviderCatalog(providers: providers)
        let toolCatalog = try AppToolCatalog(
            enabledToolNames: AppToolCatalog.adaptedToolNames,
            memoryStore: memoryStore,
            eventStore: eventStore,
            locationProvider: locationProvider,
            mcpCache: mcpDiscovery,
            session: session
        )
        let frozenBuilder = AppFrozenInputBuilder(
            capabilityVersion: capabilityVersion
        )
        let attachmentDirectory = conversationDirectory
            .appending(component: "attachments")
        let artifactResolver = AppAgentArtifactResolver(
            artifactStore: artifactStore,
            attachmentResolver: attachmentResolver,
            attachmentDirectory: attachmentDirectory
        )
        let lastSubmission = LastSubmissionBox()
        let builder = AppAgentRunRequestBuilder(
            frozenBuilder: frozenBuilder,
            snapshot: snapshot,
            artifacts: artifactResolver,
            lastSubmission: lastSubmission
        )
        let freezer = AppAgentRunInputFreezer(
            frozenBuilder: frozenBuilder,
            snapshot: snapshot,
            artifacts: artifactResolver,
            lastSubmission: lastSubmission
        )
        executor = DurableAgentExecutor(
            repository: repository,
            payloadStore: payloadStore,
            inputFreezer: freezer,
            modelProviders: providerCatalog,
            tools: toolCatalog,
            policyEngine: policyEngine,
            sanitizer: sanitizer,
            residencyDriver: residencyDriver,
            logger: diagnosticLogger
        )
        self.diagnosticLogger = diagnosticLogger
        runStore = AgentRunStore(
            executor: executor,
            requestBuilder: builder,
            recovery: SQLiteJournalRecoveryLister(repository: repository)
        )
    }
}

/// Bounded in-memory operational log for device diagnostics. Codes and metadata are redacted by the
/// runtime before recording; nothing here is user history.
public struct AgentDiagnosticEntry: Sendable {
    public let code: String
    public let metadata: [String: String]

    public init(code: String, metadata: [String: String]) {
        self.code = code
        self.metadata = metadata
    }
}

public actor AgentDiagnosticLogger: AgentExecutionLogging {
    private var entries: [AgentDiagnosticEntry] = []

    public func record(code: String, metadata: [String: String]) async {
        entries.append(AgentDiagnosticEntry(code: code, metadata: metadata))
        if entries.count > 24 { entries.removeFirst(entries.count - 24) }
    }

    public func snapshot() -> [AgentDiagnosticEntry] {
        entries
    }
}

private final class AppArtifactNames: @unchecked Sendable {
    func nextID() -> ArtifactID {
        // Random identities: a process-lifetime counter would collide with durable artifact records
        // after a relaunch (the content-addressed store persists ids in its index).
        ArtifactID(rawValue: UUID())
    }

    func nextName() -> String {
        "agent-artifact-\(UUID().uuidString)"
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
