// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// `chatTurns` image handling (C2.3): the image provider attaches bytes to USER turns only, an image-only
/// user turn (no text) is still sent, and history replay carries earlier image turns for follow-ups.
@MainActor
final class ChatTurnsImageTests: XCTestCase {

    func testImagesAttachToUserTurnsOnly() {
        let first = Message(role: .user, answer: "look", attachments: [ImageRef()])
        let messages = [
            first,
            Message(role: .assistant, answer: "I see a cat"),
            Message(role: .user, answer: "and now?"),
        ]
        let img = Data([0x01, 0x02, 0x03])
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: nil, cap: 8192,
                                        images: { $0.id == first.id ? [img] : [] })
        let userTurns = turns.filter { $0.role == .user }
        XCTAssertEqual(userTurns.first?.images, [img], "the image rides the turn it was attached to")
        XCTAssertEqual(userTurns.last?.images, [], "a later text turn carries no image")
        XCTAssertTrue(turns.filter { $0.role == .assistant }.allSatisfy { $0.images.isEmpty },
                      "assistant turns never carry images")
    }

    func testImageOnlyUserTurnIsKept() {
        // No text, but an attachment — a "describe this" turn must still be sent (with its image).
        let messages = [Message(role: .user, answer: "", attachments: [ImageRef()])]
        let img = Data([0xAA, 0xBB])
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: nil, cap: 8192,
                                        images: { _ in [img] })
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.role, .user)
        XCTAssertEqual(turns.first?.content, "")
        XCTAssertEqual(turns.first?.images, [img])
    }

    func testTextlessTurnWithoutAttachmentsIsStillSkipped() {
        // The in-flight assistant placeholder (empty, no attachments) is still dropped — behavior preserved.
        let messages = [Message(role: .user, answer: "q"), Message(role: .assistant, answer: "")]
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: nil, cap: 8192)
        XCTAssertEqual(turns.map(\.role), [.user])
    }

    func testDefaultProviderYieldsNoImages() {
        // Back-compat: the default `images` provider (used everywhere text-only) attaches nothing.
        let messages = [Message(role: .user, answer: "hi", attachments: [ImageRef()])]
        let turns = ChatStore.chatTurns(messages: messages, systemPrompt: nil, cap: 8192)
        XCTAssertEqual(turns.first?.images, [], "no provider ⇒ no images (the text path is unchanged)")
    }
}
