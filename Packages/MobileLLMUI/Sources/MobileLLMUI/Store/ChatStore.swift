// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
    /// The model the engine is loaded with (kept in sync with `ModelManager.active` at the app shell).
    public var activeModel: LoadedModel?
    /// The composer's per-thread thinking toggle (seeded from Settings' default).
    public var thinkingEnabled: Bool
    public private(set) var banner: Toast?

    // MARK: - Dependencies

    private let engine: any LLMEngine
    private let store: ConversationStore
    private let settings: AppSettings
    private var genTask: Task<Void, Never>?
    /// The forward action attached to the current banner (Undo / Switch model), kept out of `Toast`
    /// so the value type stays `Equatable`.
    private var bannerAction: (@MainActor () -> Void)?
    private var bannerDismissTask: Task<Void, Never>?
    /// Set by the app shell: reloads the active model if it was suspended to free memory while idle.
    /// Awaited right before generation, so a suspended big model comes back on the next send.
    public var ensureModelReady: (@Sendable () async -> Void)?

    public init(engine: any LLMEngine, store: ConversationStore, settings: AppSettings,
                activeModel: LoadedModel? = nil) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.activeModel = activeModel
        self.thinkingEnabled = settings.thinkingDefault
    }

    // MARK: - Loading

    /// Hydrate the mirror from disk (call once at launch).
    public func load() async {
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
        hasModel && streaming == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Conversation lifecycle

    /// Create + activate a fresh conversation for the current model (no-op if the newest thread is
    /// already an empty, unused one).
    @discardableResult
    public func newConversation() -> Conversation? {
        guard let m = activeModel else { return nil }
        if let existing = conversations.first(where: { $0.messages.isEmpty }) {
            activeID = existing.id
            return existing
        }
        let convo = Conversation(modelID: m.model.id, variantID: m.variant.id)
        conversations.insert(convo, at: 0)
        activeID = convo.id
        return convo
    }

    public func select(_ id: UUID) { activeID = id }

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
    public func delete(_ id: UUID) {
        guard let removed = conversations.first(where: { $0.id == id }) else { return }
        conversations.removeAll { $0.id == id }
        if activeID == id { activeID = conversations.first?.id }
        Task { try? await store.softDelete(id) }
        showToast(Toast("Conversation deleted", actionTitle: "Undo", autoDismiss: 5), action: { [weak self] in
            self?.restore(removed)
        })
    }

    private func restore(_ convo: Conversation) {
        Task {
            try? await store.restore(convo.id)
            conversations.append(convo)
            conversations.sort(by: Self.recency)
            activeID = convo.id
        }
    }

    // MARK: - Sending

    /// Send the composer draft: append the user turn + an empty assistant turn, then stream a reply.
    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeModel != nil, streaming == nil else { return }
        draft = ""
        guard let convo = activeConversation ?? newConversation(),
              let idx = conversations.firstIndex(where: { $0.id == convo.id }) else { return }

        let user = Message(role: .user, answer: text)
        conversations[idx].messages.append(user)
        // Auto-title from the first user line (model-summarized titling is TODO(v1.0)).
        if conversations[idx].messages.filter({ $0.role == .user }).count == 1 {
            conversations[idx].title = Self.autoTitle(from: text)
        }
        let assistant = Message(role: .assistant, answer: "", parentID: user.id)
        conversations[idx].messages.append(assistant)
        conversations[idx].updatedAt = Date()

        startGeneration(assistantID: assistant.id, in: conversations[idx].id)
    }

    /// Regenerate an assistant turn: drop it (and anything after) and stream a fresh reply to the
    /// preceding user turn. `parentID` is preserved for the v1.0 branch pager.
    public func regenerate(assistantMessageID: UUID) {
        guard streaming == nil, let ci = conversations.firstIndex(where: { $0.id == activeID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == assistantMessageID }),
              conversations[ci].messages[mi].role == .assistant else { return }
        let parentID = conversations[ci].messages[mi].parentID
        conversations[ci].messages.removeSubrange(mi...)
        let fresh = Message(role: .assistant, answer: "", parentID: parentID)
        conversations[ci].messages.append(fresh)
        conversations[ci].updatedAt = Date()
        startGeneration(assistantID: fresh.id, in: conversations[ci].id)
    }

    /// Edit a user turn and resend: truncate from it, replace the text, and regenerate (branch pager
    /// UI is TODO(v1.0); the `parentID` plumbing is in place).
    public func editAndResend(userMessageID: UUID, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, streaming == nil,
              let ci = conversations.firstIndex(where: { $0.id == activeID }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == userMessageID }),
              conversations[ci].messages[mi].role == .user else { return }
        conversations[ci].messages.removeSubrange((mi + 1)...)
        conversations[ci].messages[mi].answer = text
        let assistant = Message(role: .assistant, answer: "", parentID: userMessageID)
        conversations[ci].messages.append(assistant)
        conversations[ci].updatedAt = Date()
        startGeneration(assistantID: assistant.id, in: conversations[ci].id)
    }

    private func startGeneration(assistantID: UUID, in conversationID: UUID) {
        guard let convo = conversations.first(where: { $0.id == conversationID }) else { return }
        var state = StreamingState(messageID: assistantID)
        state.phase = .warming
        streaming = state

        let history = convo.messages.filter { $0.id != assistantID }
        // "Hidden" thinking ⇒ don't GENERATE reasoning. This model's think-boundary isn't a literal
        // <think> tag we can reliably strip from the shown text, so the only sure way to hide it is off.
        let params = settings.sampling(thinking: thinkingEnabled && settings.thinkingDisplay != .hidden)
        let turns = Self.chatTurns(messages: history, systemPrompt: settings.systemPrompt, cap: params.contextTokenCap)
        let engine = self.engine

        genTask = Task { @MainActor [weak self] in
            do {
                await self?.ensureModelReady?()   // reload if the model was suspended to free memory
                for try await delta in engine.generate(messages: turns, params: params) {
                    guard let self, self.streaming?.messageID == assistantID else { return }
                    self.apply(delta)
                }
                // A cancelled consumer ends the stream by returning nil (not by throwing), so detect
                // Stop here too — the partial is committed, never discarded (DESIGN §2.3).
                self?.finalizeIfNeeded(stopReason: Task.isCancelled ? .cancelled : .eos)
            } catch is CancellationError {
                self?.finalizeIfNeeded(stopReason: .cancelled)
            } catch {
                self?.finalizeIfNeeded(stopReason: .cancelled)
                self?.present(error)
            }
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
    private func finalizeIfNeeded(stopReason: StopReason) {
        guard streaming != nil else { return }   // already committed by `.done`
        commit(stopReason: stopReason, stats: nil)
    }

    private func commit(stopReason: StopReason, stats: Stats?) {
        guard let state = streaming,
              let ci = conversations.firstIndex(where: { $0.messages.contains { $0.id == state.messageID } }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == state.messageID }) else {
            streaming = nil
            return
        }
        conversations[ci].messages[mi].answer = state.answer
        conversations[ci].messages[mi].reasoning = state.reasoning.isEmpty ? nil : state.reasoning
        conversations[ci].messages[mi].stats = stats ?? Stats(
            promptTokens: 0, genTokens: 0, promptTPS: 0,
            tokensPerSecond: 0, peakMemoryBytes: 0, stopReason: stopReason)
        conversations[ci].updatedAt = Date()
        let convo = conversations[ci]
        streaming = nil
        genTask = nil
        conversations.sort(by: Self.recency)
        persist(convo)
    }

    /// Cooperative boundary-stop (DESIGN §2.3 critique D1): not instant — lands at the next token
    /// boundary and always commits the partial answer.
    public func stop() {
        guard streaming != nil else { return }
        streaming?.phase = .stopping
        genTask?.cancel()
    }

    // MARK: - Context meter

    /// Tokens currently used by the active thread's context vs the cap (composer meter; DESIGN §4).
    public func contextUsage() -> (used: Int, cap: Int) {
        let cap = settings.contextLength
        guard let convo = activeConversation else { return (0, cap) }
        var used = max(1, settings.systemPrompt.count / 4)
        if settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { used = 0 }
        for message in convo.messages where !message.answer.isEmpty { used += message.approximateTokens }
        used += streaming.map { max(0, ($0.answer.count + $0.reasoning.count) / 4) } ?? 0
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
        Task { try? await store.save(conversation) }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Trim history to `cap` tokens, ALWAYS keeping the system turn (DESIGN §2.3). Assistant turns are
    /// fed back as their answer text only (reasoning is not re-sent). Empty placeholder turns are
    /// skipped. The most recent turn is kept even if it alone exceeds the budget.
    public static func chatTurns(messages: [Message], systemPrompt: String?, cap: Int) -> [ChatTurn] {
        var systemTurn: ChatTurn?
        var systemTokens = 0
        if let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            systemTurn = ChatTurn(role: .system, content: prompt)
            systemTokens = max(1, prompt.count / 4)
        }
        let candidates = messages.filter { $0.role != .system && !$0.answer.isEmpty }
        var budget = max(0, cap - systemTokens)
        var kept: [ChatTurn] = []
        for message in candidates.reversed() {
            let tokens = message.approximateTokens
            if !kept.isEmpty && tokens > budget { break }
            let role: ChatTurn.Role = message.role == .assistant ? .assistant : .user
            kept.append(ChatTurn(role: role, content: message.answer))
            budget -= tokens
            if budget <= 0 { break }
        }
        var turns: [ChatTurn] = []
        if let systemTurn { turns.append(systemTurn) }
        turns.append(contentsOf: kept.reversed())
        return turns
    }

    /// First-line title from the first user message, trimmed to a reasonable length.
    static func autoTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : (trimmed.isEmpty ? "New Chat" : trimmed)
    }
}
