// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime
import LLMCore
import AgentContracts
import AgentRuntime

/// Everything `send()` mutates before an attachment reaches disk. Keeping this snapshot small and
/// explicit lets the asynchronous write path restore the composer + conversation without rolling back
/// unrelated edits such as pinning or other conversation metadata.
private struct AttachmentSendRollback: Sendable {
    let conversationID: UUID
    let userID: UUID
    var assistantID: UUID?
    let text: String
    let stagedImages: [PendingImage]
    let originalTitle: String
    let originalModelID: String
    let originalVariantID: String
    let originalUpdatedAt: Date
    var provisionalTitle: String? = nil
    var provisionalModelID: String? = nil
    var provisionalVariantID: String? = nil
    var provisionalUpdatedAt: Date? = nil

    func accepting(assistantID: UUID, conversation: Conversation) -> Self {
        var copy = self
        copy.assistantID = assistantID
        copy.provisionalTitle = conversation.title
        copy.provisionalModelID = conversation.modelID
        copy.provisionalVariantID = conversation.variantID
        copy.provisionalUpdatedAt = conversation.updatedAt
        return copy
    }
}

/// The @MainActor UI state owner (DESIGN §2.3). Holds the conversation mirror + the live streaming
/// state, talks to the `LLMEngine` actor over an `AsyncThrowingStream`, and autosaves through
/// `ConversationStore`. Only the small streaming strings mutate per token, so the message list never
/// churns mid-stream.
@MainActor
@Observable
public final class ChatStore {

    /// A reasoning-only EOS or token limit earns one answer completion attempt, not another full generation
    /// budget. Some weak reasoning models ignore `thinking=false`; this cap keeps the fallback genuinely
    /// bounded even when those discarded reasoning tokens continue until the engine's token limit.
    private static let answerRecoveryMaxTokens = 384

    // MARK: - Published state

    /// The in-memory mirror of live conversations, newest first (pinned on top).
    public internal(set) var conversations: [Conversation] = []
    public var activeID: UUID? {
        didSet {
            // Every navigation path — row selection, back, delete fallback, Undo, erase — invalidates the
            // previous conversation's asynchronous model restore. Keeping this at the state boundary avoids
            // one forgotten assignment letting a slow native load switch models after the user moved on.
            if activeID != oldValue { cancelModelRestore?() }
        }
    }
    public var draft: String = ""
    /// Live in-flight turn; `nil` when idle.
    public private(set) var streaming: StreamingState?
    /// The id of the assistant message currently streaming, published separately from `streaming` so the
    /// thread list can decide *which* row is live WITHOUT re-reading the per-token `streaming` struct —
    /// only this leaf changes at start/stop, so the whole `ForEach` no longer re-diffs on every token.
    public private(set) var streamingMessageID: UUID?
    /// The model the engine is loaded with (kept in sync with `ModelManager.active` at the app shell).
    /// An EMPTY active conversation reseeds its remembered model to follow the switch — its record was
    /// only ever a placeholder, and leaving the stale seed made a relaunch "forget" the model you had
    /// switched to before saying anything.
    public var activeModel: LoadedModel? {
        didSet {
            guard !suppressEmptyConversationReseed else { return }
            guard let m = activeModel, let i = conversations.firstIndex(where: { $0.id == activeID }),
                  conversations[i].messages.isEmpty,
                  conversations[i].modelID != m.model.id || conversations[i].variantID != m.variant.id
            else { return }
            conversations[i].modelID = m.model.id
            conversations[i].variantID = m.variant.id
            persist(conversations[i])
        }
    }
    /// The composer's per-thread thinking toggle (seeded from Settings' default).
    public var thinkingEnabled: Bool
    /// Dictation language passthrough (the composer owns the mic UI but not AppSettings).
    public var dictationLocale: String? {
        get { settings.dictationLocale }
        set { settings.dictationLocale = newValue }
    }
    /// Tools passthrough — the composer shows and flips the same switch Settings owns, because a tool
    /// state you can't SEE from the chat reads as "tools don't work" (applies from the next send).
    public var toolsEnabled: Bool {
        get { settings.toolsEnabled }
        set { settings.toolsEnabled = newValue }
    }
    public private(set) var banner: Toast?
    /// Images staged in the composer for the next send — already downscaled + JPEG-re-encoded (never the
    /// raw 48 MP original). Capped at `maxAttachments`; cleared when the turn is sent. Held in memory
    /// only until send stamps them onto the user turn + writes them to disk.
    public private(set) var pendingImages: [PendingImage] = []
    /// The durable agent runtime projection (spec §20). Nil in tests/previews that exercise the
    /// legacy in-process loop; when present every send routes through `AgentRuntime`.
    public private(set) var agentRuns: AgentRunStore?
    /// Last agent-runtime send failure (diagnostics; toasts already surface it transiently).
    public private(set) var agentLastSendError: String?
    /// Lifecycle admission gate (spec §19.1): while backgrounded, no new user turn enters the run
    /// pipeline. Owned by `LifecycleCoordinator`.
    public private(set) var acceptingNewActions = true
    /// Fired when a durable agent run starts, so continued-processing can submit the eligible run.
    public var onAgentRunStarted: (@MainActor (UUID) -> Void)?
    /// Fired when a durable agent run reaches a terminal state, so continued-processing can complete
    /// or settle its system task.
    public var onAgentRunTerminal: (@MainActor (UUID, AgentTerminalReason) -> Void)?
    /// Whether the app is wired to the durable agent runtime. A false value keeps the legacy loop,
    /// which is how the rollout switch is implemented (spec §26).
    public var agentRuntimeEnabled: Bool { agentRuns != nil }

    /// The most images a single turn may carry (keeps the mtmd prefill — and memory — bounded).
    public static let maxAttachments = 3

    // MARK: - Dependencies

    private let engine: any LLMEngine
    private let store: ConversationStore
    private let settings: AppSettings
    /// The tool seams injected at app assembly (nil in tests/previews). `eventStore` / `locationProvider`
    /// back the privacy-gated calendar / reminders / location tools. A tool is assembled only when BOTH its
    /// toggle is on AND its seam is present (see `ToolRegistry.assemble`).
    private let eventStore: (any EventStoring)?
    private let locationProvider: (any LocationProviding)?
    /// What the assistant remembers about the user. Read on every send to compose the memory block into the
    /// system prompt — the automatic recall that makes memory work with a 2B model that never thinks to
    /// call `recall` — and unwrapped to its durable store when the memory tools are assembled. Public so
    /// the memory screen edits the very list the prompt is composed from.
    public let memoryBook: MemoryBook?
    /// The per-conversation skill packs (Skills v1). Optional so tests/previews that don't exercise skills
    /// construct a `ChatStore` without one; then `activeSkill` is always nil and composition falls back to
    /// the base system prompt. Public so the composer's Skill menu + management sheet reach the same store.
    public let skillStore: SkillStore?
    private var genTask: Task<Void, Never>?
    /// AppContainer uses this narrow synchronization hook when a model operation completes. Restoring a
    /// historical thread must update the engine identity without rewriting an empty, newly selected
    /// thread with a stale model from an earlier restore request.
    private var suppressEmptyConversationReseed = false
    /// The forward action attached to the current banner (Undo / Switch model), kept out of `Toast`
    /// so the value type stays `Equatable`.
    private var bannerAction: (@MainActor () -> Void)?
    private var bannerDismissTask: Task<Void, Never>?
    /// Conversations whose last autosave threw (disk full / unwritable), keyed by id so a Retry can
    /// re-persist exactly what failed. A save success clears its entry.
    private var pendingSaveFailures: [UUID: Conversation] = [:]
    /// The id of the save-failure banner currently on screen, so a burst of failures shows ONE banner
    /// (not one per turn) yet a later failure — after the banner is gone — surfaces a fresh one.
    private var persistFailureBannerID: UUID?
    /// Autosaves are ordered explicitly. Main-actor isolation does not order their work after each Task
    /// suspends in `ConversationStore`, so an untracked fire-and-forget save could otherwise land after a
    /// successful Delete All and recreate the conversation.
    private var persistenceTail: Task<Void, Never>?
    private var persistenceSequence: UInt64 = 0
    private var persistenceEpoch: UInt64 = 0
    /// Raised before an erase drains generation + autosaves. New mutations may still update transient UI,
    /// but no new conversation snapshot is allowed to enter the durable store until the erase finishes.
    private var conversationEraseInProgress = false
    /// Optimistically removed conversations stay excluded from any older launch-time disk snapshot. A
    /// `loadAllLive()` begun before the tombstone write can otherwise reinsert a chat after the user deleted
    /// it. IDs leave this set only when delete fails, Undo succeeds, or a full erase resets the session.
    private var locallyRemovedConversationIDs: Set<UUID> = []
    /// Settings can be open in more than one macOS window. Each erase request owns a reservation so an
    /// earlier failing request cannot reopen persistence while another window is still deleting files.
    private var conversationEraseReservations = 0
    /// How long a soft-deleted conversation stays undoable in-session before its file is purged from disk
    /// (the privacy promise — a deleted chat mustn't linger). Matches the Undo banner's auto-dismiss.
    static let undoWindow: TimeInterval = 5
    /// Tombstones older than this are swept (hard-deleted) on the next `load()`.
    static let tombstoneRetention: TimeInterval = 24 * 60 * 60
    /// Set by the app shell: reloads the active model if it was suspended to free memory while idle.
    /// Awaited right before generation, so a suspended big model comes back on the next send.
    /// Returns false when a lazy/suspended model could not become resident. Generation must stop at that
    /// boundary instead of calling an engine that has no loaded weights.
    public var ensureModelReady: (@Sendable () async -> Bool)?

