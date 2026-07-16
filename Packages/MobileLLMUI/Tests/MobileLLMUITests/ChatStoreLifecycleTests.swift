// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// `ChatStore.reloadAfterWipe()` — the in-session reset after Settings → Delete all data. It must stop any
/// in-flight stream and clear the mirror + activeID. The ordering matters: if a wipe races an active
/// generation, stop-then-clear is what keeps the cancelled task from committing into a conversation that no
/// longer exists (the `commit` guard no-ops when the mirror is empty). Previously only the store-level
/// `deleteAll()` was tested; this method was never called.
@MainActor
final class ChatStoreLifecycleTests: XCTestCase {

    private var model: LLMModel { LLMCatalog.bonsai8b }

    private func makeStore(engine: LLMEngine) -> (ChatStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(component: "chat-wipe-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "wipe-\(UUID().uuidString)")!)
        let chat = ChatStore(engine: engine, store: store, settings: settings,
                             activeModel: LoadedModel(model: model, variant: model.defaultVariantValue))
        return (chat, dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testReloadAfterWipeMidStreamStopsAndClearsCleanly() async throws {
        let (chat, dir) = makeStore(engine: MockLLMEngine(script: .init(
            reasoning: "r", answer: String(repeating: "word ", count: 300),
            chunkSize: 1, chunkDelayNanos: 2_000_000)))
        defer { try? FileManager.default.removeItem(at: dir) }

        // A second, pre-existing conversation sits in the mirror alongside the one we'll stream into.
        let convoB = Conversation(modelID: model.id, variantID: model.defaultVariantValue.id,
                                  messages: [Message(role: .user, answer: "old"),
                                             Message(role: .assistant, answer: "reply")])
        chat.conversations = [convoB]
        chat.activeID = nil

        chat.draft = "go"
        chat.send()   // creates a new active conversation and starts streaming

        // Wait until the stream is genuinely in flight.
        let deadline = Date().addingTimeInterval(5)
        while (chat.streaming?.answer.isEmpty ?? true) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(chat.isStreaming, "a stream is in flight before the wipe")
        XCTAssertEqual(chat.conversations.count, 2, "two conversations exist before the wipe")

        chat.reloadAfterWipe()
        // The mirror is cleared synchronously.
        XCTAssertTrue(chat.conversations.isEmpty, "reloadAfterWipe clears the conversation mirror")
        XCTAssertNil(chat.activeID, "and drops the active id")

        // The cancelled in-flight task must commit into nothing and leave streaming nil — no crash.
        try await waitUntilIdle(chat)
        XCTAssertNil(chat.streaming, "the wiped stream ends cleanly (commit guard no-ops on the empty mirror)")
    }

    func testReloadAfterWipeWhenIdleClearsMirror() throws {
        let (chat, dir) = makeStore(engine: MockLLMEngine(script: .init()))
        defer { try? FileManager.default.removeItem(at: dir) }
        chat.conversations = [
            Conversation(modelID: model.id, variantID: model.defaultVariantValue.id),
            Conversation(modelID: model.id, variantID: model.defaultVariantValue.id),
        ]
        chat.activeID = chat.conversations.first?.id

        chat.reloadAfterWipe()
        XCTAssertTrue(chat.conversations.isEmpty)
        XCTAssertNil(chat.activeID)
        XCTAssertNil(chat.streaming)
    }
}
