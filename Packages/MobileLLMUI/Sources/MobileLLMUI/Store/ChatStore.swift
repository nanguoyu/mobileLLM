// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime
import LLMCore

/// The @MainActor UI state owner (DESIGN §2.3). Holds the conversation mirror + the live streaming
/// state, talks to the `LLMEngine` actor over an `AsyncThrowingStream`, and autosaves through
/// `ConversationStore`. Only the small streaming strings mutate per token, so the message list never
/// churns mid-stream.
@MainActor
@Observable
public final class ChatStore {

    // MARK: - Published state

    /// The in-memory mirror of live conversations, newest first (pinned on top).
    public internal(set) var conversations: [Conversation] = []
    public var activeID: UUID?
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
    /// How long a soft-deleted conversation stays undoable in-session before its file is purged from disk
    /// (the privacy promise — a deleted chat mustn't linger). Matches the Undo banner's auto-dismiss.
    static let undoWindow: TimeInterval = 5
    /// Tombstones older than this are swept (hard-deleted) on the next `load()`.
    static let tombstoneRetention: TimeInterval = 24 * 60 * 60
    /// Set by the app shell: reloads the active model if it was suspended to free memory while idle.
    /// Awaited right before generation, so a suspended big model comes back on the next send.
    public var ensureModelReady: (@Sendable () async -> Void)?