    public init(engine: any LLMEngine, store: ConversationStore, settings: AppSettings,
                activeModel: LoadedModel? = nil,
                memoryBook: MemoryBook? = nil,
                eventStore: (any EventStoring)? = nil,
                locationProvider: (any LocationProviding)? = nil,
                skillStore: SkillStore? = nil,
                agentRuns: AgentRunStore? = nil) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.activeModel = activeModel
        self.memoryBook = memoryBook
        self.eventStore = eventStore
        self.locationProvider = locationProvider
        self.skillStore = skillStore
        self.agentRuns = agentRuns
        self.thinkingEnabled = settings.thinkingDefault
        if let agentRuns {
            attachAgentRuntime(agentRuns)
        }
    }

    /// Wires the durable agent runtime projection into chat. Called at app assembly after the
    /// container exists (the runtime needs a snapshot closure that reads this store).
    public func attachAgentRuntime(_ agentRuns: AgentRunStore) {
        self.agentRuns = agentRuns
        agentRuns.onAnswer = { [weak self] conversationID, assistantMessageID, text, reasoning, steps in
            self?.commitAgentAnswer(
                conversationID: conversationID,
                assistantMessageID: assistantMessageID,
                text: text,
                reasoning: reasoning,
                steps: steps
            )
        }
        agentRuns.onRunFailed = { [weak self] conversationID, assistantMessageID, message in
            self?.commitAgentFailure(
                conversationID: conversationID,
                assistantMessageID: assistantMessageID,
                message: message
            )
        }
        agentRuns.onRunTerminated = { [weak self] conversationID, assistantMessageID, reason, message in
            self?.settleAgentRunTerminal(
                conversationID: conversationID,
                assistantMessageID: assistantMessageID,
                reason: reason,
                message: message
            )
        }
        agentRuns.onRunStarted = { [weak self] conversationID, assistantMessageID in
            self?.agentRunDidStart(
                conversationID: conversationID,
                assistantMessageID: assistantMessageID
            )
        }
        agentRuns.onEphemeral = { [weak self] conversationID, kind, delta in
            guard let self, self.activeID == conversationID, self.streaming != nil else { return }
            switch kind {
            case .reasoning:
                if self.streaming?.thinkingStartedAt == nil {
                    self.streaming?.thinkingStartedAt = Date()
                }
                if self.streaming?.phase != .stopping {
                    self.streaming?.phase = .thinking
                }
                self.streaming?.reasoning += delta
            case .answer:
                self.pauseReasoningClock()
                if self.streaming?.phase != .stopping {
                    self.streaming?.phase = .answering
                }
                self.streaming?.answer += delta
            }
        }
    }

    /// Synchronize the engine selection into chat state. Explicit Models → Use operations may reseed an
    /// empty placeholder thread; historical-conversation restoration never may, because a superseded
    /// restore completing late must not overwrite the newly selected thread's remembered variant.
    public func synchronizeActiveModel(_ model: LoadedModel?, reseedEmptyConversation: Bool) {
        suppressEmptyConversationReseed = !reseedEmptyConversation
        activeModel = model
        suppressEmptyConversationReseed = false
    }

    // MARK: - Loading

    /// Hydrate the conversation LIST from disk (call once at launch). Launch deliberately has no active
    /// thread unless the user has already entered or created one while bootstrap was awaiting another
    /// store. In that case the live mirror wins per id and its selection is preserved: launch hydration
    /// must never navigate the user back out of work they already started. Sweeps stale tombstones first
    /// so a deleted chat doesn't survive on disk past its retention window (DESIGN §2.4 — the privacy
    /// promise).
    public func load() async {
        guard !conversationEraseInProgress else { return }
        let epoch = persistenceEpoch
        await store.sweepExpiredTombstones(olderThan: Self.tombstoneRetention)
        let loaded = await store.loadAllLive().sorted(by: Self.recency)
        guard persistenceEpoch == epoch, !conversationEraseInProgress else { return }

        // The main actor is re-entrant across the store awaits above. A user can therefore create/select
        // a thread while bootstrap is still reading memory or conversations. Merge at the commit point,
        // preferring the live value for duplicate ids, instead of replacing the mirror with an older disk
        // snapshot. On an ordinary cold launch `conversations` and `activeID` are empty, so this reduces to
        // the original "load history, select nothing" behavior.
        commitLoadedConversations(loaded)
    }

    /// Commit a launch snapshot against the current live mirror. Internal so the stale-snapshot contract can
    /// be tested deterministically without adding timing hooks to the durable ConversationStore actor.
    func commitLoadedConversations(_ loaded: [Conversation]) {
        let live = conversations
        let liveIDs = Set(live.map(\.id))
        conversations = (live + loaded.filter {
            !liveIDs.contains($0.id) && !locallyRemovedConversationIDs.contains($0.id)
        }).sorted(by: Self.recency)
        if let selected = activeID, !conversations.contains(where: { $0.id == selected }) {
            activeID = nil
        }
    }

    private static func recency(_ a: Conversation, _ b: Conversation) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.updatedAt > b.updatedAt
    }

    public var activeConversation: Conversation? {
        guard let activeID else { return nil }
        return conversations.first { $0.id == activeID }
    }

    /// The online service model when the user selected it AND a model id is configured. The API key is
    /// not checked here (Settings only enables the toggle once a key exists, and removing the key turns
    /// it off); a run that somehow reaches generation without a key fails closed in the provider.
    public var onlineModelID: String? { settings.onlineModelID }

    /// Stable id of the active online service (Keychain account + approval destination scope).
    public var onlineServiceID: String? { settings.onlineServiceID }

    /// Whether the ACTIVE thread remembers an online service identity.
    public var isOnlineThread: Bool {
        guard let convo = activeConversation else { return false }
        return OnlineModelIdentity.serviceParts(fromConversationModelID: convo.modelID) != nil
    }

    /// Effective online reasoning for the next send: the thread's explicit per-conversation override,
    /// else the global Thinking default (same default local conversations start from).
    public var onlineReasoningEnabled: Bool {
        guard isOnlineActive else { return false }
        if let convo = activeConversation, let override = convo.onlineReasoningEnabled {
            return override
        }
        return settings.thinkingDefault
    }

    /// The single composer thinking control: online threads persist their own override on the
    /// conversation record; local threads keep the session toggle.
    public var composerThinkingEnabled: Bool {
        get { isOnlineActive ? onlineReasoningEnabled : thinkingEnabled }
        set {
            if isOnlineActive, let convo = activeConversation,
               let idx = conversations.firstIndex(where: { $0.id == convo.id })
            {
                conversations[idx].onlineReasoningEnabled = newValue
                persist(conversations[idx])
            } else {
                thinkingEnabled = newValue
            }
        }
    }

    /// The active thread's per-conversation context override (nil = follow the global setting).
    public var conversationContextOverride: Int? { activeConversation?.contextLength }

    /// Context request for the next LOCAL run: thread override, else the global local setting.
    public var localContextRequest: Int { conversationContextOverride ?? settings.contextLength }

    /// Context request for the next ONLINE run: thread override, else the global online setting.
    public var onlineContextRequest: Int {
        conversationContextOverride ?? settings.onlineContextLength
    }

    /// Persist a per-conversation context override (nil = follow the global setting again).
    public func setConversationContextLength(_ value: Int?) {
        guard let convo = activeConversation,
              let idx = conversations.firstIndex(where: { $0.id == convo.id }) else { return }
        conversations[idx].contextLength = value
        persist(conversations[idx])
    }

    /// The active thread's stored approval-mode override (nil = follow the product default).
    /// Changing it applies from the next send; the mode is frozen into each run.
    public var conversationApprovalMode: AgentApprovalMode? {
        get { activeConversation?.approvalMode }
        set {
            guard let convo = activeConversation,
                  let idx = conversations.firstIndex(where: { $0.id == convo.id }) else { return }
            conversations[idx].approvalMode = newValue
            persist(conversations[idx])
        }
    }

    /// The effective approval mode for the next send: thread override, else the product default
    /// Safe preset (spec §15.2) — safe in-app/read/online operations run without prompts, while
    /// writes, unknown-external, destructive, financial, and code-execution still ask.
    public var effectiveApprovalMode: AgentApprovalMode {
        conversationApprovalMode ?? .safePreset
    }

    /// Whether a workflow is running in the active conversation (spec §20/§23). The workflow runtime is
    /// not implemented yet, so this is always false — the ••• Workflow entry stays disabled until it
    /// becomes true, exactly as specified.
    public var hasRunningWorkflow: Bool { false }

    /// The active thread's reasoning effort (nil = medium). Applies whenever reasoning is enabled.
    public var conversationReasoningEffort: ReasoningEffort? {
        get { activeConversation?.reasoningEffort }
        set {
            guard let convo = activeConversation,
                  let idx = conversations.firstIndex(where: { $0.id == convo.id }) else { return }
            conversations[idx].reasoningEffort = newValue
            persist(conversations[idx])
        }
    }

    /// Effective effort for the next send: thread override, else medium (spec §15.3).
    public var effectiveReasoningEffort: ReasoningEffort {
        conversationReasoningEffort ?? .medium
    }

    /// The active thread's sampling overrides (nil field = follow the global setting).
    public var conversationSamplingOverride: ConversationSampling? { activeConversation?.sampling }

    public var conversationTemperature: Double {
        conversationSamplingOverride?.temperature ?? settings.temperature
    }

    public var conversationTopP: Double {
        conversationSamplingOverride?.topP ?? settings.topP
    }

    /// True when the active ONLINE thread uses the service's own model output maximum (0 = auto).
    /// Local threads always have a finite engine budget, so this is always false for them.
    public var isOnlineOutputBudgetAuto: Bool {
        guard isOnlineActive else { return false }
        if let override = conversationSamplingOverride?.maxTokens { return override == 0 }
        return settings.onlineMaxTokens == 0
    }

    /// Effective finite output ceiling used for runtime accounting. Online auto mode maps 0 to the
    /// conversation's context window (the service metadata, when configured, may clamp it further).
    public var conversationMaxTokens: Int {
        if let override = conversationSamplingOverride?.maxTokens {
            if isOnlineActive && override == 0 { return onlineContextRequest }
            return override
        }
        if isOnlineActive {
            return settings.onlineMaxTokens == 0 ? onlineContextRequest : settings.onlineMaxTokens
        }
        return settings.maxTokens
    }

    /// Human-facing label for the sampling row: "Auto" when the online service picks its own max,
    /// otherwise the concrete token count.
    public var conversationOutputBudgetLabel: String {
        isOnlineActive && isOnlineOutputBudgetAuto ? "Auto" : "\(conversationMaxTokens)"
    }

    /// Set one per-conversation sampling field; nil restores "follow the global setting".
    public func setConversationTemperature(_ value: Double?) {
        mutateConversationSampling { $0.temperature = value }
    }

    public func setConversationTopP(_ value: Double?) {
        mutateConversationSampling { $0.topP = value }
    }

    public func setConversationMaxTokens(_ value: Int?) {
        // 0 means "auto" and only exists for online services; local engines need a finite budget.
        guard isOnlineActive || value != 0 else { return }
        mutateConversationSampling { $0.maxTokens = value }
    }

    private func mutateConversationSampling(_ mutate: (inout ConversationSampling) -> Void) {
        guard let convo = activeConversation,
              let idx = conversations.firstIndex(where: { $0.id == convo.id }) else { return }
        var sampling = conversations[idx].sampling ?? ConversationSampling()
        mutate(&sampling)
        conversations[idx].sampling = (sampling == ConversationSampling()) ? nil : sampling
        persist(conversations[idx])
    }

    /// Whether the next turn routes to the online provider. First-class model choice: it needs no local
    /// weights and no `activeModel`, so a device with zero installed models can still chat online.
    public var isOnlineActive: Bool { onlineModelID != nil }

    public var isStreaming: Bool { streaming != nil }
    public var hasModel: Bool { activeModel != nil || isOnlineActive }
    public var canSend: Bool {
        acceptingNewActions && !conversationEraseInProgress && hasModel && streaming == nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
    }

    /// The lifecycle coordinator calls this at the foreground→background boundary and back.
    public func setAcceptingNewActions(_ value: Bool) {
        acceptingNewActions = value
    }

    /// Header/switcher label for whatever will answer the next turn.
    public var activeModelLabel: String {
        if let service = settings.onlineActiveService {
            return OnlineModelIdentity.displayLabel(service.name)
        }
        return activeModel?.subtitle ?? "No model"
    }

    /// The durable generation identity for the current selection: online when active, else the local
    /// model. Also used to stamp conversations so a thread remembers its model across relaunch.
    private func currentGenerationModel() -> GenerationModel? {
        if let service = settings.onlineActiveService {
            return GenerationModel(
                modelID: OnlineModelIdentity.conversationModelID(service.id, model: service.modelID ?? ""),
                variantID: OnlineModelIdentity.variantID,
                displayName: OnlineModelIdentity.displayLabel(service.name),
                engine: .online
            )
        }
        return activeModel.map(GenerationModel.init)
    }

    // MARK: - Composer attachments

    /// Room for another staged image (the photo affordance disables at the cap).
    public var canAttachMoreImages: Bool {
        !conversationEraseInProgress && streaming == nil && pendingImages.count < Self.maxAttachments
    }

    /// Stage a picked/pasted image for the next send. Downscales + re-encodes to JPEG BEFORE storing so a
    /// 48 MP photo never rides the prompt or sits in memory at full size. No-op past the cap or when the
    /// bytes aren't a decodable image. Returns whether the image was added (so the UI can toast on reject).
    @discardableResult
    public func attach(imageData: Data) -> Bool {
        guard canAttachMoreImages, let jpeg = ImageAttachment.downscaledJPEG(from: imageData) else { return false }
        pendingImages.append(PendingImage(data: jpeg))
        return true
    }

    public func removePendingImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    public func clearPendingImages() {
        pendingImages.removeAll()
    }

    /// Load a persisted attachment's bytes (for thumbnail rendering in a committed user turn).
    public func attachmentData(_ ref: ImageRef) async -> Data? {
        await store.attachmentData(ref.id)
    }

    // MARK: - Conversation lifecycle

    /// Create + activate a fresh conversation (no-op if the newest thread is already an empty, unused
    /// one). Deliberately does NOT require a resident model — a flagship lets you create and browse
    /// threads model-less and gates only SENDING (`send`/`canSend`), so the pencil + empty-state CTA are
    /// never dead. The record seeds its model id from the active model, else the default (its real model
    /// is stamped on the first send).
    @discardableResult
    public func newConversation() -> Conversation? {
        guard !conversationEraseInProgress else { return nil }
        // New Chat is an explicit intent even when it reuses the one empty placeholder and activeID does
        // not change; any historical restore attached to that placeholder is no longer authoritative.
        cancelModelRestore?()
        if let existing = conversations.first(where: { $0.messages.isEmpty }),
           let i = conversations.firstIndex(where: { $0.id == existing.id }) {
            // Reusing a leftover empty thread must also refresh its model seed — it may have been
            // created under a different model, and a stale seed survives relaunch as a surprise switch.
            if let generation = currentGenerationModel() {
                conversations[i].modelID = generation.modelID
                conversations[i].variantID = generation.variantID
                persist(conversations[i])
            }
            materializeToolPolicyIfNeeded(at: i)
            activeID = existing.id
            return conversations[i]
        }
        let seed = currentGenerationModel()
        let convo = Conversation(modelID: seed?.modelID ?? settings.defaultModelID,
                                 variantID: seed?.variantID ?? "",
                                 toolPolicy: globalToolTemplate())
        conversations.insert(convo, at: 0)
        activeID = convo.id
        // Persisted immediately (not on first send) so an empty draft remains available in the list after
        // a relaunch. Launch still leaves every conversation unselected. At most one empty thread ever
        // exists (the reuse branch above), so this never litters the list.
        persist(convo)
        return convo
    }

    /// The current global tool template copied into a NEW conversation (spec §14: new conversations
    /// copy the template once at creation; later global changes affect new conversations only).
    private func globalToolTemplate() -> ConversationToolPolicy? {
        guard agentRuns != nil else { return nil }
        return currentToolPolicy(materializedFromGlobalTemplate: true)
    }

    /// Builds the current user selection into a conversation tool policy. Shared by the one-time
    /// global template copy and the Chat options menu's explicit per-conversation edits.
    private func currentToolPolicy(materializedFromGlobalTemplate: Bool) -> ConversationToolPolicy? {
        // The policy is the USER's selection (Tools screen), mapped to logical ids; the runtime's
        // selector and catalog decide which of those are adapted and advertised for a pass.
        var allowed = settings.builtInToolConfig.enabled.compactMap { id in
            try? AgentToolLogicalID(providerID: "builtin", name: id.rawValue)
        }
        allowed.append(contentsOf: agentMCPToolLogicalIDs?() ?? [])
        let deduped = Array(Set(allowed)).sorted()
        return try? ConversationToolPolicy(
            masterEnabled: settings.toolsEnabled,
            allowedToolIDs: deduped,
            pinnedToolIDs: deduped,
            selectionPolicyVersion: 1,
            materializedFromGlobalTemplate: materializedFromGlobalTemplate
        )
    }

    /// Explicit per-conversation edit from the Chat options menu: the toggles there are the
    /// conversation-local surface, so they must apply to the NEXT send in THIS thread. Global
    /// Settings changes alone never expand an existing policy (spec §14); a menu toggle is the
    /// explicit edit that does.
    public func applyCurrentToolSelectionToActiveConversation() {
        guard let idx = conversations.firstIndex(where: { $0.id == activeID }),
              let policy = currentToolPolicy(materializedFromGlobalTemplate: false)
        else { return }
        conversations[idx].toolPolicy = policy
        persist(conversations[idx])
    }

    /// One-time materialization for a legacy conversation on its first agent-runtime edit/run
    /// (spec §14). Later global changes never silently expand an existing policy.
    private func materializeToolPolicyIfNeeded(at index: Int) {
        guard agentRuns != nil,
              conversations[index].toolPolicy == nil,
              let template = globalToolTemplate()
        else { return }
        conversations[index].toolPolicy = template
        persist(conversations[index])
    }

    /// Set by the app shell: activate the given (modelID, variantID) if installed. Called when the user
    /// opens a conversation whose remembered model differs from the resident one — a thread keeps ITS
    /// model across relaunches instead of silently falling back to the Settings default.
    public var restoreModel: (@MainActor (_ modelID: String, _ variantID: String) -> Void)?
    /// Set by the app shell: logical ids of MCP tools explicitly discovered through the server
    /// setup/refresh flow. They join the built-in selection in every newly materialized policy.
    public var agentMCPToolLogicalIDs: (@MainActor () -> [AgentToolLogicalID])?
    /// Canonicalizes an exact or legacy persisted variant id using the same installed-model resolver that
    /// will perform restoration. Without this, one legacy Explore id appears to match every quant sibling.
    public var resolvePersistedVariantID: (@MainActor (_ modelID: String, _ variantID: String) -> String?)?
    /// Selecting another thread (including one that already matches the current model) invalidates any
    /// older asynchronous restore. AppContainer wires this to its latest-selection-wins restore task.
    public var cancelModelRestore: (@MainActor () -> Void)?

    public func select(_ id: UUID) {
        guard !conversationEraseInProgress else { return }
        guard conversations.contains(where: { $0.id == id }) else { return }
        // A list-row tap is immediately followed by ChatDetailView.onAppear on compact navigation. The
        // activeID observer cancels only when the row truly changes; the shell-level restore request then
        // makes the pair share one engine load.
        activeID = id
        restoreConversationModelIfNeeded()
    }

    /// Ask the shell to bring back the active conversation's own model and variant when they differ from
    /// the resident selection. Never mid-stream; empty model ids (a modelless placeholder thread) are left
    /// alone, and an empty legacy variant id means "any installed variant of this model".
    public func restoreConversationModelIfNeeded() {
        guard streaming == nil, let convo = activeConversation, !convo.modelID.isEmpty else { return }
        // An online thread remembers the service model id; reopen it by arming the same selection.
        // No local weights are involved, so there is nothing to load or restore.
        if let parts = OnlineModelIdentity.serviceParts(fromConversationModelID: convo.modelID) {
            // Re-arm the exact service the thread used. If the service was deleted, recreate a minimal
            // entry so the thread's model identity stays truthful and sends fail closed on the missing key.
            if settings.onlineServices.contains(where: { $0.id == parts.serviceID }) {
                let existing = settings.onlineServices.first { $0.id == parts.serviceID }!
                settings.upsertOnlineService(OnlineService(
                    id: existing.id,
                    name: existing.name,
                    baseURL: existing.baseURL,
                    modelID: parts.model,
                    isEnabled: true
                ))
            } else {
                settings.upsertOnlineService(OnlineService(
                    id: parts.serviceID,
                    name: parts.serviceID,
                    baseURL: settings.openAIBaseURL,
                    modelID: parts.model,
                    isEnabled: true
                ))
            }
            return
        }
        let modelDiffers = convo.modelID != activeModel?.model.id
        let variantDiffers: Bool
        if !convo.variantID.isEmpty,
           let canonicalID = resolvePersistedVariantID?(convo.modelID, convo.variantID) {
            variantDiffers = activeModel?.variant.id != canonicalID
        } else {
            variantDiffers = !convo.variantID.isEmpty
                && !(activeModel?.variant.matchesPersistedID(convo.variantID) ?? false)
        }
        guard modelDiffers || variantDiffers else { return }
        restoreModel?(convo.modelID, convo.variantID)
    }

    /// Stop generation, invalidate queued saves, and wait for every save that already reached the store.
    /// Call this before deleting conversation files; while it is active, `persist` rejects new snapshots.
    public func quiesceForConversationErase() async {
        conversationEraseReservations += 1
        if conversationEraseReservations == 1 {
            conversationEraseInProgress = true
            persistenceEpoch &+= 1
            cancelModelRestore?()
        }

        let generation = genTask
        if streaming != nil { stop() }
        generation?.cancel()
        await generation?.value

        // `commitStream` may have queued its final snapshot while the generation task was unwinding. The
        // erase epoch makes that persist a no-op, but waiting for the current tail also drains any save
        // that had already crossed the epoch check and entered ConversationStore.
        let tail = persistenceTail
        await tail?.value
        persistenceTail = nil
    }

    /// Finish the coordinated erase. A failed disk erase keeps the visible conversation mirror so the UI
    /// does not claim those chats vanished; a successful one returns every conversation-scoped value to a
    /// fresh state. Full-app erase additionally clears registry/token-derived caches and session toggles.
    public func finishConversationErase(succeeded: Bool, resetSessionState: Bool) {
        genTask?.cancel()
        genTask = nil
        streaming = nil
        streamingMessageID = nil
        if succeeded {
            conversations = []
            activeID = nil
            locallyRemovedConversationIDs.removeAll()
        }
        if succeeded || resetSessionState {
            draft = ""
            pendingImages.removeAll()
            pendingSaveFailures.removeAll()
            persistFailureBannerID = nil
            cachedRegistry = nil
            cachedRegistrySignature = nil
            bannerDismissTask?.cancel()
            bannerDismissTask = nil
            banner = nil
            bannerAction = nil
        }
        if resetSessionState {
            thinkingEnabled = settings.thinkingDefault
        }
        persistenceTail = nil
        conversationEraseReservations = max(0, conversationEraseReservations - 1)
        conversationEraseInProgress = conversationEraseReservations > 0
    }

    /// Compatibility entry point for tests/embedders that have already erased the store. Production
    /// deletion paths first await `quiesceForConversationErase()` and then call the explicit finisher.
    public func reloadAfterWipe() {
        conversationEraseReservations = max(1, conversationEraseReservations)
        finishConversationErase(succeeded: true, resetSessionState: true)
    }

    public func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].title = trimmed
        persist(conversations[i])
    }

    /// The project tags assigned to one conversation (spec §20: pure tag grouping, many-to-many).
    public func projectTags(for id: UUID) -> [String] {
        conversations.first(where: { $0.id == id })?.projectTagList ?? []
    }

    /// Replace a conversation's full tag set (normalized: trimmed, deduplicated, sorted).
    public func setProjectTags(_ tags: [String], for id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].projectTags = Self.normalizedProjectTags(tags.map(canonicalProjectTag))
        persist(conversations[i])
    }

    /// Toggle one tag on/off for a conversation.
    public func toggleProjectTag(_ tag: String, on id: UUID) {
        let canonical = canonicalProjectTag(tag)
        guard !canonical.isEmpty, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        var tags = conversations[i].projectTagList
        if let index = tags.firstIndex(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) {
            tags.remove(at: index)
        } else {
            tags.append(canonical)
        }
        conversations[i].projectTags = Self.normalizedProjectTags(tags)
        persist(conversations[i])
    }

    /// Every project tag in use, sorted — the tag picker and the list filter share this source.
    public var allProjectTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for convo in conversations {
            for tag in convo.projectTagList where seen.insert(tag.lowercased()).inserted {
                result.append(tag)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// How many conversations carry a tag (case-insensitive) — shown in the tag picker.
    public func projectTagCount(_ tag: String) -> Int {
        conversations.reduce(into: 0) { count, convo in
            if convo.projectTagList.contains(where: {
                $0.caseInsensitiveCompare(tag) == .orderedSame
            }) {
                count += 1
            }
        }
    }

    /// Rename a project tag across every conversation (case-insensitive match). The new spelling
    /// becomes canonical; if it already exists elsewhere its spelling is reused.
    public func renameProjectTag(_ oldTag: String, to newTag: String) {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let canonical = allProjectTags.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) ?? trimmed
        for i in conversations.indices {
            let tags = conversations[i].projectTagList
            var changed = false
            let renamed = tags.map { tag -> String in
                if tag.caseInsensitiveCompare(oldTag) == .orderedSame {
                    changed = true
                    return canonical
                }
                return tag
            }
            if changed {
                conversations[i].projectTags = Self.normalizedProjectTags(renamed)
                persist(conversations[i])
            }
        }
    }

    /// Delete a project tag from every conversation (case-insensitive match).
    public func deleteProjectTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for i in conversations.indices {
            let tags = conversations[i].projectTagList
            let remaining = tags.filter {
                $0.caseInsensitiveCompare(trimmed) != .orderedSame
            }
            if remaining.count != tags.count {
                conversations[i].projectTags = Self.normalizedProjectTags(remaining)
                persist(conversations[i])
            }
        }
    }

    /// Reuses the spelling of an existing tag (case-insensitive), so "work" and "Work" never appear
    /// as two picker entries — the first-seen spelling wins everywhere.
    private func canonicalProjectTag(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return allProjectTags.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            ?? trimmed
    }

    private static func normalizedProjectTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        let trimmed = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return trimmed.filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func togglePin(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].pinned.toggle()
        let convo = conversations[i]
        conversations.sort(by: Self.recency)
        persist(convo)
    }

    /// Soft-delete with an Undo affordance (DESIGN §4 — irreversible loss gets undo, not just confirm).
    /// Rolls the mirror back if the on-disk tombstone write fails (so mirror and disk never diverge), and
    /// schedules a hard-delete once the Undo window lapses so a "deleted" chat doesn't linger on disk.
    public func delete(_ id: UUID) {
        guard let removed = conversations.first(where: { $0.id == id }) else { return }
        let previousActive = activeID
        locallyRemovedConversationIDs.insert(id)
        conversations.removeAll { $0.id == id }
        if activeID == id {
            activeID = conversations.first?.id
            restoreConversationModelIfNeeded()
        }
        // Optimistic: offer Undo instantly. The disk write + failure-rollback happen behind it.
        showToast(Toast("Conversation deleted", actionTitle: "Undo", autoDismiss: Self.undoWindow),
                  action: { [weak self] in self?.restore(removed) })
        let epoch = persistenceEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.softDelete(id)
                guard self.persistenceEpoch == epoch, !self.conversationEraseInProgress else { return }
                self.scheduleTombstoneSweep(id)
            } catch {
                guard self.persistenceEpoch == epoch, !self.conversationEraseInProgress else { return }
                // Roll the mirror back — disk still has it live, so the list must too (guarded so a race
                // with a just-tapped Undo can't double-insert it).
                if !self.conversations.contains(where: { $0.id == id }) {
                    self.locallyRemovedConversationIDs.remove(id)
                    self.conversations.append(removed)
                    self.conversations.sort(by: Self.recency)
                    self.activeID = previousActive
                    self.restoreConversationModelIfNeeded()
                }
                self.showToast(Toast("Couldn't delete the conversation.", kind: .error, autoDismiss: 4))
            }
        }
    }

    private func restore(_ convo: Conversation) {
        let epoch = persistenceEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.restore(convo.id)   // only re-add on success, else mirror/disk diverge
                guard self.persistenceEpoch == epoch, !self.conversationEraseInProgress else { return }
                self.locallyRemovedConversationIDs.remove(convo.id)
                self.conversations.append(convo)
                self.conversations.sort(by: Self.recency)
                self.activeID = convo.id
                self.restoreConversationModelIfNeeded()
            } catch {
                guard self.persistenceEpoch == epoch, !self.conversationEraseInProgress else { return }
                self.showToast(Toast("Couldn't restore the conversation.", kind: .error, autoDismiss: 4))
            }
        }
    }

    /// Purge a soft-deleted conversation's file once its in-session Undo window has passed — unless it was
    /// undone (restored back into the mirror). Keeps the tombstone honest without stranding data on disk.
    private func scheduleTombstoneSweep(_ id: UUID) {
        let epoch = persistenceEpoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.undoWindow + 0.5) * 1_000_000_000))
            guard let self, self.persistenceEpoch == epoch, !self.conversationEraseInProgress,
                  !self.conversations.contains(where: { $0.id == id }) else { return }
            try? await self.store.hardDelete(id)
        }
    }

    // MARK: - Sending

    /// Send the composer draft (text and/or staged images): append the user turn + an empty assistant
    /// turn, then stream a reply. An image-only turn (no text) is allowed for vision models.
    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedImages = pendingImages
        let images = stagedImages.map(\.data)
        guard acceptingNewActions,
              !text.isEmpty || !images.isEmpty,
              hasModel,
              streaming == nil
        else { return }

        // Image capability belongs to the exact variant, not merely to the engine family: a text-only GGUF
        // (for example Bonsai 8B) runs on llama.cpp but has no vision projector. Reject before clearing the
        // composer or creating provisional messages, otherwise that path silently sends an all-text prompt
        // and loses the user's staged image. Draft + images remain intact for a retry after switching.
        if !images.isEmpty,
           isOnlineActive
                || activeModel?.variant.engine != .llamaCpp
                || activeModel?.variant.supportsVisionInput != true {
            showToast(Toast("This model can't read images — switch to an image-capable model and try again.",
                            kind: .warning, autoDismiss: 5))
            return
        }

        draft = ""
        clearPendingImages()
        guard let convo = activeConversation ?? newConversation(),
              let idx = conversations.firstIndex(where: { $0.id == convo.id }) else { return }

        // Reference the attached images by id; the bytes are written to disk (never inlined in the record).
        // Reuse the staged image ids for the durable refs. Besides making the relationship explicit, this
        // lets a failed disk write restore the exact composer payload without manufacturing a second set
        // of identities.
        let refs = stagedImages.map { ImageRef(id: $0.id) }
        let rollback = AttachmentSendRollback(
            conversationID: conversations[idx].id,
            userID: UUID(),
            text: text,
            stagedImages: stagedImages,
            originalTitle: conversations[idx].title,
            originalModelID: conversations[idx].modelID,
            originalVariantID: conversations[idx].variantID,
            originalUpdatedAt: conversations[idx].updatedAt
        )
        let user = Message(id: rollback.userID, role: .user, answer: text,
                           attachments: refs.isEmpty ? nil : refs)
        conversations[idx].messages.append(user)
        // Auto-title from the first user line (model-summarized titling is TODO(v1.0)).
        if conversations[idx].messages.filter({ $0.role == .user }).count == 1 {
            conversations[idx].title = Self.autoTitle(from: text)
        }
        // Stamp the model that's actually answering on EVERY send — the record tracks the thread's
        // CURRENT model, so reopening the app restores what you were really using, not the first pick.
        if let generation = currentGenerationModel() {
            conversations[idx].modelID = generation.modelID
            conversations[idx].variantID = generation.variantID
        }
        let assistant = Message(role: .assistant, answer: "", parentID: user.id)
        conversations[idx].messages.append(assistant)
        conversations[idx].updatedAt = Date()

        let attachments = zip(refs, images).map { (id: $0.0.id, data: $0.1) }
        let finalRollback = rollback.accepting(
            assistantID: assistant.id,
            conversation: conversations[idx]
        )
        if let agentRuns {
            // Legacy conversations materialize the global tool template exactly once on their first
            // agent-runtime run (spec §14).
            materializeToolPolicyIfNeeded(at: idx)
            startAgentRun(
                conversationID: conversations[idx].id,
                user: user,
                assistant: assistant,
                text: text,
                attachments: attachments,
                attachmentRollback: finalRollback,
                agentRuns: agentRuns
            )
        } else {
            startGeneration(assistantID: assistant.id, in: conversations[idx].id,
                            writeAttachments: attachments,
                            attachmentRollback: finalRollback)
        }
    }

    /// Routes one turn through the durable agent runtime (spec §9.1 send order): attachment bytes
    /// reach disk first, then the run is submitted; the committed answer is projected back into the
    /// conversation record only after the journal terminal event arrives.
    private func startAgentRun(
        conversationID: UUID,
        user: Message,
        assistant: Message,
        text: String,
        attachments: [(id: UUID, data: Data)],
        attachmentRollback: AttachmentSendRollback?,
        agentRuns: AgentRunStore
    ) {
        let store = self.store
        let imageRefs = user.attachments ?? []
        streamingMessageID = assistant.id
        streaming = StreamingState(messageID: assistant.id)
        genTask = Task { @MainActor [weak self] in
            do {
                do {
                    for attachment in attachments {
                        try await store.writeAttachment(attachment.data, id: attachment.id)
                    }
                } catch {
                    await store.removeAttachments(imageRefs)
                    if let attachmentRollback {
                        self?.recoverFailedAttachmentSend(attachmentRollback, error: error)
                    }
                    return
                }
                // Online runs need no local weights: the provider is remote and the run ceiling already
                // carries the exact modelProvider destination. Local runs load lazily as before.
                let online = self?.isOnlineActive ?? false
                let ready: Bool
                if online {
                    ready = true
                } else {
                    ready = await self?.ensureModelReady?() ?? true
                }
                guard ready, online || self?.activeModel != nil else {
                    self?.agentLastSendError = "model readiness failed before agent send"
                    self?.finalizeAgentRun(
                        conversationID: conversationID,
                        assistantMessageID: assistant.id,
                        failed: true,
                        errorMessage: "The model could not be loaded."
                    )
                    return
                }
                _ = try await agentRuns.start(
                    conversationID: conversationID,
                    userMessageID: user.id,
                    assistantMessageID: assistant.id,
                    text: text,
                    imageRefs: imageRefs
                )
            } catch is CancellationError {
                self?.agentLastSendError = "agent send cancelled before start"
                self?.finalizeAgentRun(
                    conversationID: conversationID,
                    assistantMessageID: assistant.id,
                    failed: true,
                    errorMessage: "The run was cancelled before it started."
                )
            } catch {
                self?.agentLastSendError = "\(error)"
                self?.finalizeAgentRun(
                    conversationID: conversationID,
                    assistantMessageID: assistant.id,
                    failed: true,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    /// The runtime accepted the run; keep the UI busy state alive until the terminal event lands.
    private func agentRunDidStart(conversationID: UUID, assistantMessageID: UUID) {
        guard streamingMessageID == assistantMessageID else { return }
        if streaming?.phase != .stopping {
            streaming?.phase = .warming
        }
        onAgentRunStarted?(conversationID)
    }

    /// Project the committed journal answer into the conversation record (spec §9.1: journal first,
    /// JSON projection second).
    private func commitAgentAnswer(
        conversationID: UUID,
        assistantMessageID: UUID,
        text: String,
        reasoning: String?,
        steps: [AgentRunStep]
    ) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantMessageID })
        else { return }
        pauseReasoningClock()
        var message = conversations[ci].messages[mi]
        message.answer = text
        message.reasoning = reasoning
        if let duration = streaming?.thinkingDuration, duration > 0 {
            message.thinkingSeconds = duration
        }
        let toolRuns = steps.compactMap { step -> ToolRun? in
            guard step.kind == .toolCall else { return nil }
            return ToolRun(
                name: step.title,
                arguments: step.detail,
                result: step.resultText ?? step.statusText
            )
        }
        if !toolRuns.isEmpty { message.toolRuns = toolRuns }
        if let generation = currentGenerationModel() { message.generatedBy = generation }
        if let usage = agentRuns?.presentation(for: conversationID)?.usage {
            let outputTokens = usage.quantities[.outputTokens]
            let activeMilliseconds = usage.quantities[.activeMilliseconds]
            let seconds = max(1, Double(activeMilliseconds) / 1_000)
            message.stats = Stats(
                promptTokens: Int(usage.quantities[.inputTokens]),
                genTokens: Int(outputTokens),
                promptTPS: 0,
                tokensPerSecond: Double(outputTokens) / seconds,
                peakMemoryBytes: Int64(usage.quantities[.peakMemoryBytes]),
                stopReason: .eos
            )
        }
        conversations[ci].messages[mi] = message
        conversations[ci].updatedAt = Date()
        persist(conversations[ci])
        if streamingMessageID == assistantMessageID {
            streaming = nil
            streamingMessageID = nil
            genTask = nil
        }
        onAgentRunTerminal?(
            conversationID,
            agentRuns?.presentation(for: conversationID)?.terminalReason ?? .completed
        )
    }

    private func commitAgentFailure(
        conversationID: UUID,
        assistantMessageID: UUID,
        message: String
    ) {
        finalizeAgentRun(
            conversationID: conversationID,
            assistantMessageID: assistantMessageID,
            failed: true,
            errorMessage: message
        )
    }

    /// A run that ended without an answer (Stop/cancel or failure) must settle the streaming row:
    /// mark the turn Stopped/Failed and release the composer for the next send.
    private func settleAgentRunTerminal(
        conversationID: UUID,
        assistantMessageID: UUID,
        reason: AgentTerminalReason,
        message: String?
    ) {
        pauseReasoningClock()
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantMessageID })
        else {
            if streamingMessageID == assistantMessageID {
                streaming = nil
                streamingMessageID = nil
                genTask = nil
            }
            return
        }
        var turn = conversations[ci].messages[mi]
        turn.emptyOutcome = reason == .cancelledByUser ? .stopped : .failed
        conversations[ci].messages[mi] = turn
        conversations[ci].updatedAt = Date()
        persist(conversations[ci])
        if streamingMessageID == assistantMessageID {
            streaming = nil
            streamingMessageID = nil
            genTask = nil
        }
        if let message, reason != .cancelledByUser {
            showToast(Toast(message, kind: .error, autoDismiss: 5))
        }
        onAgentRunTerminal?(conversationID, reason)
    }

    private func finalizeAgentRun(
        conversationID: UUID,
        assistantMessageID: UUID,
        failed: Bool,
        errorMessage: String
    ) {
        guard let ci = conversations.firstIndex(where: { $0.id == conversationID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantMessageID })
        else { return }
        if failed {
            var message = conversations[ci].messages[mi]
            message.emptyOutcome = .failed
            conversations[ci].messages[mi] = message
            conversations[ci].updatedAt = Date()
            persist(conversations[ci])
            showToast(Toast(errorMessage, kind: .error, autoDismiss: 5))
        }
        if streamingMessageID == assistantMessageID {
            streaming = nil
            streamingMessageID = nil
            genTask = nil
        }
    }

    /// Reattaches to recoverable runs for the active thread without resuming them (spec §9.4:
    /// recovery is explicit user intent).
    public func recoverAgentRuns() async {
        await agentRuns?.refreshRecoverableRuns()
    }

    /// Reopens a recoverable run when the user opens its thread; the run stays paused until Resume.
    public func reopenAgentRun(_ recoverable: RecoverableAgentRun) async {
        do {
            let assistantMessageID = activeConversation?.messages
                .last(where: { $0.role == .assistant })?.id
            try await agentRuns?.reopen(
                recoverable: recoverable,
                assistantMessageID: assistantMessageID
            )
        } catch {
            showToast(Toast(error.localizedDescription, kind: .error, autoDismiss: 5))
        }
    }

    /// Regenerate an assistant turn: drop it (and anything after) and stream a fresh reply to the
    /// preceding user turn. `parentID` is preserved for the v1.0 branch pager.
    public func regenerate(assistantMessageID: UUID) {
        guard streaming == nil, let ci = conversations.firstIndex(where: { $0.id == activeID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantMessageID }),
              conversations[ci].messages[mi].role == .assistant else { return }
        let parentID = conversations[ci].messages[mi].parentID
        guard let ui = conversations[ci].messages.firstIndex(where: { $0.id == parentID }),
              conversations[ci].messages[ui].role == .user else { return }
        let user = conversations[ci].messages[ui]
        purgeAttachments(of: Array(conversations[ci].messages[mi...]))
        conversations[ci].messages.removeSubrange(mi...)
        let fresh = Message(role: .assistant, answer: "", parentID: parentID)
        conversations[ci].messages.append(fresh)
        conversations[ci].updatedAt = Date()
        if let agentRuns {
            materializeToolPolicyIfNeeded(at: ci)
            startAgentRun(
                conversationID: conversations[ci].id,
                user: user,
                assistant: fresh,
                text: user.answer,
                attachments: [],
                attachmentRollback: nil,
                agentRuns: agentRuns
            )
        } else {
            startGeneration(assistantID: fresh.id, in: conversations[ci].id)
        }
    }

    /// Truncation flows drop whole turns from a LIVE thread — their attachment pixels must leave the disk
    /// with them (the same privacy promise hard-delete keeps), or regenerate/edit quietly leaks orphans.
    private func purgeAttachments(of dropped: [Message]) {
        let refs = dropped.compactMap(\.attachments).flatMap { $0 }
        guard !refs.isEmpty else { return }
        let store = self.store
        Task { await store.removeAttachments(refs) }
    }

    /// True when `id` is the newest assistant turn in `convo` — regenerating it discards nothing after it,
    /// so it can stay one-tap; regenerating an earlier one silently drops later turns and needs a confirm.
    public func isLastAssistantMessage(_ id: UUID, in convo: Conversation) -> Bool {
        convo.messages.last(where: { $0.role == .assistant })?.id == id
    }

    /// How many later turns regenerating the assistant message `id` would drop (everything after it).
    public func discardedTurnCount(regeneratingFrom id: UUID) -> Int {
        guard let convo = activeConversation,
              let mi = convo.messages.firstIndex(where: { $0.id == id }) else { return 0 }
        return convo.messages.count - (mi + 1)
    }

    /// Edit a user turn and resend: truncate from it, replace the text, and regenerate (branch pager
    /// UI is TODO(v1.0); the `parentID` plumbing is in place).
    public func editAndResend(userMessageID: UUID, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, streaming == nil,
              let ci = conversations.firstIndex(where: { $0.id == activeID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == userMessageID }),
              conversations[ci].messages[mi].role == .user else { return }
        purgeAttachments(of: Array(conversations[ci].messages[(mi + 1)...]))
        conversations[ci].messages.removeSubrange((mi + 1)...)
        conversations[ci].messages[mi].answer = text
        let user = conversations[ci].messages[mi]
        let assistant = Message(role: .assistant, answer: "", parentID: userMessageID)
        conversations[ci].messages.append(assistant)
        conversations[ci].updatedAt = Date()
        if let agentRuns {
            materializeToolPolicyIfNeeded(at: ci)
            startAgentRun(
                conversationID: conversations[ci].id,
                user: user,
                assistant: assistant,
                text: text,
                attachments: [],
                attachmentRollback: nil,
                agentRuns: agentRuns
            )
        } else {
            startGeneration(assistantID: assistant.id, in: conversations[ci].id)
        }
    }

    private func startGeneration(assistantID: UUID, in conversationID: UUID,
                                 writeAttachments: [(id: UUID, data: Data)] = [],
                                 attachmentRollback: AttachmentSendRollback? = nil) {
        guard let convo = conversations.first(where: { $0.id == conversationID }) else { return }
        var state = StreamingState(messageID: assistantID)
        state.phase = .warming
        // Only a real network handshake earns the note — local tools connect to nothing, and a lingering
        // "Connecting tools…" over plain prefill reads as a hang. Cleared as soon as the registry is up.
        // A send is an authorization boundary. Capture every per-tool choice synchronously, before the task
        // can suspend for attachment I/O or a cold model load; settings changed while warming apply only to
        // the next turn and can neither grant nor revoke capabilities retroactively.
        let toolsOn = settings.toolsEnabled
        let turnToolConfig = settings.builtInToolConfig
        let turnMCPServers = settings.mcpServers.filter {
            $0.isEnabled && !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let turnMemoryEnabled = turnToolConfig.enabled.contains(.recall)

        if toolsOn, !turnMCPServers.isEmpty {
            state.warmingNote = "Connecting tools…"
        }
        // A turn carrying an image makes the engine bring the vision encoder up — ~940 MB and a few
        // seconds for the FIRST image of a session (it's resident afterwards, so later ones only pay to
        // encode). Either way the pause is real and needs a reason on screen; without one it reads as a
        // hang. The note clears the moment tokens start.
        if convo.messages.last(where: { $0.role == .user })?.attachments?.isEmpty == false,
           activeModel?.variant.supportsVisionInput == true {
            state.warmingNote = "Reading image…"
        }
        streaming = state
        streamingMessageID = assistantID

        let history = convo.messages.filter { $0.id != assistantID }
        // What this turn asks about — the query the memory block is searched with, below.
        let memoryQuery = Self.memoryQuery(history: history)
        let engine = self.engine
        let turnSettings = self.settings
        let store = self.store

        genTask = Task { @MainActor [weak self] in
            do {
                // Persist this turn's attachment bytes to disk FIRST, so the reload-from-disk below (and
                // any later follow-up / history replay) sees them. Files, not inline JSON (the privacy +
                // record-size promise).
                do {
                    for attachment in writeAttachments {
                        try await store.writeAttachment(attachment.data, id: attachment.id)
                    }
                } catch {
                    // A multi-image turn may have written one file before a later write failed. Remove
                    // every ref best-effort, roll the in-memory turn back, and restore the composer payload:
                    // no conversation record is ever allowed to point at pixels that did not reach disk.
                    await store.removeAttachments(writeAttachments.map { ImageRef(id: $0.id) })
                    if let attachmentRollback {
                        self?.recoverFailedAttachmentSend(attachmentRollback, error: error)
                    }
                    return
                }
                // Cold launch restores only model identity; the first turn loads its weights here. A
                // real engine/load failure is surfaced by AppContainer and must not fall through into
                // `generate` on an empty engine.
                guard await self?.ensureModelReady?() ?? true else {
                    self?.finalizeIfNeeded(assistantID: assistantID, stopReason: .cancelled, failed: true)
                    return
                }
                try Task.checkCancellation()
                guard let readyModel = self?.activeModel else {
                    self?.finalizeIfNeeded(assistantID: assistantID, stopReason: .cancelled, failed: true)
                    return
                }
                guard self?.streaming?.messageID == assistantID else { return }
                self?.streaming?.generatedBy = GenerationModel(readyModel)
                // Read model-dependent state only AFTER readiness: a concurrent explicit switch may have
                // completed while this turn waited for the one engine-mutation lane.
                let params = turnSettings.sampling(
                    thinking: (self?.thinkingEnabled ?? false) && turnSettings.thinkingDisplay != .hidden,
                    model: readyModel.model
                )
                let dialect = ToolDialect(readyModel.model.architecture.promptTemplate)
                // After switching an image-bearing thread to a text-only model, history degrades to text
                // rather than being rejected by the newly resident engine.
                let imageCapable = readyModel.variant.engine == .llamaCpp
                    && readyModel.variant.supportsVisionInput
                // Re-attach image bytes from disk for every image-bearing turn in THIS thread — the new
                // turn AND earlier ones — so a follow-up question still sees the image context. Loaded only
                // while generating (this local map is released when the task ends) and bounded by the
                // thread's image count, keeping memory honest on the phone.
                let imagesByMessage = imageCapable ? await Self.loadAttachmentImages(for: history, from: store) : [:]
                // Re-read memory before composing, not after: a fact the model saved with `remember` last
                // turn — or one the user just typed on the memory screen — has to be in THIS turn's prompt.
                await self?.memoryBook?.refresh()
                // Base system prompt + the active thread's skill + what's worth remembering for this turn.
                // All three ride the same path into `chatTurns`, so trimming, token accounting, and the
                // model all see exactly what was composed. Composed HERE, not captured at send time, so it
                // sees the memory refreshed just above; if the store is gone there's no one to stream to,
                // so stop rather than generate against an empty prompt.
                guard let systemPrompt = self?.composedSystemPrompt(
                    query: memoryQuery,
                    memoryEnabled: turnMemoryEnabled
                ) else { return }
                let turns = Self.chatTurns(messages: history, systemPrompt: systemPrompt,
                                           cap: params.contextTokenCap,
                                           images: { imagesByMessage[$0.id] ?? [] })
                if toolsOn {
                    // Agent loop: the model may call the local calculator/clock, a Wikipedia lookup, or any
                    // tool exposed by a configured MCP server before answering.
                    guard let registry = try await self?.toolRegistry(
                        config: turnToolConfig,
                        servers: turnMCPServers
                    ) else { return }
                    self?.streaming?.warmingNote = nil   // handshake done — the rest is plain prefill
                    let loop = ToolLoop(engine: engine, registry: registry, dialect: dialect)
                    initialToolLoop: for try await event in loop.run(messages: turns, params: params) {
                        guard let self, self.streaming?.messageID == assistantID else { return }
                        self.applyLoopEvent(event)
                        if case .done = event { break initialToolLoop }
                    }
                } else {
                    initialGeneration: for try await delta in engine.generate(messages: turns, params: params) {
                        guard let self, self.streaming?.messageID == assistantID else { return }
                        self.apply(delta)
                        if case .done = delta { break initialGeneration }
                    }
                }

                // Some reasoning models occasionally stop after emitting only their hidden reasoning —
                // either at a healthy EOS or because the reasoning consumed the token budget. Give those
                // exact outcomes ONE short, answer-only completion pass: no thinking, no ToolLoop/registry,
                // and no recursion. Cancellation, engine errors, stop sequences, and genuinely empty
                // generations all remain terminal as-is.
                try Task.checkCancellation()
                if let first = self?.streaming,
                   first.messageID == assistantID,
                   let firstStopReason = first.stats?.stopReason,
                   firstStopReason == .eos || firstStopReason == .maxTokens,
                   !first.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   first.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.beginAnswerRecovery()
                    var recoveryParams = params
                    recoveryParams.thinking = false
                    recoveryParams.maxTokens = min(max(1, recoveryParams.maxTokens),
                                                   Self.answerRecoveryMaxTokens)
                    let recoveryTurns = Self.answerRecoveryTurns(turns)
                    answerRecovery: for try await delta in engine.generate(
                        messages: recoveryTurns,
                        params: recoveryParams
                    ) {
                        try Task.checkCancellation()
                        guard let self, self.streaming?.messageID == assistantID else { return }
                        switch delta {
                        case .reasoning:
                            // `thinking=false` is the hard request. If a model disobeys it, do not append a
                            // second hidden chain or restart its clock; the original reasoning stays intact.
                            break
                        case .answer, .done:
                            self.apply(delta)
                        }
                        if case .done = delta { break answerRecovery }
                    }
                }
                // A cancelled consumer ends the stream by returning nil (not by throwing), so detect
                // Stop here too — the partial is committed, never discarded (DESIGN §2.3).
                let finalStats = self?.streaming?.stats
                self?.finalizeIfNeeded(
                    assistantID: assistantID,
                    stopReason: Task.isCancelled ? .cancelled : (finalStats?.stopReason ?? .eos),
                    stats: finalStats
                )
            } catch is CancellationError {
                self?.finalizeIfNeeded(assistantID: assistantID, stopReason: .cancelled)
            } catch {
                self?.finalizeIfNeeded(assistantID: assistantID, stopReason: .cancelled, failed: true)
                self?.present(error)
            }
        }
    }

    /// Attachment persistence is part of accepting a send, not an ignorable side effect. If it fails,
    /// remove the provisional user/assistant pair, restore the exact staged images, and put the text back
    /// in the composer. A user may already have started typing the next draft while the write was in
    /// flight, so preserve that text after the restored draft instead of overwriting it.
    private func recoverFailedAttachmentSend(_ rollback: AttachmentSendRollback, error _: Error) {
        var provisionalIDs: Set<UUID> = [rollback.userID]
        if let assistantID = rollback.assistantID { provisionalIDs.insert(assistantID) }
        if let ci = conversations.firstIndex(where: { $0.id == rollback.conversationID }) {
            conversations[ci].messages.removeAll { provisionalIDs.contains($0.id) }
            // Restore only fields that still carry this send's provisional values. A rename, pin, or other
            // main-actor edit made while the disk write was suspended must win over this rollback.
            if let provisionalTitle = rollback.provisionalTitle,
               conversations[ci].title == provisionalTitle {
                conversations[ci].title = rollback.originalTitle
            }
            if let provisionalModelID = rollback.provisionalModelID,
               conversations[ci].modelID == provisionalModelID {
                conversations[ci].modelID = rollback.originalModelID
            }
            if let provisionalVariantID = rollback.provisionalVariantID,
               conversations[ci].variantID == provisionalVariantID {
                conversations[ci].variantID = rollback.originalVariantID
            }
            if let provisionalUpdatedAt = rollback.provisionalUpdatedAt,
               conversations[ci].updatedAt == provisionalUpdatedAt {
                conversations[ci].updatedAt = rollback.originalUpdatedAt
            }
        }

        if !rollback.text.isEmpty {
            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? rollback.text
                : rollback.text + "\n\n" + draft
        }
        let restoredIDs = Set(rollback.stagedImages.map(\.id))
        pendingImages = rollback.stagedImages + pendingImages.filter { !restoredIDs.contains($0.id) }

        if let assistantID = rollback.assistantID, streaming?.messageID == assistantID {
            streaming = nil
            streamingMessageID = nil
        }
        genTask = nil
        showToast(Toast(
            "Couldn't save the attached image. Your draft was restored; check available storage and try again.",
            kind: .error,
            autoDismiss: 6
        ))
    }

    private var cachedRegistry: ToolRegistry?
    private var cachedRegistrySignature: String?

    /// The tool set for a turn: the persisted built-in tools (assembled from `settings.builtInToolConfig`
    /// plus the injected memory / calendar / location seams), then every enabled MCP server's tools layered
    /// on top. Cached by a signature that covers BOTH the built-in config and the servers, so flipping any
    /// tool — a built-in toggle, a search engine, a muted MCP tool — takes effect on the next send, not the
    /// next launch.
    private func toolRegistry(config: BuiltInToolConfig, servers: [MCPServer]) async throws -> ToolRegistry {
        try Task.checkCancellation()
        let signature = Self.registrySignature(config: config, servers: servers)
        if let cachedRegistry, cachedRegistrySignature == signature { return cachedRegistry }

        // The tools get the DURABLE store, not the book: they run inside the agent loop, off the main
        // actor, and the book is only the screen's (and the injector's) main-actor mirror of it.
        let builtIns = ToolRegistry.assemble(config: config, memoryStore: memoryBook?.store,
                                             eventStore: eventStore, locationProvider: locationProvider)
        let registry: ToolRegistry
        if servers.isEmpty {
            registry = builtIns
        } else {
            // `includeStandard: false` yields ONLY the MCP tools, so the assembled built-ins aren't
            // duplicated; the two lists are then concatenated (built-ins advertise first).
            let mcp = try await ToolRegistry.build(mcpServers: servers, includeStandard: false)
            registry = ToolRegistry(builtIns.tools + mcp.tools)
        }
        try Task.checkCancellation()
        cachedRegistry = registry
        cachedRegistrySignature = signature
        return registry
    }

    /// A stable string over everything that changes the assembled tool set — the enabled built-in tools,
    /// the search-engine order, and each enabled server's URL / token / muted tools. Pure + nonisolated so
    /// the cache-invalidation contract is unit-testable off the main actor, without building real registries.
    nonisolated static func registrySignature(config: BuiltInToolConfig, servers: [MCPServer]) -> String {
        let builtins = config.enabled.map(\.rawValue).sorted().joined(separator: "+")
        let engines = config.searchEngines.map(\.rawValue).joined(separator: "+")
        let mcp = servers.map {
            "\($0.url)|\($0.token ?? "")|\($0.disabledTools.sorted().joined(separator: "+"))"
        }.joined(separator: ",")
        return "builtins:[\(builtins)];engines:[\(engines)];mcp:[\(mcp)]"
    }

    /// Map an agent-loop event onto the streaming state — reasoning/answer as usual, plus tool activity.
    private func applyLoopEvent(_ event: ToolLoopEvent) {
        guard streaming != nil else { return }
        switch event {
        case .reasoning(let s): apply(.reasoning(s))
        case .answer(let s): apply(.answer(s))
        case .discardAnswer:
            // Tool-loop text is provisional until that model pass proves it needs no tool. If a call or
            // enforced correction appears later, remove the intermediate prose while keeping reasoning and
            // completed tool rows. This is also the pass boundary when a model emitted reasoning followed
            // directly by call markup, so pause idempotently even when no answer token did it first.
            pauseReasoningClock()
            streaming?.answer = ""
            if streaming?.phase != .stopping {
                let hasReasoning = streaming?.reasoning.isEmpty == false
                streaming?.phase = hasReasoning ? .thinking : .warming
            }
        case .toolCall(let call):
            pauseReasoningClock()
            if streaming?.phase != .stopping {
                // Pre-tool prose is only an intermediate agent-loop step, not the final answer. Restore
                // a live disclosure when there is reasoning to show (otherwise return to warming while
                // the tool runs). The duration remains the accumulated MODEL reasoning only; the tool and
                // its network wait are outside the active clock segment.
                let hasReasoning = streaming?.reasoning.isEmpty == false
                streaming?.phase = hasReasoning ? .thinking : .warming
            }
            streaming?.toolActivity.append(ToolRun(name: call.name, arguments: call.argumentsJSON))
        case .toolResult(_, let result):
            if let n = streaming?.toolActivity.count, n > 0 { streaming?.toolActivity[n - 1].result = result }
        case .done(let stats): apply(.done(stats))
        }
    }

    private func apply(_ delta: EngineDelta) {
        guard streaming != nil else { return }
        switch delta {
        case .reasoning(let s):
            streaming?.warmingNote = nil
            if streaming?.phase != .stopping { streaming?.phase = .thinking }
            // A later tool-loop pass starts a fresh segment. Time spent executing the tool and prefilling
            // this pass occurred before this delta and therefore never enters the accumulated duration.
            if streaming?.thinkingStartedAt == nil { streaming?.thinkingStartedAt = Date() }
            streaming?.reasoning += s
        case .answer(let s):
            // The first answer token closes only the current reasoning segment. Further answer generation
            // is not reasoning time; a later pass may start and add another segment.
            pauseReasoningClock()
            streaming?.warmingNote = nil
            if streaming?.phase != .stopping { streaming?.phase = .answering }
            streaming?.answer += s
        case .done(let stats):
            pauseReasoningClock()
            streaming?.stats = stats
        }
    }

    /// Transition the same live row into its one permitted answer-only completion pass. The original
    /// reasoning and its frozen duration remain untouched; clearing first-pass stats prevents a clean
    /// second stream that omits `.done` from accidentally inheriting the first pass's terminal marker.
    private func beginAnswerRecovery() {
        pauseReasoningClock()
        guard streaming != nil else { return }
        streaming?.answer = ""
        streaming?.stats = nil
        streaming?.phase = .warming
        streaming?.warmingNote = "Finishing answer…"
    }

    /// Close the active reasoning segment and add it to the turn's accumulated reasoning-only duration.
    /// Calling this repeatedly at answer/tool/done boundaries is idempotent because the segment start is
    /// cleared after the first close.
    private func pauseReasoningClock(at now: Date = Date()) {
        guard let started = streaming?.thinkingStartedAt else { return }
        let elapsed = max(0, now.timeIntervalSince(started))
        // Read before opening the observed property's `_modify` accessor. Combining the read and write in
        // one optional-chain assignment overlaps Swift's dynamic exclusivity accesses and crashes when a
        // stream is cancelled while this boundary is being applied.
        let accumulated = streaming?.thinkingDuration ?? 0
        streaming?.thinkingDuration = accumulated + elapsed
        streaming?.thinkingStartedAt = nil
    }

    /// Commit the streamed reasoning/answer into the assistant message + autosave. Called on `.done`,
    /// on clean stream end, and on Stop/cancel (which always commits the partial — never discards).
    private func finalizeIfNeeded(assistantID: UUID, stopReason: StopReason,
                                  stats: Stats? = nil, failed: Bool = false) {
        // Only finalize OUR stream: a just-cancelled generation task can reach here AFTER a new send has
        // started a fresh stream, and an unguarded commit would stamp this task's stop reason onto the new
        // turn (a real race the coverage work surfaced). The messageID gate makes finalize idempotent
        // per-turn — the winning `.done`/stop already niled `streaming`, so a late loser no-ops.
        guard streaming?.messageID == assistantID else { return }
        commit(stopReason: stopReason, stats: stats, failed: failed)
    }

    private func commit(stopReason: StopReason, stats: Stats?, failed: Bool = false) {
        pauseReasoningClock()
        guard let state = streaming,
              let ci = conversations.firstIndex(where: { $0.messages.contains { $0.id == state.messageID } }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == state.messageID }) else {
            streaming = nil
            streamingMessageID = nil
            return
        }
        let visibleAnswer = state.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : state.answer
        conversations[ci].messages[mi].answer = visibleAnswer
        conversations[ci].messages[mi].reasoning = state.reasoning.isEmpty ? nil : state.reasoning
        // Persist model reasoning time only. Tool/MCP/network waits and non-reasoning generation are paused
        // at their boundaries, so "Thought for Xs" does not really mean "the whole tool turn took Xs".
        conversations[ci].messages[mi].thinkingSeconds =
            state.reasoning.isEmpty ? nil : state.thinkingDuration
        conversations[ci].messages[mi].toolRuns = state.toolActivity.isEmpty ? nil : state.toolActivity
        conversations[ci].messages[mi].generatedBy = state.generatedBy
        if visibleAnswer.isEmpty {
            // Nothing was generated — do NOT fake a "0 tok · stop:…" stats line (the ghost reply). Mark
            // the outcome so the row renders a compact Stopped / Failed — Retry instead.
            // Distinguish "you stopped it" from "it ran to EOS with nothing to say" — the second is the
            // model's own outcome and shouldn't read as the user's action.
            conversations[ci].messages[mi].emptyOutcome = failed ? .failed
                : (stopReason == .cancelled ? .stopped : .noReply)
            conversations[ci].messages[mi].stats = nil
        } else {
            conversations[ci].messages[mi].emptyOutcome = nil
            conversations[ci].messages[mi].stats = stats ?? Stats(
                promptTokens: 0, genTokens: 0, promptTPS: 0,
                tokensPerSecond: 0, peakMemoryBytes: 0, stopReason: stopReason)
        }
        conversations[ci].updatedAt = Date()
        let convo = conversations[ci]
        streaming = nil
        streamingMessageID = nil
        genTask = nil
        conversations.sort(by: Self.recency)
        persist(convo)
    }

    /// Cooperative boundary-stop (DESIGN §2.3 critique D1): not instant — lands at the next token
    /// boundary and always commits the partial answer. Always honored — the accidental-double-tap
    /// protection lives on the composer's Stop BUTTON (briefly disabled after send), not here, so an
    /// intentional stop during a long warm-up still works.
    public func stop() {
        // Agent runtime mode: Stop is a durable cancel command, not a task cancellation.
        if agentRuntimeEnabled,
           let agentRuns,
           let conversationID = activeConversation?.id,
           agentRuns.presentation(for: conversationID) != nil
        {
            pauseReasoningClock()
            streaming?.phase = .stopping
            Task { await agentRuns.cancel(conversationID: conversationID) }
            return
        }
        guard streaming != nil else { return }
        pauseReasoningClock()
        streaming?.phase = .stopping
        genTask?.cancel()
    }

    // MARK: - Skills (per-conversation instruction packs; Skills v1)

    /// The skill activated for the active thread, or nil when none is set OR the referenced skill was
    /// deleted (nil-safe resolution: a dangling `skillID` simply resolves to no skill, and composition
    /// falls back to the base system prompt).
    public var activeSkill: Skill? {
        guard let id = activeConversation?.skillID else { return nil }
        return skillStore?.skill(id: id)
    }

    /// Every skill available to pick from the composer menu (empty when no store is wired).
    public var availableSkills: [Skill] { skillStore?.skills ?? [] }

    /// Persist a per-conversation skill selection (nil clears it). Does NOT bump `updatedAt` — activating a
    /// skill is a config change, not a message, so it must not reorder the conversation list.
    public func setSkill(_ skillID: UUID?, for conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }),
              conversations[i].skillID != skillID else { return }
        conversations[i].skillID = skillID
        persist(conversations[i])
    }

    /// Set the skill on the ACTIVE thread from the composer, creating an empty thread first if there isn't
    /// one — so the Skill menu works before the first message (mirrors how `send` lazily creates a thread).
    public func setActiveSkill(_ skillID: UUID?) {
        guard let convo = activeConversation ?? newConversation() else { return }
        setSkill(skillID, for: convo.id)
    }

    /// The system prompt for a turn: the base prompt, the active skill's instruction fragment, and the
    /// facts worth remembering for `query` (blank — the default — means the freshest few). Both the
    /// generation path (`startGeneration`) and the context meter (`contextUsage`) route through this, so
    /// every part is charged to the window exactly once and shown honestly.
    func composedSystemPrompt(query: String = "", memoryEnabled: Bool? = nil) -> String {
        Self.systemPrompt(base: settings.systemPrompt, skill: activeSkill,
                          memoryBlock: memoryBlock(for: query, enabled: memoryEnabled))
    }

    /// Pure composition (unit-tested): `base` + `"\n\n## Active skill: <name>\n<instructions>"` when a skill
    /// is active, then the memory block. A blank base (system prompt "off") yields just the fragments, so a
    /// skill — and memory — still work. Nonisolated + pure so the composition contract is unit-testable off
    /// the main actor.
    nonisolated static func systemPrompt(base: String, skill: Skill?, memoryBlock: String? = nil) -> String {
        var parts: [String] = []
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBase.isEmpty { parts.append(base) }
        if let skill { parts.append("## Active skill: \(skill.name)\n\(skill.instructions)") }
        if let memoryBlock, !memoryBlock.isEmpty { parts.append(memoryBlock) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Memory (auto-recall into the prompt)

    /// The memory block for `query`, or nil when memory is switched off (`AppSettings.memoryEnabled`),
    /// unwired, or empty. Reads the book's main-actor mirror — `startGeneration` refreshes it right before
    /// composing, and the meter shows whatever the last refresh left.
    private func memoryBlock(for query: String, enabled: Bool? = nil) -> String? {
        guard enabled ?? settings.memoryEnabled,
              let facts = memoryBook?.facts, !facts.isEmpty else { return nil }
        return Self.memoryBlock(facts, query: query)
    }

    /// The search query for the memory block: the outgoing user turn, plus the one before it. A follow-up
    /// often can't stand alone ("and his birthday?"), so one turn of carry-over is what makes the right
    /// fact surface — but only one: more history dilutes the token scoring into "everything matches".
    /// `draft` is the text not yet sent (the meter's view of the next turn); on the send path it's already
    /// in `history`, so it's left empty there.
    nonisolated static func memoryQuery(draft: String = "", history: [Message]) -> String {
        let recentUserTurns = history.filter { $0.role == .user && !$0.answer.isEmpty }.suffix(2).map(\.answer)
        return ([draft] + recentUserTurns).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The "what you remember" block: the top `limit` facts for `query`, one per line, hard-capped at
    /// `maxChars` — the whole point is a small model reading a short list, and an unbounded block would eat
    /// the 4K window it has to answer in. Model-saved notes use canonical English. If a query in another
    /// language has no lexical hit, the newest notes are the small deterministic fallback; `recall` keeps
    /// strict search semantics and asks the model for English search terms. Each line is clipped first, so
    /// one rambling fact can't crowd the rest out; then lines are taken while the block fits.
    /// Pure + nonisolated so the bound is unit-testable off the main actor.
    nonisolated static func memoryBlock(_ facts: [MemoryFact], query: String,
                                        limit: Int = 5, maxChars: Int = 400) -> String? {
        let header = "## What you remember about the user\n"
            + "These notes are already saved; use them as facts and never call remember for them. "
            + "Notes are stored in English, but reply in the user's language."
        let matches = MemoryRanking.rank(facts, query: query, limit: limit)
        let selected = matches.isEmpty
            ? MemoryRanking.rank(facts, query: "", limit: limit)
            : matches
        var block = header
        for fact in selected {
            let flat = fact.text.replacingOccurrences(of: "\n", with: " ")
            let line = "\n- " + (flat.count > 120 ? String(flat.prefix(120)) + "…" : flat)
            guard block.count + line.count <= maxChars else { break }
            block += line
        }
        return block == header ? nil : block
    }

    // MARK: - Context meter

    /// Tokens currently used by the active thread's context vs the cap (composer meter; DESIGN §4).
    public func contextUsage() -> (used: Int, cap: Int) {
        // The meter must show the cap the engine actually runs at, not the requested one.
        let cap: Int
        if isOnlineActive {
            // Online providers are not bounded by device RAM: the setting is the cap (up to the service
            // window) instead of a local checkpoint's native context.
            cap = min(onlineContextRequest, OnlineModelIdentity.maximumContextTokens)
        } else if let model = activeModel?.model {
            cap = ContextPolicy.effective(requested: localContextRequest, model: model)
        } else {
            cap = localContextRequest
        }
        guard let convo = activeConversation else { return (0, cap) }
        // CJK-aware throughout (`TokenEstimate`) so a Chinese thread's meter isn't ~3× under. The active
        // skill's instructions AND the memory block ride the composed system prompt, so they're counted
        // here too. Memory is searched with the query the NEXT send would use — draft included — because a
        // meter that warns you after the injection pushed you over the window is no warning at all. (So the
        // count can shift slightly as you type, when the draft brings different facts into range; the
        // block's cap bounds that to a few tokens.)
        let system = composedSystemPrompt(query: Self.memoryQuery(draft: draft, history: convo.messages))
        var used = system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : TokenEstimate.tokens(in: system)
        for message in convo.messages where !message.answer.isEmpty { used += message.approximateTokens }
        used += streaming.map { TokenEstimate.tokens(in: $0.answer) + TokenEstimate.tokens(in: $0.reasoning) } ?? 0
        return (used, cap)
    }

    // MARK: - Toasts

    public func showToast(_ toast: Toast, action: (@MainActor () -> Void)? = nil) {
        bannerDismissTask?.cancel()
        banner = toast
        bannerAction = action
        if let seconds = toast.autoDismiss {
            let id = toast.id
            bannerDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if self?.banner?.id == id { self?.banner = nil; self?.bannerAction = nil }
            }
        }
    }

    public func runBannerAction() {
        let action = bannerAction
        banner = nil
        bannerAction = nil
        action?()
    }

    public func dismissBanner() { banner = nil; bannerAction = nil }

    /// Map an engine/runtime error to a banner with a forward action (DESIGN §2.5).
    private func present(_ error: Error) {
        if error is CancellationError { return }
        switch error {
        case ThermalError.pausedForHeat:
            showToast(Toast("Paused to let the device cool — it'll resume automatically.",
                            kind: .warning, autoDismiss: 4))
        case let activation as ModelActivationError:
            showToast(Toast(activation.message, kind: .error, actionTitle: activation.forwardTitle,
                            autoDismiss: nil))
        default:
            showToast(Toast(error.localizedDescription, kind: .error, autoDismiss: 4))
        }
    }

    // MARK: - Persistence

    private func persist(_ conversation: Conversation) {
        guard !conversationEraseInProgress else { return }
        persistenceSequence &+= 1
        let sequence = persistenceSequence
        let epoch = persistenceEpoch
        let predecessor = persistenceTail
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            guard self.persistenceEpoch == epoch, !self.conversationEraseInProgress else {
                self.completePersistence(sequence: sequence)
                return
            }
            do {
                try await self.store.save(conversation)
                guard self.persistenceEpoch == epoch, !self.conversationEraseInProgress else {
                    self.completePersistence(sequence: sequence)
                    return
                }
                self.pendingSaveFailures[conversation.id] = nil   // this thread is safe on disk again
            } catch {
                guard self.persistenceEpoch == epoch, !self.conversationEraseInProgress else {
                    self.completePersistence(sequence: sequence)
                    return
                }
                // Disk full / unwritable: don't lose the turn silently. Remember it for Retry and surface
                // one banner for the burst.
                self.pendingSaveFailures[conversation.id] = conversation
                self.surfacePersistFailure()
            }
            self.completePersistence(sequence: sequence)
        }
        persistenceTail = task
    }

    private func completePersistence(sequence: UInt64) {
        if persistenceSequence == sequence {
            persistenceTail = nil
        }
    }

    /// One save-failure banner per burst: suppressed while its banner is still on screen, re-shown once
    /// that banner is gone and a later save fails.
    private func surfacePersistFailure() {
        if let id = persistFailureBannerID, banner?.id == id { return }
        let toast = Toast("Couldn't save changes — the device may be out of storage.",
                          kind: .error, actionTitle: "Retry", autoDismiss: nil)
        persistFailureBannerID = toast.id
        showToast(toast, action: { [weak self] in self?.retryPersist() })
    }

    private func retryPersist() {
        let pending = Array(pendingSaveFailures.values)
        pendingSaveFailures.removeAll()
        for convo in pending { persist(convo) }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Trim history to `cap` tokens, ALWAYS keeping the system turn (DESIGN §2.3). Assistant turns are
    /// fed back as their answer text only (reasoning is not re-sent). Empty placeholder turns are
    /// skipped — but a user turn that carries image attachments is kept even with no text (a "describe
    /// this" turn). The most recent turn is kept even if it alone exceeds the budget. `images` supplies
    /// the (already-loaded) encoded bytes for a message's attachments; user turns carry them to the
    /// vision engine.
    public static func chatTurns(messages: [Message], systemPrompt: String?, cap: Int,
                                 images: (Message) -> [Data] = { _ in [] }) -> [ChatTurn] {
        var systemTurn: ChatTurn?
        var systemTokens = 0
        if let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            systemTurn = ChatTurn(role: .system, content: prompt)
            systemTokens = TokenEstimate.tokens(in: prompt)   // CJK-aware, matching the per-message estimate
        }
        let candidates = messages.filter { $0.role != .system && ($0.hasVisibleContent) }
        var budget = max(0, cap - systemTokens)
        var kept: [ChatTurn] = []
        for message in candidates.reversed() {
            let tokens = message.approximateTokens
            if !kept.isEmpty && tokens > budget { break }
            let role: ChatTurn.Role = message.role == .assistant ? .assistant : .user
            let turnImages = role == .user ? images(message) : []
            kept.append(ChatTurn(role: role, content: message.answer, images: turnImages))
            budget -= tokens
            if budget <= 0 { break }
        }
        // Auto-compaction (DESIGN §2.3): rather than silently dropping the oldest turns, leave the model a
        // breadcrumb of what they were about — an extractive summary of the dropped user turns (no extra
        // model call). This keeps continuity on the small on-device contexts where trimming bites often.
        let dropped = Array(candidates.dropLast(kept.count))
        let note = compactionNote(dropped)

        var turns: [ChatTurn] = []
        if let systemTurn { turns.append(systemTurn) }
        if let note { turns.append(ChatTurn(role: .system, content: note)) }
        turns.append(contentsOf: kept.reversed())
        return turns
    }

    /// Add the narrow instruction used by the single reasoning-only recovery pass. It deliberately
    /// contains no tool declarations and does not replay the first pass's private reasoning as conversation
    /// content: the same user request is enough to ask for the missing visible answer, while keeping hidden
    /// reasoning out of a synthetic prompt and out of the eventual answer.
    static func answerRecoveryTurns(_ messages: [ChatTurn]) -> [ChatTurn] {
        let instruction = """
        The previous attempt produced internal reasoning but ended before producing a user-visible answer. \
        Complete the same turn now. Output only the final answer: do not think aloud, repeat hidden \
        reasoning, call tools, or emit tool-call markup. Reply in the language of the latest user request.
        """
        var recovered = messages
        if let index = recovered.firstIndex(where: { $0.role == .system }) {
            let separator = recovered[index].content.isEmpty ? "" : "\n\n"
            recovered[index] = ChatTurn(
                role: .system,
                content: recovered[index].content + separator + instruction,
                images: recovered[index].images
            )
        } else {
            recovered.insert(ChatTurn(role: .system, content: instruction), at: 0)
        }
        return recovered
    }

    /// Load the encoded image bytes for every attachment across `messages` (current thread only), keyed by
    /// message id, for `chatTurns`' image provider. Awaits the store actor per file; the returned map is a
    /// generation-scoped local that's released when the caller's task ends (memory discipline).
    static func loadAttachmentImages(for messages: [Message],
                                     from store: ConversationStore) async -> [UUID: [Data]] {
        var result: [UUID: [Data]] = [:]
        for message in messages {
            guard let refs = message.attachments, !refs.isEmpty else { continue }
            var datas: [Data] = []
            for ref in refs {
                if let data = await store.attachmentData(ref.id) { datas.append(data) }
            }
            if !datas.isEmpty { result[message.id] = datas }
        }
        return result
    }

    /// A compact system note summarizing dropped turns, or nil when nothing was dropped.
    static func compactionNote(_ dropped: [Message]) -> String? {
        let topics = dropped.filter { $0.role == .user }
            .map { firstFragment($0.answer) }.filter { !$0.isEmpty }
        guard !topics.isEmpty else { return nil }
        let recent = topics.suffix(6).joined(separator: "; ")
        return "[Earlier in this conversation, older turns were summarized to save space. The user "
             + "previously asked about: \(recent). Ask if you need those details again.]"
    }

    private static func firstFragment(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(60)) + "…" : t
    }

    /// First-line title from the first user message, trimmed to a reasonable length.
    static func autoTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : (trimmed.isEmpty ? "New Chat" : trimmed)
    }
}
