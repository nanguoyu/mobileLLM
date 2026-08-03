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
        artifactReferences: [ArtifactReference]
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
                content: message.answer
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
            enabledLocalToolNames: snapshot.toolsEnabled ? localTools : []
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
            availableToolCapabilities: AgentCapabilitySet([]),
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
            peakMemoryBytes: 1_073_741_824
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
            capabilityCeiling: RunCapabilityCeiling(authority: .empty),
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
    private var bytesByArtifactID: [ArtifactID: Data] = [:]

    func store(_ artifactID: ArtifactID, bytes: Data) {
        bytesByArtifactID[artifactID] = bytes
    }

    func preauthorizedBytes(for reference: ArtifactReference) async throws -> Data {
        guard let bytes = bytesByArtifactID[reference.id],
              bytes.count == reference.byteCount
        else { throw LocalModelAdapterError.artifactUnavailable(reference.id) }
        return bytes
    }
}

// MARK: - Tool catalog

/// The app's Tool V2 catalog. The first release adapts only local-pure tools; every other built-in
/// tool (web, Wikipedia, MCP, calendar, location, …) is listed as unavailable so the runtime never
/// advertises a capability it cannot safely execute, exactly as spec §14 requires.
struct AppToolCatalog: ExecutableToolCatalog, Sendable {
    static let localToolNames = AppLocalToolIDs.names

    let snapshot: ToolCatalogSnapshot
    let adapters: [AgentToolDescriptorID: LegacyLocalToolAdapter]

    static func catalog(
        enabledLocalToolNames: [String],
        trustRevision: String = "builtin.v1"
    ) throws -> ToolCatalogSnapshot {
        let builtIns = ToolRegistry.standard.tools
        var descriptors: [AgentToolDescriptor] = []
        var unavailable: [UnavailableTool] = []
        for tool in builtIns {
            let logicalID = try AgentToolLogicalID(providerID: "builtin", name: tool.schema.name)
            if Self.localToolNames.contains(tool.schema.name),
               enabledLocalToolNames.contains(tool.schema.name)
            {
                let adapter = try LegacyLocalToolAdapter(
                    tool: tool,
                    providerID: "builtin",
                    trustRevision: trustRevision
                )
                descriptors.append(adapter.descriptor)
            } else {
                unavailable.append(
                    UnavailableTool(logicalID: logicalID, reason: .providerUnavailable)
                )
            }
        }
        return try ToolCatalogSnapshot(
            revision: 1,
            descriptors: descriptors,
            unavailable: unavailable
        )
    }

    init(enabledLocalToolNames: [String]) throws {
        let snapshot = try Self.catalog(enabledLocalToolNames: enabledLocalToolNames)
        var adapters: [AgentToolDescriptorID: LegacyLocalToolAdapter] = [:]
        for tool in ToolRegistry.standard.tools
            where Self.localToolNames.contains(tool.schema.name)
                && enabledLocalToolNames.contains(tool.schema.name)
        {
            let adapter = try LegacyLocalToolAdapter(
                tool: tool,
                providerID: "builtin",
                trustRevision: "builtin.v1"
            )
            adapters[adapter.descriptor.id] = adapter
        }
        self.snapshot = snapshot
        self.adapters = adapters
    }

    func localSnapshot() async throws -> ToolCatalogSnapshot { snapshot }

    func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)? {
        adapters[descriptorID]
    }
}

// MARK: - Request builder + freezer

struct AppAgentRunRequestBuilder: AgentRunRequestBuilding {
    let frozenBuilder: AppFrozenInputBuilder
    let snapshot: @MainActor (UUID, UUID, String, [ImageRef]) -> AgentRunRequestSnapshot?
    let artifactStore: ContentAddressedArtifactStore
    let attachmentResolver: AppAttachmentResolver
    let attachmentDirectory: URL
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
        var artifactReferences: [ArtifactReference] = []
        if !imageRefs.isEmpty {
            for image in imageRefs {
                let url = attachmentDirectory.appending(component: image.fileName)
                let data = try Data(contentsOf: url)
                let runID = AgentRunID(rawValue: UUID())
                let committed = try await artifactStore.commit(
                    ArtifactCommitRequest(
                        data: data,
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
                await attachmentResolver.store(committed.id, bytes: data)
                artifactReferences.append(committed)
            }
        }
        let request = try frozenBuilder.request(
            snapshot: snapshot,
            artifactReferences: artifactReferences
        )
        let frozen = try frozenBuilder.frozenInputs(
            snapshot: snapshot,
            artifactReferences: artifactReferences
        )
        let submission = AgentRunSubmission(request: request, frozenInputs: frozen)
        lastSubmission.store(submission)
        return submission
    }
}

struct AppAgentRunInputFreezer: AgentRunInputFreezing {
    let frozenBuilder: AppFrozenInputBuilder
    let snapshot: @MainActor (UUID, UUID, String, [ImageRef]) -> AgentRunRequestSnapshot?
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
        return try frozenBuilder.frozenInputs(
            snapshot: snapshot,
            artifactReferences: request.artifactReferences
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
        snapshot: @escaping @MainActor (UUID, UUID, String, [ImageRef]) -> AgentRunRequestSnapshot?
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
        let attachmentResolver = AppAttachmentResolver()
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
                configuration: try LocalModelAdapterConfiguration()
            )
        }
        let providerCatalog = try StaticAgentModelProviderCatalog(providers: providers)
        let toolCatalog = try AppToolCatalog(enabledLocalToolNames: AppToolCatalog.localToolNames)
        let frozenBuilder = AppFrozenInputBuilder(
            capabilityVersion: capabilityVersion
        )
        let attachmentDirectory = conversationDirectory
            .appending(component: "attachments")
        let lastSubmission = LastSubmissionBox()
        let builder = AppAgentRunRequestBuilder(
            frozenBuilder: frozenBuilder,
            snapshot: snapshot,
            artifactStore: artifactStore,
            attachmentResolver: attachmentResolver,
            attachmentDirectory: attachmentDirectory,
            lastSubmission: lastSubmission
        )
        let freezer = AppAgentRunInputFreezer(
            frozenBuilder: frozenBuilder,
            snapshot: snapshot,
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
