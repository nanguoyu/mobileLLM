// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
        // Let a little of the answer stream in, then stop.
        try await Task.sleep(nanoseconds: 60_000_000)
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

        // Total estimated tokens stay within the cap (system + kept turns).
        let total = turns.reduce(0) { $0 + max(1, $1.content.count / 4) }
        XCTAssertLessThanOrEqual(total, cap, "trimmed history honors contextTokenCap")

        // Oldest turns were dropped; the most recent turn survives.
        XCTAssertLessThan(turns.count, messages.count + 1)
        XCTAssertEqual(turns.last?.content, messages.last?.answer, "the newest turn is preserved")
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
}
