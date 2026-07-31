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
        // Raw system + <｜User｜>hello<｜Assistant｜>, model emits its own <think> → no suffix. NO literal BOS:
        // tokenize(addSpecial:true) prepends it, so the builder must not (a second one degrades output).
        XCTAssertEqual(p, "sys<｜User｜>hello<｜Assistant｜>")
    }

    func testDeepSeekHistoryEndsAssistantWithEOS() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .user, content: "a"),
                       ChatTurn(role: .assistant, content: "b"),
                       ChatTurn(role: .user, content: "c")],
            template: .deepSeek, reasoning: .thinkTags, thinking: true)
        // Mid-history EOS between turns stays; only the leading BOS is dropped (owned by add_special).
        XCTAssertEqual(p, "<｜User｜>a<｜Assistant｜>b<｜end▁of▁sentence｜><｜User｜>c<｜Assistant｜>")
    }

    func testDeepSeekCoalescesEverySystemTurnInOrder() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .system, content: "Base policy"),
                       ChatTurn(role: .user, content: "old question"),
                       ChatTurn(role: .system, content: "Compaction note"),
                       ChatTurn(role: .assistant, content: "old answer"),
                       ChatTurn(role: .system, content: "Newest constraint"),
                       ChatTurn(role: .user, content: "continue")],
            template: .deepSeek, reasoning: .thinkTags, thinking: true)

        XCTAssertTrue(p.hasPrefix("Base policy\n\nCompaction note\n\nNewest constraint"),
                      "all system turns must survive in encounter order")
        XCTAssertEqual(p.components(separatedBy: "Compaction note").count - 1, 1)
        XCTAssertTrue(p.contains("<｜User｜>continue<｜Assistant｜>"))
    }

    // MARK: Hunyuan

    func testHunyuanUsesTencentSpecialTokens() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .user, content: "你好")],
            template: .hunyuan, reasoning: .thinkTags, thinking: true)
        // Tencent special tokens preserved; leading BOS dropped (owned by add_special, never doubled).
        XCTAssertEqual(p, "<｜hy_User｜>你好<｜hy_Assistant｜>")
    }

    func testHunyuanCoalescesEverySystemTurnWithoutConcatenatingText() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .system, content: "系统规则"),
                       ChatTurn(role: .system, content: ""),
                       ChatTurn(role: .system, content: "压缩摘要"),
                       ChatTurn(role: .user, content: "继续")],
            template: .hunyuan, reasoning: .thinkTags, thinking: true)

        XCTAssertEqual(p, "系统规则\n\n压缩摘要<｜hy_User｜>继续<｜hy_Assistant｜>")
    }

    // MARK: Gemma 4 (asymmetric turn markers, non-thinking)

    func testGemmaAsymmetricTurnMarkers() {
        let p = LlamaEngine.buildPrompt(
            messages: [ChatTurn(role: .system, content: "S"),
                       ChatTurn(role: .user, content: "hi"),
                       ChatTurn(role: .assistant, content: "hey"),
                       ChatTurn(role: .user, content: "bye")],
            template: .gemma, reasoning: .none, thinking: false)
        // <|turn> opens, <turn|> closes; assistant → "model"; ends on the model opener; no <think>.
        XCTAssertEqual(p, "<|turn>system\nS<turn|>\n<|turn>user\nhi<turn|>\n"
                        + "<|turn>model\nhey<turn|>\n<|turn>user\nbye<turn|>\n<|turn>model\n")
        XCTAssertFalse(p.contains("<think>"))
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

    // MARK: BOS policy — builders never emit a literal begin-of-sentence token

    func testNoBuilderEmitsLiteralBOS() {
        // add_special owns the BOS; a literal one in the string would double it on GGUFs with
        // add_bos_token=true. Pin that NO builder writes a family BOS literal, anywhere in its output.
        let bosLiterals = ["<｜begin▁of▁sentence｜>", "<｜hy_begin▁of▁sentence｜>", "<bos>", "<s>"]
        let msgs = [ChatTurn(role: .system, content: "S"),
                    ChatTurn(role: .user, content: "hi"),
                    ChatTurn(role: .assistant, content: "yo"),
                    ChatTurn(role: .user, content: "bye")]
        for template in [PromptTemplate.chatML, .deepSeek, .hunyuan, .gemma, .auto] {
            for style in [ReasoningStyle.none, .thinkTags, .thinkTagsImplicitOpen] {
                for thinking in [true, false] {
                    let p = LlamaEngine.buildPrompt(messages: msgs, template: template,
                                                    reasoning: style, thinking: thinking)
                    for bos in bosLiterals {
                        XCTAssertFalse(p.hasPrefix(bos), "\(template)/\(style): no leading BOS literal")
                        XCTAssertFalse(p.contains(bos), "\(template)/\(style): no BOS literal anywhere")
                    }
                }
            }
        }
    }
}
