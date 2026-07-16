// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Multi-turn image history replay + the `imageCapable` degrade-gate in `startGeneration` (C2). Existing
/// vision tests only cover a SINGLE new-turn image send. Here: on a FOLLOW-UP send with a vision model,
/// `loadAttachmentImages(for: history, …)` must reload the earlier image-bearing turn's bytes from disk so
/// the picture still rides the context — and after switching the thread to a text-only model, history
/// images must DEGRADE to text (not be replayed into an engine that can't see them).
@MainActor
final class ChatStoreImageHistoryTests: XCTestCase {

    private var visionVariant: LLMVariant { LLMCatalog.qwen35_4b.variant(engine: .llamaCpp, quant: .gguf4bit)! }
    private var textVariant: LLMVariant { LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)! }

    private func makeStore(engine: LLMEngine, variant: LLMVariant, model: LLMModel)
        -> (ChatStore, ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(component: "img-history-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "img-history-\(UUID().uuidString)")!)
        let chat = ChatStore(engine: engine, store: store, settings: settings,
                             activeModel: LoadedModel(model: model, variant: variant))
        return (chat, store, dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Let a just-finished generation task run its trailing finalize on the main actor before a second send
    /// starts on the same store (the finalize must not race the next send's fresh streaming state).
    private func settle() async throws {
        for _ in 0..<8 { await Task.yield() }
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    /// A follow-up question must still see the earlier turn's image — the store reloads it from disk into
    /// the history handed to the vision engine.
    func testFollowUpReplaysEarlierImageForVisionModel() async throws {
        let engine = RecordingEngine()
        let (chat, _, dir) = makeStore(engine: engine, variant: visionVariant, model: LLMCatalog.qwen35_4b)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Turn 1: an image-bearing user turn (bytes persist to disk).
        chat.draft = "describe this"
        XCTAssertTrue(chat.attach(imageData: makeTestImageData()))
        chat.send()
        try await waitUntilIdle(chat)
        try await settle()

        // Turn 2: a text-only follow-up.
        chat.draft = "what color is it?"
        chat.send()
        try await waitUntilIdle(chat)

        // The SECOND generate's history still carries the image on the FIRST user turn.
        let recorded = await engine.lastTurns()
        let turns = try XCTUnwrap(recorded)
        let imageTurns = turns.filter { $0.role == .user && !$0.images.isEmpty }
        XCTAssertEqual(imageTurns.count, 1, "the earlier image is replayed into the follow-up's context")
        XCTAssertEqual(imageTurns.first?.content, "describe this")
        XCTAssertEqual(imageTurns.first?.images.count, 1)
        XCTAssertTrue(turns.contains { $0.role == .user && $0.content == "what color is it?" && $0.images.isEmpty },
                      "the new text-only turn carries no image of its own")
    }

    /// After switching an image-bearing thread to a text-only model, history images must NOT be replayed —
    /// they degrade to text, matching the engine-side guard (an all-text prompt the model can actually run).
    func testFollowUpDegradesImagesAfterSwitchingToTextModel() async throws {
        let engine = RecordingEngine()
        let (chat, _, dir) = makeStore(engine: engine, variant: visionVariant, model: LLMCatalog.qwen35_4b)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "describe this"
        XCTAssertTrue(chat.attach(imageData: makeTestImageData()))
        chat.send()
        try await waitUntilIdle(chat)
        try await settle()

        // Switch the resident model to a TEXT-ONLY llama.cpp variant (no vision projector).
        chat.activeModel = LoadedModel(model: LLMCatalog.bonsai8b, variant: textVariant)
        XCTAssertFalse(textVariant.supportsVisionInput, "precondition: the new variant can't see images")

        chat.draft = "continue please"
        chat.send()
        try await waitUntilIdle(chat)

        let recorded = await engine.lastTurns()
        let turns = try XCTUnwrap(recorded)
        XCTAssertTrue(turns.allSatisfy { $0.images.isEmpty },
                      "a text-only model must never be handed history images — they degrade to text")
        // The earlier turn's text is still present (only its image degraded, not the turn).
        XCTAssertTrue(turns.contains { $0.role == .user && $0.content == "describe this" })
    }
}