    public init(engine: any LLMEngine, store: ConversationStore, settings: AppSettings,
                activeModel: LoadedModel? = nil,
                memoryBook: MemoryBook? = nil,
                eventStore: (any EventStoring)? = nil,
                locationProvider: (any LocationProviding)? = nil,
                skillStore: SkillStore? = nil) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.activeModel = activeModel
        self.memoryBook = memoryBook
        self.eventStore = eventStore
        self.locationProvider = locationProvider
        self.skillStore = skillStore
        self.thinkingEnabled = settings.thinkingDefault
    }

    // MARK: - Loading

    /// Hydrate the mirror from disk (call once at launch). Sweeps stale tombstones first so a deleted
    /// chat doesn't survive on disk past its retention window (DESIGN §2.4 — the privacy promise).
    public func load() async {
        await store.sweepExpiredTombstones(olderThan: Self.tombstoneRetention)
        conversations = await store.loadAllLive().sorted(by: Self.recency)
        if activeID == nil { activeID = conversations.first?.id }
    }

    private static func recency(_ a: Conversation, _ b: Conversation) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.updatedAt > b.updatedAt
    }

    public var activeConversation: Conversation? {
        guard let activeID else { return nil }
        return conversations.first { $0.id == activeID }
    }

    public var isStreaming: Bool { streaming != nil }
    public var hasModel: Bool { activeModel != nil }
    public var canSend: Bool {
        hasModel && streaming == nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
    }

    // MARK: - Composer attachments

    /// Room for another staged image (the photo affordance disables at the cap).
    public var canAttachMoreImages: Bool { pendingImages.count < Self.maxAttachments }

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
        if let existing = conversations.first(where: { $0.messages.isEmpty }),
           let i = conversations.firstIndex(where: { $0.id == existing.id }) {
            // Reusing a leftover empty thread must also refresh its model seed — it may have been
            // created under a different model, and a stale seed survives relaunch as a surprise switch.
            if let m = activeModel {
                conversations[i].modelID = m.model.id
                conversations[i].variantID = m.variant.id
                persist(conversations[i])
            }
            activeID = existing.id
            return conversations[i]
        }
        let convo = Conversation(modelID: activeModel?.model.id ?? settings.defaultModelID,
                                 variantID: activeModel?.variant.id ?? "")
        conversations.insert(convo, at: 0)
        activeID = convo.id
        // Persisted immediately (not on first send): a relaunch should land back on the fresh thread the
        // user just opened — and on its model — not on the previous conversation. At most one empty
        // thread ever exists (the reuse branch above), so this never litters the list.
        persist(convo)
        return convo
    }

    /// Set by the app shell: activate the given (modelID, variantID) if installed. Called when the user
    /// opens a conversation whose remembered model differs from the resident one — a thread keeps ITS
    /// model across relaunches instead of silently falling back to the Settings default.
    public var restoreModel: (@MainActor (_ modelID: String, _ variantID: String) -> Void)?

    public func select(_ id: UUID) {
        activeID = id
        restoreConversationModelIfNeeded()
    }

    /// Ask the shell to bring back the active conversation's own model when it differs from the resident
    /// one. Never mid-stream; empty ids (a modelless placeholder thread) are left alone.
    public func restoreConversationModelIfNeeded() {
        guard streaming == nil, let convo = activeConversation,
              !convo.modelID.isEmpty, convo.modelID != activeModel?.model.id else { return }
        restoreModel?(convo.modelID, convo.variantID)
    }

    /// Clear the in-memory mirror after a full data wipe (Settings → Delete all data).
    public func reloadAfterWipe() {
        stop()
        conversations = []
        activeID = nil
    }

    public func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].title = trimmed
        persist(conversations[i])
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
        conversations.removeAll { $0.id == id }
        if activeID == id { activeID = conversations.first?.id }
        // Optimistic: offer Undo instantly. The disk write + failure-rollback happen behind it.
        showToast(Toast("Conversation deleted", actionTitle: "Undo", autoDismiss: Self.undoWindow),
                  action: { [weak self] in self?.restore(removed) })
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.softDelete(id)
                self.scheduleTombstoneSweep(id)
            } catch {
                // Roll the mirror back — disk still has it live, so the list must too (guarded so a race
                // with a just-tapped Undo can't double-insert it).
                if !self.conversations.contains(where: { $0.id == id }) {
                    self.conversations.append(removed)
                    self.conversations.sort(by: Self.recency)
                    self.activeID = previousActive
                }
                self.showToast(Toast("Couldn't delete the conversation.", kind: .error, autoDismiss: 4))
            }
        }
    }

    private func restore(_ convo: Conversation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.restore(convo.id)   // only re-add on success, else mirror/disk diverge
                self.conversations.append(convo)
                self.conversations.sort(by: Self.recency)
                self.activeID = convo.id
            } catch {
                self.showToast(Toast("Couldn't restore the conversation.", kind: .error, autoDismiss: 4))
            }
        }
    }

    /// Purge a soft-deleted conversation's file once its in-session Undo window has passed — unless it was
    /// undone (restored back into the mirror). Keeps the tombstone honest without stranding data on disk.
    private func scheduleTombstoneSweep(_ id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.undoWindow + 0.5) * 1_000_000_000))
            guard let self, !self.conversations.contains(where: { $0.id == id }) else { return }
            try? await self.store.hardDelete(id)
        }
    }

    // MARK: - Sending

    /// Send the composer draft (text and/or staged images): append the user turn + an empty assistant
    /// turn, then stream a reply. An image-only turn (no text) is allowed for vision models.
    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages.map(\.data)
        guard !text.isEmpty || !images.isEmpty, activeModel != nil, streaming == nil else { return }

        // The MLX engine has no mtmd image path. Rather than silently drop the images and answer text-only,
        // block the send with an actionable toast so the user can switch this model to its GGUF variant
        // (C2.3). Draft + staged images are kept so the retry after switching loses nothing.
        if !images.isEmpty, activeModel?.variant.engine == .mlx {
            showToast(Toast("This engine can't read images yet — switch this model to its GGUF (llama.cpp) variant.",
                            kind: .warning, autoDismiss: 5))
            return
        }

        draft = ""
        clearPendingImages()
        guard let convo = activeConversation ?? newConversation(),
              let idx = conversations.firstIndex(where: { $0.id == convo.id }) else { return }

        // Reference the attached images by id; the bytes are written to disk (never inlined in the record).
        let refs = images.map { _ in ImageRef() }
        let user = Message(role: .user, answer: text, attachments: refs.isEmpty ? nil : refs)
        conversations[idx].messages.append(user)
        // Auto-title from the first user line (model-summarized titling is TODO(v1.0)).
        if conversations[idx].messages.filter({ $0.role == .user }).count == 1 {
            conversations[idx].title = Self.autoTitle(from: text)
        }
        // Stamp the model that's actually answering on EVERY send — the record tracks the thread's
        // CURRENT model, so reopening the app restores what you were really using, not the first pick.
        if let m = activeModel {
            conversations[idx].modelID = m.model.id
            conversations[idx].variantID = m.variant.id
        }
        let assistant = Message(role: .assistant, answer: "", parentID: user.id)
        conversations[idx].messages.append(assistant)
        conversations[idx].updatedAt = Date()

        let attachments = zip(refs, images).map { (id: $0.0.id, data: $0.1) }
        startGeneration(assistantID: assistant.id, in: conversations[idx].id, writeAttachments: attachments)
    }

    /// Regenerate an assistant turn: drop it (and anything after) and stream a fresh reply to the
    /// preceding user turn. `parentID` is preserved for the v1.0 branch pager.
    public func regenerate(assistantMessageID: UUID) {
        guard streaming == nil, let ci = conversations.firstIndex(where: { $0.id == activeID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantMessageID }),
              conversations[ci].messages[mi].role == .assistant else { return }
        let parentID = conversations[ci].messages[mi].parentID
        purgeAttachments(of: Array(conversations[ci].messages[mi...]))
        conversations[ci].messages.removeSubrange(mi...)
        let fresh = Message(role: .assistant, answer: "", parentID: parentID)
        conversations[ci].messages.append(fresh)
        conversations[ci].updatedAt = Date()
        startGeneration(assistantID: fresh.id, in: conversations[ci].id)
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
        let assistant = Message(role: .assistant, answer: "", parentID: userMessageID)
        conversations[ci].messages.append(assistant)
        conversations[ci].updatedAt = Date()
        startGeneration(assistantID: assistant.id, in: conversations[ci].id)
    }

    private func startGeneration(assistantID: UUID, in conversationID: UUID,
                                 writeAttachments: [(id: UUID, data: Data)] = []) {
        guard let convo = conversations.first(where: { $0.id == conversationID }) else { return }
        var state = StreamingState(messageID: assistantID)
        state.phase = .warming
        // Only a real network handshake earns the note — local tools connect to nothing, and a lingering
        // "Connecting tools…" over plain prefill reads as a hang. Cleared as soon as the registry is up.
        if settings.toolsEnabled, settings.mcpServers.contains(where: { $0.isEnabled && !$0.url.isEmpty }) {
            state.warmingNote = "Connecting tools…"
        }
        streaming = state
        streamingMessageID = assistantID

        let history = convo.messages.filter { $0.id != assistantID }
        // "Hidden" thinking ⇒ don't GENERATE reasoning. This model's think-boundary isn't a literal
        // <think> tag we can reliably strip from the shown text, so the only sure way to hide it is off.
        let params = settings.sampling(thinking: thinkingEnabled && settings.thinkingDisplay != .hidden,
                                       model: activeModel?.model)
        // What this turn asks about — the query the memory block is searched with, below.
        let memoryQuery = Self.memoryQuery(history: history)
        let engine = self.engine
        let toolsOn = settings.toolsEnabled
        let store = self.store
        // Declare tools in the ACTIVE model's own dialect. Every family was post-trained on its own tool
        // syntax; handed a stranger's, a model improvises something we then can't read — which is how
        // tools were silently dead on every non-ChatML model (see `ToolDialect`). Falls back to the Qwen
        // convention when no model is active, matching the loop's own default.
        let dialect = activeModel.map { ToolDialect($0.model.architecture.promptTemplate) } ?? .qwen
        // Replay history images only when the ACTIVE model can actually see them (llama.cpp + projector).
        // After switching an image-bearing thread to a text-only model, the engine would refuse the whole
        // conversation otherwise — history degrades to text, exactly like the engine-side guard.
        let imageCapable = activeModel.map { $0.variant.engine == .llamaCpp && $0.variant.supportsVisionInput } ?? false

        genTask = Task { @MainActor [weak self] in
            do {
                // Persist this turn's attachment bytes to disk FIRST, so the reload-from-disk below (and
                // any later follow-up / history replay) sees them. Files, not inline JSON (the privacy +
                // record-size promise).
                for a in writeAttachments { try? await store.writeAttachment(a.data, id: a.id) }
                await self?.ensureModelReady?()   // reload if the model was suspended to free memory
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
                guard let systemPrompt = self?.composedSystemPrompt(query: memoryQuery) else { return }
                let turns = Self.chatTurns(messages: history, systemPrompt: systemPrompt,
                                           cap: params.contextTokenCap,
                                           images: { imagesByMessage[$0.id] ?? [] })
                if toolsOn {
                    // Agent loop: the model may call the local calculator/clock, a Wikipedia lookup, or any
                    // tool exposed by a configured MCP server before answering.
                    let registry = await self?.toolRegistry() ?? .standard
                    self?.streaming?.warmingNote = nil   // handshake done — the rest is plain prefill
                    let loop = ToolLoop(engine: engine, registry: registry, dialect: dialect)
                    for try await event in loop.run(messages: turns, params: params) {
                        guard let self, self.streaming?.messageID == assistantID else { return }
                        self.applyLoopEvent(event)
                    }
                } else {
                    for try await delta in engine.generate(messages: turns, params: params) {
                        guard let self, self.streaming?.messageID == assistantID else { return }
                        self.apply(delta)
                    }
                }
                // A cancelled consumer ends the stream by returning nil (not by throwing), so detect
                // Stop here too — the partial is committed, never discarded (DESIGN §2.3).
                self?.finalizeIfNeeded(assistantID: assistantID, stopReason: Task.isCancelled ? .cancelled : .eos)
            } catch is CancellationError {
                self?.finalizeIfNeeded(assistantID: assistantID, stopReason: .cancelled)
            } catch {
                self?.finalizeIfNeeded(assistantID: assistantID, stopReason: .cancelled, failed: true)
                self?.present(error)
            }
        }
    }

    private var cachedRegistry: ToolRegistry?
    private var cachedRegistrySignature: String?

    /// The tool set for a turn: the persisted built-in tools (assembled from `settings.builtInToolConfig`
    /// plus the injected memory / calendar / location seams), then every enabled MCP server's tools layered
    /// on top. Cached by a signature that covers BOTH the built-in config and the servers, so flipping any
    /// tool — a built-in toggle, a search engine, a muted MCP tool — takes effect on the next send, not the
    /// next launch.
    private func toolRegistry() async -> ToolRegistry {
        let config = settings.builtInToolConfig
        let servers = settings.mcpServers.filter {
            $0.isEnabled && !$0.url.trimmingCharacters(in: .whitespaces).isEmpty
        }
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
            let mcp = await ToolRegistry.build(mcpServers: servers, includeStandard: false)
            registry = ToolRegistry(builtIns.tools + mcp.tools)
        }
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
        case .toolCall(let call):
            if streaming?.phase != .stopping { streaming?.phase = .answering }
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
            if streaming?.phase != .stopping { streaming?.phase = .thinking }
            if streaming?.thinkingStartedAt == nil { streaming?.thinkingStartedAt = Date() }
            streaming?.reasoning += s
        case .answer(let s):
            // First answer token freezes the thinking duration + collapses the disclosure.
            if streaming?.thinkingDuration == nil, let started = streaming?.thinkingStartedAt {
                streaming?.thinkingDuration = Date().timeIntervalSince(started)
            }
            if streaming?.phase != .stopping { streaming?.phase = .answering }
            streaming?.answer += s
        case .done(let stats):
            streaming?.stats = stats
            commit(stopReason: stats.stopReason, stats: stats)
        }
    }

    /// Commit the streamed reasoning/answer into the assistant message + autosave. Called on `.done`,
    /// on clean stream end, and on Stop/cancel (which always commits the partial — never discards).
    private func finalizeIfNeeded(assistantID: UUID, stopReason: StopReason, failed: Bool = false) {
        // Only finalize OUR stream: a just-cancelled generation task can reach here AFTER a new send has
        // started a fresh stream, and an unguarded commit would stamp this task's stop reason onto the new
        // turn (a real race the coverage work surfaced). The messageID gate makes finalize idempotent
        // per-turn — the winning `.done`/stop already niled `streaming`, so a late loser no-ops.
        guard streaming?.messageID == assistantID else { return }
        commit(stopReason: stopReason, stats: nil, failed: failed)
    }

    private func commit(stopReason: StopReason, stats: Stats?, failed: Bool = false) {
        guard let state = streaming,
              let ci = conversations.firstIndex(where: { $0.messages.contains { $0.id == state.messageID } }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == state.messageID }) else {
            streaming = nil
            streamingMessageID = nil
            return
        }
        conversations[ci].messages[mi].answer = state.answer
        conversations[ci].messages[mi].reasoning = state.reasoning.isEmpty ? nil : state.reasoning
        // Persist the real thinking wall-clock so the collapsed tile shows an honest "Thought for Xs".
        conversations[ci].messages[mi].thinkingSeconds =
            state.reasoning.isEmpty ? nil : (state.thinkingDuration ?? state.thinkingStartedAt.map { Date().timeIntervalSince($0) })
        conversations[ci].messages[mi].toolRuns = state.toolActivity.isEmpty ? nil : state.toolActivity
        if state.answer.isEmpty {
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
        guard streaming != nil else { return }
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
    func composedSystemPrompt(query: String = "") -> String {
        Self.systemPrompt(base: settings.systemPrompt, skill: activeSkill, memoryBlock: memoryBlock(for: query))
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
    private func memoryBlock(for query: String) -> String? {
        guard settings.memoryEnabled, let facts = memoryBook?.facts, !facts.isEmpty else { return nil }
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
    /// the 4K window it has to answer in. Each line is clipped first, so one rambling fact can't crowd the
    /// rest out; then lines are taken while the block fits. Nil when nothing survives.
    /// Pure + nonisolated so the bound is unit-testable off the main actor.
    nonisolated static func memoryBlock(_ facts: [MemoryFact], query: String,
                                        limit: Int = 5, maxChars: Int = 400) -> String? {
        let header = "## What you remember about the user"
        var block = header
        for fact in MemoryRanking.rank(facts, query: query, limit: limit) {
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
        let cap = settings.effectiveContext(for: activeModel?.model)
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.store.save(conversation)
                self.pendingSaveFailures[conversation.id] = nil   // this thread is safe on disk again
            } catch {
                // Disk full / unwritable: don't lose the turn silently. Remember it for Retry and surface
                // one banner for the burst.
                self.pendingSaveFailures[conversation.id] = conversation
                self.surfacePersistFailure()
            }
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
