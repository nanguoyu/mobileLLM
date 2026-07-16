// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// `regenerate(assistantMessageID:)` and `editAndResend(userMessageID:newText:)` — only the pure targeting
/// helpers were tested before; neither mutator was ever called. These drive the real flows and assert the
/// three contracts that matter: later turns are dropped from the mirror, a fresh reply streams + commits,
/// and — the stated privacy promise — the DROPPED image-bearing turns' pixels leave disk (regenerate/edit
/// must not "quietly leak orphans", per the code's own warning), while KEPT turns' pixels stay.
@MainActor
final class ChatStoreRegenerateEditTests: XCTestCase {

    private var model: LLMModel { LLMCatalog.bonsai8b }

    private func makeStore() -> (ChatStore, ConversationStore, RecordingEngine, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(component: "chat-regen-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "regen-\(UUID().uuidString)")!)
        let engine = RecordingEngine()
        let chat = ChatStore(engine: engine, store: store, settings: settings,
                             activeModel: LoadedModel(model: model, variant: model.defaultVariantValue))
        return (chat, store, engine, dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Poll `attachmentData` until it reaches `expectingNil` (the purge is a fire-and-forget Task).
    private func pollAttachment(_ store: ConversationStore, _ id: UUID,
                                expectingNil: Bool, timeout: TimeInterval = 2) async throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let data = await store.attachmentData(id)
            if (data == nil) == expectingNil { return data }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return await store.attachmentData(id)
    }

    // MARK: - regenerate

    func testRegenerateDropsLaterTurnsPurgesAttachmentsAndCommitsFresh() async throws {
        let (chat, store, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // u1 / a1 / u2(image) / a2 — regenerating a1 must drop a1, u2, a2 (and u2's image bytes).
        let droppedRef = ImageRef()
        try await store.writeAttachment(makeTestImageData(), id: droppedRef.id)
        let u1 = Message(role: .user, answer: "first question")
        let a1 = Message(role: .assistant, answer: "first answer", parentID: u1.id)
        let u2 = Message(role: .user, answer: "second question", attachments: [droppedRef])
        let a2 = Message(role: .assistant, answer: "second answer", parentID: u2.id)
        let convo = Conversation(modelID: model.id, variantID: model.defaultVariantValue.id,
                                 messages: [u1, a1, u2, a2])
        chat.conversations = [convo]
        chat.activeID = convo.id
        let precondition = await store.attachmentData(droppedRef.id)
        XCTAssertNotNil(precondition, "precondition: the image is on disk")

        chat.regenerate(assistantMessageID: a1.id)
        try await waitUntilIdle(chat)

        let msgs = try XCTUnwrap(chat.activeConversation?.messages)
        XCTAssertEqual(msgs.count, 2, "everything from a1 onward is dropped, then one fresh assistant is added")
        XCTAssertEqual(msgs[0].id, u1.id, "the preceding user turn survives")
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertNotEqual(msgs[1].id, a1.id, "the regenerated turn is a NEW message")
        XCTAssertEqual(msgs[1].parentID, u1.id, "the fresh reply is parented to the same user turn (branch plumbing)")
        XCTAssertEqual(msgs[1].answer, "ok", "a fresh reply streamed and committed")
        XCTAssertFalse(msgs.contains { $0.id == u2.id || $0.id == a2.id }, "the later turns are gone")

        let purged = try await pollAttachment(store, droppedRef.id, expectingNil: true)
        XCTAssertNil(purged, "the dropped image-bearing turn's pixels are purged from disk")
    }

    // MARK: - editAndResend

    func testEditAndResendTruncatesReplacesTextPurgesDroppedButKeepsEditedTurnsImage() async throws {
        let (chat, store, engine, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // u1(image, kept) / a1 / u2(image, dropped) / a2 — editing u1 drops a1, u2, a2.
        let keptRef = ImageRef()
        let droppedRef = ImageRef()
        try await store.writeAttachment(makeTestImageData(), id: keptRef.id)
        try await store.writeAttachment(makeTestImageData(), id: droppedRef.id)
        let u1 = Message(role: .user, answer: "original question", attachments: [keptRef])
        let a1 = Message(role: .assistant, answer: "first answer", parentID: u1.id)
        let u2 = Message(role: .user, answer: "second question", attachments: [droppedRef])
        let a2 = Message(role: .assistant, answer: "second answer", parentID: u2.id)
        let convo = Conversation(modelID: model.id, variantID: model.defaultVariantValue.id,
                                 messages: [u1, a1, u2, a2])
        chat.conversations = [convo]
        chat.activeID = convo.id

        chat.editAndResend(userMessageID: u1.id, newText: "edited question")
        try await waitUntilIdle(chat)

        let msgs = try XCTUnwrap(chat.activeConversation?.messages)
        XCTAssertEqual(msgs.count, 2, "everything after u1 is dropped, then a fresh assistant is added")
        XCTAssertEqual(msgs[0].id, u1.id)
        XCTAssertEqual(msgs[0].answer, "edited question", "the user turn's text is replaced")
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].parentID, u1.id)
        XCTAssertEqual(msgs[1].answer, "ok", "a fresh reply streamed and committed")

        // The engine saw the edited text on the resent turn.
        let recorded = await engine.lastTurns()
        let turns = try XCTUnwrap(recorded)
        XCTAssertTrue(turns.contains { $0.role == .user && $0.content == "edited question" },
                      "the edited text is what actually reaches the engine")

        // Purge targets only the DROPPED turn's pixels; the kept (edited) turn's image stays.
        let droppedData = try await pollAttachment(store, droppedRef.id, expectingNil: true)
        XCTAssertNil(droppedData, "the dropped turn's image is purged")
        let keptData = try await pollAttachment(store, keptRef.id, expectingNil: false)
        XCTAssertNotNil(keptData, "the surviving (edited) turn's image is NOT purged")
    }

    /// Editing to blank text is a no-op (guarded) — nothing truncates, nothing purges.
    func testEditAndResendIgnoresBlankText() async throws {
        let (chat, store, _, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = ImageRef()
        try await store.writeAttachment(makeTestImageData(), id: ref.id)
        let u1 = Message(role: .user, answer: "q1")
        let a1 = Message(role: .assistant, answer: "a1", parentID: u1.id)
        let u2 = Message(role: .user, answer: "q2", attachments: [ref])
        let convo = Conversation(modelID: model.id, variantID: model.defaultVariantValue.id,
                                 messages: [u1, a1, u2])
        chat.conversations = [convo]
        chat.activeID = convo.id

        chat.editAndResend(userMessageID: u1.id, newText: "   ")
        XCTAssertEqual(chat.activeConversation?.messages.count, 3, "blank edit changes nothing")
        XCTAssertNil(chat.streaming, "no generation starts")
        let stillThere = await store.attachmentData(ref.id)
        XCTAssertNotNil(stillThere, "no attachment is purged on a no-op edit")
    }
}
