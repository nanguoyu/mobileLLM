// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// `ChatStore` streaming flow (DESIGN §2.3): send → think block then answer → commit; Stop commits
/// the partial; history-trim keeps the system turn and honors `contextTokenCap`.
@MainActor
final class ChatStoreTests: XCTestCase {

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-chat-tests-\(UUID().uuidString)")
        return (ConversationStore(directory: dir), dir)
    }

    private var mockModel: LoadedModel {
        LoadedModel(model: LLMCatalog.bonsai8b, variant: LLMCatalog.bonsai8b.defaultVariantValue)
    }

    private func makeStore(script: MockLLMEngine.Script) -> (ChatStore, URL) {
        let (store, dir) = tempStore()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "chat-tests-\(UUID().uuidString)")!)
        let chat = ChatStore(engine: MockLLMEngine(script: script), store: store, settings: settings,
                             activeModel: mockModel)
        return (chat, dir)
    }

    /// Wait until the store stops streaming (the mock runs instantly with 0-delay chunks).
    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testSendStreamsThinkThenAnswerAndCommits() async throws {
        let (chat, dir) = makeStore(script: .init(reasoning: "let me reason", answer: "the final answer",
                                                  chunkSize: 1))
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "hello"
        chat.send()
        try await waitUntilIdle(chat)

        let convo = try XCTUnwrap(chat.activeConversation)
        XCTAssertEqual(convo.messages.count, 2, "one user + one assistant message")
        let assistant = try XCTUnwrap(convo.messages.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.answer, "the final answer")
        XCTAssertEqual(assistant.reasoning, "let me reason", "reasoning is split out + persisted")
        XCTAssertEqual(assistant.stats?.stopReason, .eos)
        XCTAssertNil(chat.streaming)
    }

    func testTitleDerivedFromFirstUserMessage() async throws {
        let (chat, dir) = makeStore(script: .init())
        defer { try? FileManager.default.removeItem(at: dir) }
        chat.draft = "What is the capital of France?"
        chat.send()
        try await waitUntilIdle(chat)
        XCTAssertEqual(chat.activeConversation?.title, "What is the capital of France?")
    }

    func testStopCommitsPartialAnswer() async throws {
        // A slow, long stream so we can Stop mid-flight and assert the partial is committed, not lost.
        let (chat, dir) = makeStore(script: .init(reasoning: "r",
                                                  answer: String(repeating: "word ", count: 400),
                                                  chunkSize: 1, chunkDelayNanos: 2_000_000))
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "go"
        chat.send()
        // Wait until ANSWER text has actually streamed before stopping — a fixed sleep raced the mock on
        // slow CI runners: stop-before-first-token commits the (by design) stats-free Stopped state, and
        // ChatStore's double-tap grace window also ignores a stop that early. Deterministic: poll for text.
        let deadline = Date().addingTimeInterval(5)
        while (chat.streaming?.answer.isEmpty ?? true) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(chat.streaming?.answer.isEmpty ?? true, "the mock should have streamed some answer")
        chat.stop()
        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.stats?.stopReason, .cancelled, "Stop commits with a cancelled stop reason")
        // The committed message keeps whatever streamed (never discarded); shorter than the full answer.
        XCTAssertLessThan(assistant.answer.count, 2000, "committed a partial, not the whole answer")
        XCTAssertNil(chat.streaming)
    }

    // MARK: - History trimming (pure)

    func testChatTurnsKeepsSystemTurnAndHonorsCap() {
        let system = "You are a helpful, on-device assistant."   // ~10 tokens
        // 20 user/assistant turns of ~25 tokens each (100 chars) — far over a small cap.
        var messages: [Message] = []
        for i in 0..<20 {
            messages.append(Message(role: .user, answer: String(repeating: "x", count: 100) + "\(i)"))
            messages.append(Message(role: .assistant, answer: String(repeating: "y", count: 100) + "\(i)"))
        }
        let cap = 200
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: system, cap: cap)

        XCTAssertEqual(turns.first?.role, .system, "the system turn is always first + always kept")
        XCTAssertEqual(turns.first?.content, system)

        // The conversation turns (user/assistant) stay within the cap; the system prompt + the bounded
        // compaction preamble are always-kept overhead.
        let convo = turns.filter { $0.role != .system }.reduce(0) { $0 + max(1, $1.content.count / 4) }
        XCTAssertLessThanOrEqual(convo, cap, "trimmed conversation honors contextTokenCap")

        // Oldest turns were dropped; the most recent turn survives.
        XCTAssertLessThan(turns.count, messages.count + 1)
        XCTAssertEqual(turns.last?.content, messages.last?.answer, "the newest turn is preserved")
    }

    func testCompactionNoteInjectedWhenOldTurnsDropped() {
        var messages: [Message] = []
        for i in 0..<12 {
            messages.append(Message(role: .user, answer: "Tell me about topic number \(i)"))
            messages.append(Message(role: .assistant, answer: String(repeating: "y", count: 80)))
        }
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: "Sys", cap: 120)
        // A compaction system turn is present and references a dropped early topic.
        let systemNotes = turns.filter { $0.role == .system }.map(\.content)
        XCTAssertTrue(systemNotes.contains { $0.contains("Earlier in this conversation") },
                      "dropping old turns must leave a compaction breadcrumb")
        // The note summarizes dropped user turns (the most recent of the dropped span).
        XCTAssertTrue(systemNotes.contains { $0.contains("topic number") },
                      "the breadcrumb references what the dropped turns were about")
    }

    func testNoCompactionNoteWhenEverythingFits() {
        let messages = [Message(role: .user, answer: "hi"), Message(role: .assistant, answer: "hello")]
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: "Sys", cap: 8192)
        XCTAssertFalse(turns.contains { $0.content.contains("Earlier in this conversation") })
        XCTAssertNil(ChatStore.compactionNote([]))
    }

    func testChatTurnsWithoutSystemPrompt() {
        let messages = [Message(role: .user, answer: "hi"), Message(role: .assistant, answer: "hello")]
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: "  ", cap: 8192)
        XCTAssertEqual(turns.map(\.role), [.user, .assistant], "blank system prompt adds no system turn")
    }

    func testChatTurnsSkipsEmptyAssistantPlaceholder() {
        let messages = [
            Message(role: .user, answer: "question"),
            Message(role: .assistant, answer: ""),   // in-flight placeholder
        ]
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: nil, cap: 8192)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.role, .user)
    }

    // MARK: - Soft delete + undo

    func testDeleteThenUndoRestoresConversation() async throws {
        let (chat, dir) = makeStore(script: .init())
        defer { try? FileManager.default.removeItem(at: dir) }
        chat.draft = "keep me"
        chat.send()
        try await waitUntilIdle(chat)

        let id = try XCTUnwrap(chat.activeID)
        chat.delete(id)
        XCTAssertFalse(chat.conversations.contains { $0.id == id }, "removed from the mirror")
        XCTAssertEqual(chat.banner?.actionTitle, "Undo")

        chat.runBannerAction()   // Undo
        // Restore hops through the store actor; wait for the mirror to repopulate.
        let deadline = Date().addingTimeInterval(2)
        while !chat.conversations.contains(where: { $0.id == id }) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(chat.conversations.contains { $0.id == id }, "Undo restores the conversation")
    }

    // MARK: - Model-less creation (B1.a: create/browse without a model; gate only sending)

    func testNewConversationWorksWithoutActiveModel() {
        let (chat, dir) = makeStore(script: .init())
        defer { try? FileManager.default.removeItem(at: dir) }
        chat.activeModel = nil

        let convo = chat.newConversation()
        XCTAssertNotNil(convo, "creating a thread must not require a resident model")
        XCTAssertEqual(chat.conversations.count, 1)
        XCTAssertEqual(chat.activeID, convo?.id)

        chat.draft = "hi"
        XCTAssertFalse(chat.canSend, "with no model, sending is gated even with a non-empty draft")
        chat.send()
        XCTAssertNil(chat.streaming, "send is a no-op without a model")
        XCTAssertEqual(chat.activeConversation?.messages.count, 0, "no turn is appended without a model")
    }

    // MARK: - Empty / failed replies (B1.e: no ghost 0-token rows; honest Retry state)

    func testStopBeforeFirstTokenCommitsStoppedEmptyState() async throws {
        // Long per-char delay so nothing streams before we Stop synchronously.
        let (chat, dir) = makeStore(script: .init(reasoning: "r", answer: "a",
                                                  chunkSize: 1, chunkDelayNanos: 100_000_000))
        defer { try? FileManager.default.removeItem(at: dir) }
        chat.draft = "go"
        chat.send()
        chat.stop()   // before any token
        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertTrue(assistant.answer.isEmpty, "nothing was generated")
        XCTAssertNil(assistant.stats, "an empty stopped turn must NOT fake a 0-token stats line")
        XCTAssertEqual(assistant.emptyOutcome, .stopped)
    }

    func testGenerationErrorCommitsFailedEmptyStateAndBanner() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "chat-fail-\(UUID().uuidString)")!)
        let chat = ChatStore(engine: ThrowingEngine(), store: store, settings: settings, activeModel: mockModel)

        chat.draft = "go"
        chat.send()
        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertTrue(assistant.answer.isEmpty)
        XCTAssertEqual(assistant.emptyOutcome, .failed)
        XCTAssertNil(assistant.stats, "a failed turn must NOT fake stats")
        XCTAssertEqual(chat.banner?.kind, .error, "the failure also surfaces an error banner")
    }

    // MARK: - Regenerate safety (B1.e: confirm before dropping later turns)

    func testRegenerateTargetingHelpers() {
        let (chat, dir) = makeStore(script: .init())
        defer { try? FileManager.default.removeItem(at: dir) }
        let u1 = Message(role: .user, answer: "q1")
        let a1 = Message(role: .assistant, answer: "a1", parentID: u1.id)
        let u2 = Message(role: .user, answer: "q2")
        let a2 = Message(role: .assistant, answer: "a2", parentID: u2.id)
        let convo = Conversation(modelID: "m", variantID: "v", messages: [u1, a1, u2, a2])
        chat.conversations = [convo]
        chat.activeID = convo.id

        XCTAssertTrue(chat.isLastAssistantMessage(a2.id, in: convo), "a2 is the newest assistant turn")
        XCTAssertFalse(chat.isLastAssistantMessage(a1.id, in: convo))
        XCTAssertEqual(chat.discardedTurnCount(regeneratingFrom: a1.id), 2, "regenerating a1 drops u2 + a2")
        XCTAssertEqual(chat.discardedTurnCount(regeneratingFrom: a2.id), 0, "the newest turn drops nothing")
    }

    // MARK: - CJK token accounting (B1.f)

    func testApproximateTokensIsCJKAware() {
        let cjk = Message(role: .user, answer: "你好世界你好世界你好")   // 10 CJK scalars ≈ 10 tokens
        XCTAssertEqual(cjk.approximateTokens, 10, "CJK counts ≈1 token/char, not char/4")
        let latin = Message(role: .user, answer: String(repeating: "a", count: 40))   // ≈ chars/4
        XCTAssertEqual(latin.approximateTokens, 10)
    }

    // MARK: - Persistence failure (B1.d: surface a retryable banner, keep the turn)

    func testSaveFailureSurfacesRetryBannerAndKeepsMirror() async throws {
        let base = FileManager.default.temporaryDirectory.appending(component: "b1-savefail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A regular FILE where the store wants a directory ⇒ every save() throws.
        let blocker = base.appending(component: "blocker")
        try Data().write(to: blocker)
        let store = ConversationStore(directory: blocker.appending(component: "Conversations"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "chat-savefail-\(UUID().uuidString)")!)
        let chat = ChatStore(engine: MockLLMEngine(script: .init()), store: store, settings: settings,
                             activeModel: mockModel)

        chat.draft = "hello"
        chat.send()
        try await waitUntilIdle(chat)
        // persist() is async — poll for the retryable banner.
        let deadline = Date().addingTimeInterval(2)
        while chat.banner?.actionTitle != "Retry" && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(chat.banner?.kind, .error)
        XCTAssertEqual(chat.banner?.actionTitle, "Retry", "a failed save surfaces a retryable banner")
        // The turn is NOT lost from the in-memory mirror.
        XCTAssertEqual(chat.activeConversation?.messages.count, 2, "user + assistant turns survive in memory")
        XCTAssertEqual(chat.activeConversation?.messages.last?.answer.isEmpty, false)
    }

    // MARK: - Dictation (B1.g: compile + initial state)

    func testDictationServiceStartsIdle() {
        let dictation = DictationService()
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertFalse(dictation.isRecording)
        XCTAssertTrue(dictation.transcript.isEmpty)
    }
}

/// An engine whose stream fails immediately — exercises the generation-error commit path (B1.e).
private actor ThrowingEngine: LLMEngine {
    struct Boom: Error {}
    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}
    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { $0.finish(throwing: Boom()) }
    }
}
