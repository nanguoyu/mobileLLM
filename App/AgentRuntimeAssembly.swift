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
    /// MCP tools explicitly discovered by the user's server setup/refresh flow (spec §13: discovery
    /// never happens during prompt compilation).
    public let mcpToolDescriptors: [AgentToolDescriptor]
    /// Host-only destinations of the user's configured web-search engines (run-ceiling enumeration).
    public let webSearchDestinations: [ExternalDestination]
    /// The conversation-persistent tool policy (spec §14). App assembly snapshots the conversation's
    /// materialized policy; the runtime freezes it with the run.
    public let toolPolicy: ConversationToolPolicy?

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
        mcpToolDescriptors: [AgentToolDescriptor],
        webSearchDestinations: [ExternalDestination],
        toolPolicy: ConversationToolPolicy?
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
        self.mcpToolDescriptors = mcpToolDescriptors
        self.webSearchDestinations = webSearchDestinations
        self.toolPolicy = toolPolicy
    }
}

// MARK: - Shared frozen-input construction

/// Shared builder used by both the request builder (submission) and the input freezer (recovery).
/// Both paths produce the exact same immutable snapshot for one request.
struct AppFrozenInputBuilder: Sendable {
    let capabilityVersion: SemanticVersion

    /// Stable provider identity for one exact (model, variant) registration. The request builder and
    /// the app assembly MUST derive it the same way or the runtime cannot resolve the pinned provider.
    static func providerID(model: LLMModel, variant: LLMVariant) throws -> AgentModelProviderID {
        try AgentModelProviderID(
            "local.mobilellm.\(model.id).\(variant.id.sanitizedProviderComponent)"
                .prefix(120).description
        )
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
        let registration = try registration(snapshot: snapshot)
        let effectiveContext = UInt64(
            ContextPolicy.effective(requested: snapshot.contextLength, model: snapshot.model)
        )
        let contextBudget = try ContextTokenBudget(
            maximumContextTokens: effectiveContext,
            reservedOutputTokens: 1_024,
            maximumToolSchemaTokens: 1_024
        )
        let generationParameters = try AgentModelGenerationParameters(
            maximumOutputTokens: UInt64(snapshot.maxTokens),
            maximumContextTokens: effectiveContext,
            temperature: snapshot.temperature,
            topP: snapshot.topP,
            topK: snapshot.topK > 0 ? UInt32(snapshot.topK) : nil,
            repetitionPenalty: snapshot.repetitionPenalty,
            thinkingMode: snapshot.thinkingEnabled ? .enabled : .disabled,
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
            modelSelection: registration.selection,
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
        let registration = try registration(snapshot: snapshot)
        let runID = AgentRunID(rawValue: UUID())
        let effectiveContext = UInt64(
            ContextPolicy.effective(requested: snapshot.contextLength, model: snapshot.model)
        )
        let budget = try AgentBudget.firstReleaseDefaults(
            contextTokensPerAttempt: effectiveContext,
            outputTokens: UInt64(snapshot.maxTokens),
            // Observed on device: the Gemma 4 E2B vision path peaks at ~1.30 GB (weights + mmproj +
            // KV + image encode), so a 1 GiB run ceiling fails settlement even though the model
            // answered correctly. 2 GiB covers every first-release curated model; it is a hard
            // per-run ceiling, not a residency admission check.
            peakMemoryBytes: 2_147_483_648
        )
        var ceilingDestinations = snapshot.webSearchDestinations
        if snapshot.memorySeamAvailable {
            ceilingDestinations.append(try ExternalDestination(
                kind: .privateDataStore,
                normalizedIdentity: "mobilellm.memory"
            ))
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
            capabilities: AgentCapabilitySet([.networkRead, .localRead, .localWrite, .unknownExternal]),
            destinations: ceilingDestinations,
            dataCategories: [
                try AgentDataCategory(rawValue: "web.search"),
                try AgentDataCategory(rawValue: "user.memory"),
                try AgentDataCategory(rawValue: "mcp.call"),
            ]
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
                localOnly: true,
                allowedSelections: [registration.selection],
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

/// The app's Tool V2 catalog. First release adapts the curated tool set the device matrix exercises:
/// calculator, clock, web search (networkRead with approval), and app-owned memory (localRead/write,
/// gated on the MemoryBook seam). Every other built-in (Wikipedia, webpage fetch, MCP, calendar,
/// location, …) stays unavailable so the runtime never advertises a capability it cannot safely
/// execute.
final class AppToolCatalog: ExecutableToolCatalog, @unchecked Sendable {
    static let adaptedToolNames = AppLocalToolIDs.names

    let snapshot: ToolCatalogSnapshot
    let adapters: [AgentToolDescriptorID: any ToolV2]
    private let mcpCache: MCPDiscoveryCache

    static func catalog(
        enabledToolNames: [String],
        memoryAvailable: Bool,
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
            memoryAvailable: memoryStore != nil
        )
        self.adapters = adapters
        self.mcpCache = mcpCache
    }

    private static func effects(for name: String) -> [AgentEffect] {
        switch name {
        case "web_search": [.networkRead]
        case "remember": [.localWrite]
        case "recall": [.localRead]
        default: [.localPure]
        }
    }

    private static func requiredCapabilities(for name: String) -> AgentCapabilitySet {
        AgentCapabilitySet(effects(for: name).compactMap(\.minimumCapability))
    }

    private static func idempotency(for name: String) -> ExternalIdempotency {
        // A write tool cannot declare pure-read idempotency (descriptor semantics validation).
        name == "remember" ? .nonIdempotent : .pureRead
    }

    private static func timeoutMilliseconds(for name: String) -> UInt64 {
        name == "web_search" ? 30_000 : 5_000
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
        mcpDiscovery: MCPDiscoveryCache = MCPDiscoveryCache(),
        session: URLSession = .shared
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
        let providers = try registrations.map { registration in
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
        let providerCatalog = try StaticAgentModelProviderCatalog(providers: providers)
        let toolCatalog = try AppToolCatalog(
            enabledToolNames: AppToolCatalog.adaptedToolNames,
            memoryStore: memoryStore,
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
