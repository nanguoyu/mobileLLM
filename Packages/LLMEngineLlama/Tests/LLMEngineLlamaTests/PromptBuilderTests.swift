// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@testable import LLMEngineLlama

/// The per-model prompt builders + reasoning-control suffix. Special tokens here were verified
/// byte-for-byte against each model's published tokenizer config (fullwidth ｜ U+FF5C, ▁ U+2581).
final class PromptBuilderTests: XCTestCase {

    // MARK: ChatML (Qwen3.5/3.6, MiniCPM5, Bonsai)

    func testChatMLThreadsHistoryAndOpensAssistant() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .system, content: "S"),
                       ChatTurn(role: .user, content: "Hi"),
                       ChatTurn(role: .assistant, content: "Hey"),
                       ChatTurn(role: .user, content: "Bye")],
            template: .chatML, reasoning: .thinkTags, thinking: true)
        XCTAssertEqual(p, """
        <|im_start|>system
        S<|im_end|>
        <|im_start|>user
        Hi<|im_end|>
        <|im_start|>assistant
        Hey<|im_end|>
        <|im_start|>user
        Bye<|im_end|>
        <|im_start|>assistant

        """)
    }

    func testChatMLImplicitOpenPrefillsOpenThinkWhenThinking() {
        // Qwen3.5/3.6/MiniCPM5: template pre-fills the OPENING <think>\n (model streams reasoning first).
        let p = LlamaEngine.buildPrompt(messages: [ChatTurn(role: .user, content: "Q")],
                                        template: .chatML, reasoning: .thinkTagsImplicitOpen, thinking: true)
        XCTAssertTrue(p.hasSuffix("<|im_start|>assistant\n<think>\n"))
        XCTAssertFalse(p.hasSuffix("</think>\n\n"))
    }

    func testThinkingOffSuppressesWithEmptyBlockForBothStyles() {
        for style in [ReasoningStyle.thinkTags, .thinkTagsImplicitOpen] {
            let p = LlamaEngine.buildPrompt(messages: [ChatTurn(role: .user, content: "Q")],
                                            template: .chatML, reasoning: style, thinking: false)
            XCTAssertTrue(p.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"),
                          "\(style): thinking-off must pre-fill an empty closed think block")
        }
    }

    func testExplicitThinkTagsAddNothingWhenThinking() {
        // DeepSeek/Hunyuan emit their own <think>; on thinking we append no opener.
        let p = LlamaEngine.buildPrompt(messages: [ChatTurn(role: .user, content: "Q")],
                                        template: .chatML, reasoning: .thinkTags, thinking: true)
        XCTAssertTrue(p.hasSuffix("<|im_start|>assistant\n"))
        XCTAssertFalse(p.contains("<think>"))
    }

    // MARK: DeepSeek

    func testDeepSeekFoldsAssistantOpenerIntoUserTurn() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .system, content: "sys"),
                       ChatTurn(role: .user, content: "hello")],
            template: .deepSeek, reasoning: .thinkTags, thinking: true)
        // BOS + raw system + <｜User｜>hello<｜Assistant｜>, model emits its own <think> → no suffix.
        XCTAssertEqual(p, "<｜begin▁of▁sentence｜>sys<｜User｜>hello<｜Assistant｜>")
    }

    func testDeepSeekHistoryEndsAssistantWithEOS() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .user, content: "a"),
                       ChatTurn(role: .assistant, content: "b"),
                       ChatTurn(role: .user, content: "c")],
            template: .deepSeek, reasoning: .thinkTags, thinking: true)
        XCTAssertEqual(p, "<｜begin▁of▁sentence｜><｜User｜>a<｜Assistant｜>b<｜end▁of▁sentence｜><｜User｜>c<｜Assistant｜>")
    }

    // MARK: Hunyuan

    func testHunyuanUsesTencentSpecialTokens() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .user, content: "你好")],
            template: .hunyuan, reasoning: .thinkTags, thinking: true)
        XCTAssertEqual(p, "<｜hy_begin▁of▁sentence｜><｜hy_User｜>你好<｜hy_Assistant｜>")
    }

    // MARK: reasoning-style toggle wiring

    func testNoneStyleNeverEmitsThink() {
        let on = LlamaEngine.buildPrompt(messages: [ChatTurn(role: .user, content: "Q")],
                                         template: .chatML, reasoning: .none, thinking: true)
        let off = LlamaEngine.buildPrompt(messages: [ChatTurn(role: .user, content: "Q")],
                                          template: .chatML, reasoning: .none, thinking: false)
        XCTAssertFalse(on.contains("<think>"))
        XCTAssertFalse(off.contains("<think>"))
    }
}
