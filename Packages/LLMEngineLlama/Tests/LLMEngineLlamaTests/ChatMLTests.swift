// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@testable import LLMEngineLlama

/// The ChatML prompt builder: full-history threading + the thinking-suppression pre-fill.
final class ChatMLTests: XCTestCase {

    func testThreadsFullHistoryInOrder() {
        let msgs = [
            ChatTurn(role: .system, content: "You are helpful."),
            ChatTurn(role: .user, content: "Hi"),
            ChatTurn(role: .assistant, content: "Hello!"),
            ChatTurn(role: .user, content: "Bye"),
        ]
        let p = LlamaEngine.buildChatML(messages: msgs, thinking: true)
        XCTAssertEqual(p, """
        <|im_start|>system
        You are helpful.<|im_end|>
        <|im_start|>user
        Hi<|im_end|>
        <|im_start|>assistant
        Hello!<|im_end|>
        <|im_start|>user
        Bye<|im_end|>
        <|im_start|>assistant

        """)
    }

    func testThinkingOnLeavesGenerationOpen() {
        let p = LlamaEngine.buildChatML(messages: [ChatTurn(role: .user, content: "Q")], thinking: true)
        XCTAssertTrue(p.hasSuffix("<|im_start|>assistant\n"), "thinking-on must not pre-fill a think block")
        XCTAssertFalse(p.contains("</think>"))
    }

    func testThinkingOffPrefillsEmptyThinkBlock() {
        let p = LlamaEngine.buildChatML(messages: [ChatTurn(role: .user, content: "Q")], thinking: false)
        XCTAssertTrue(p.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"),
                      "thinking-off must pre-fill an empty think block so nothing lands in .reasoning")
    }
}
