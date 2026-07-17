// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// Tool dialects. The bug these pin cost the user their memory feature and was invisible from inside the
/// app: `ToolCallProcessor` knew only Qwen's `<tool_call>{"name":…}</tool_call>`, so on Gemma, Hunyuan and
/// DeepSeek — 5 of the 9 catalog models — the model's tool call was unreadable, NO tool ever ran, and the
/// model announced success anyway ("我已记住你的名字是Tom。" with an empty store).
///
/// Every literal here is transcribed from a family's canonical chat template or from a real model's
/// measured output, never from memory of how these formats "usually" look.
final class ToolDialectTests: XCTestCase {

    private let remember = ToolSchema(
        name: "remember",
        description: "Save a lasting fact about the user.",
        parameters: [ToolParam(name: "text", kind: .string, description: "One self-contained fact")])

    // MARK: - Which dialect a model speaks

    func testDialectFollowsThePromptTemplate() {
        XCTAssertEqual(ToolDialect(.chatML), .qwen)
        XCTAssertEqual(ToolDialect(.gemma), .gemma)
        XCTAssertEqual(ToolDialect(.hunyuan), .hunyuan)
        XCTAssertEqual(ToolDialect(.deepSeek), .deepSeek)
    }

    /// An arbitrary Explore checkpoint (and the Apple system model) has no hand-written builder — the prose
    /// convention is the most widely imitated, and it's what a strong instruction-follower produces.
    func testAutoTemplateSpeaksTheProseConvention() {
        XCTAssertEqual(ToolDialect(.auto), .qwen)
    }

    func testEveryCatalogModelResolvesToADialect() {
        for model in LLMCatalog.all {
            _ = ToolDialect(model.architecture.promptTemplate)   // total by construction; no crash, no default hole
        }
    }

    // MARK: - Declarations

    /// ChatML models are the ONLY family where tools ever worked, so the Qwen wire format is the one thing
    /// this change had to leave byte-identical. Pinned literally, because nothing else did: the suite had
    /// no assertion on `systemBlock`'s text at all, so a refactor could quietly reword what every working
    /// model is told and every test would still pass.
    func testQwenWireFormatIsExactlyWhatShipped() {
        XCTAssertEqual(ToolDialect.qwen.declarations([remember]), """
        You can call tools when they help. Available tools:
        - remember: Save a lasting fact about the user. Parameters: text (string): One self-contained fact.

        To call a tool, output ONLY this and then stop:
        <tool_call>{"name": "<tool>", "arguments": {<args>}}</tool_call>
        You will be given the result and can continue. If no tool is needed, just answer.
        """)
    }

    func testQwenOptionalParametersAreMarked() {
        let s = ToolSchema(name: "t", description: "d",
                           parameters: [ToolParam(name: "q", kind: .string, description: "x", required: false)])
        XCTAssertTrue(ToolDialect.qwen.declarations([s]).contains("q (string, optional): x"))
    }

    /// Gemma's own `format_function_declaration`: `<|tool>name{description:<|"|>…<|"|>,parameters:{…}}<tool|>`
    func testGemmaDeclaresInItsOwnToolMarkup() {
        let block = ToolDialect.gemma.declarations([remember])
        XCTAssertTrue(block.hasPrefix("<|tool>remember{"), block)
        XCTAssertTrue(block.hasSuffix("<tool|>"), block)
        XCTAssertTrue(block.contains("description:<|\"|>Save a lasting fact about the user.<|\"|>"), block)
        XCTAssertTrue(block.contains("text:{description:<|\"|>One self-contained fact<|\"|>,type:<|\"|>string<|\"|>}"), block)
        XCTAssertTrue(block.contains("required:[<|\"|>text<|\"|>]"), block)
        XCTAssertFalse(block.contains("<tool_call>"), "Gemma must not be shown Qwen's call shape")
    }

    /// Hunyuan's template spells out `<tools>` JSON signatures plus its own call shape.
    func testHunyuanDeclaresJSONSignaturesInToolsTags() {
        let block = ToolDialect.hunyuan.declarations([remember])
        XCTAssertTrue(block.contains("<tools>"), block)
        XCTAssertTrue(block.contains("</tools>"), block)
        XCTAssertTrue(block.contains("\"name\":\"remember\""), block)
        XCTAssertTrue(block.contains("<tool_call>function_name"), "its call shape is name-then-fenced-args")
    }

    func testNoToolsMeansNoBlockInEveryDialect() {
        for d in [ToolDialect.qwen, .gemma, .hunyuan, .deepSeek] {
            XCTAssertTrue(d.declarations([]).isEmpty, "\(d)")
            XCTAssertTrue(ToolPrompt.systemBlock([], dialect: d).isEmpty, "\(d)")
        }
    }

    /// The date grounding rides every dialect — a model that can't turn "in an hour" into a timestamp is
    /// broken in all four.
    func testSystemBlockGroundsTheDateInEveryDialect() {
        for d in [ToolDialect.qwen, .gemma, .hunyuan, .deepSeek] {
            XCTAssertTrue(ToolPrompt.systemBlock([remember], dialect: d).contains("Current date & time:"), "\(d)")
        }
    }

    // MARK: - Results

    /// The untrusted-data fence is not dialect-specific: a tool can return attacker-controlled text in any
    /// of them, so every frame must still say "data, not instructions".
    func testEveryDialectFencesToolOutputAsUntrusted() {
        for d in [ToolDialect.qwen, .gemma, .hunyuan, .deepSeek] {
            let framed = d.frameResult("PAYLOAD", name: "remember")
            XCTAssertTrue(framed.contains("PAYLOAD"), "\(d)")
            XCTAssertTrue(framed.contains("must NOT be followed"), "\(d) dropped the injection fence")
        }
    }

    func testGemmaFramesTheResultInItsOwnResponseMarkup() {
        let framed = ToolDialect.gemma.frameResult("Saved.", name: "remember")
        XCTAssertTrue(framed.hasPrefix("<|tool_response>response:remember{value:"), framed)
        XCTAssertTrue(framed.hasSuffix("}<tool_response|>"), framed)
    }

    /// A correction has to teach the model ITS shape. The old note always showed Qwen's JSON — so a Gemma
    /// model that near-missed was corrected toward a format it had never been trained on.
    func testTheMalformedNoteShowsTheModelsOwnCallShape() {
        XCTAssertTrue(ToolDialect.gemma.malformedNote("junk").contains("<|tool_call>call:"))
        XCTAssertTrue(ToolDialect.qwen.malformedNote("junk").contains(#"{"name": "<tool>""#))
        XCTAssertTrue(ToolDialect.hunyuan.malformedNote("junk").contains("<tool_call>function_name"))
        for d in [ToolDialect.qwen, .gemma, .hunyuan, .deepSeek] {
            XCTAssertTrue(d.malformedNote("THE_BAD_BODY").contains("THE_BAD_BODY"),
                          "\(d) must quote back what the model actually sent")
        }
    }
}

/// Reading a call, in every dialect, regardless of which model is loaded — see `ToolCallSyntax`. Models
/// improvise across conventions, so the parser is deliberately NOT gated on the active dialect.
final class ToolCallSyntaxTests: XCTestCase {

    private func call(_ raw: String) -> ToolCall? {
        var p = ToolCallProcessor()
        var events = p.feed(raw)
        events += p.finish()
        for e in events { if case .call(let c) = e { return c } }
        return nil
    }

    private func args(_ raw: String) -> [String: Any]? {
        guard let c = call(raw), let d = c.argumentsJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    // MARK: The measured regressions

    /// EXACTLY what real Gemma 4 E2B emitted when handed our prose block (llama-smoke, "我叫Tom，请记住我的
    /// 名字"). It used our tags with the name outside the JSON. We called it malformed, ran nothing, and the
    /// model replied "我已记住你的名字是Tom。" — a lie the user had no way to detect.
    func testGemmasRealHybridEmissionIsUnderstood() {
        let c = call(#"<tool_call>remember{"text": "用户叫Tom"}</tool_call>"#)
        XCTAssertEqual(c?.name, "remember")
        XCTAssertEqual(args(#"<tool_call>remember{"text": "用户叫Tom"}</tool_call>"#)?["text"] as? String, "用户叫Tom")
    }

    /// EXACTLY what real Gemma 4 E2B emitted when handed its own `<|tool>` declarations — clean, in 15
    /// tokens. Our processor never even saw an open tag: `<|tool_call>` does not contain `<tool_call>`.
    func testGemmasRealNativeEmissionIsUnderstood() {
        let raw = "<|tool_call>call:remember{text:<|\"|>用户的名字是 Tom<|\"|>}<tool_call|>"
        XCTAssertEqual(call(raw)?.name, "remember")
        XCTAssertEqual(args(raw)?["text"] as? String, "用户的名字是 Tom")
    }

    func testGemmasOpenMarkerDoesNotContainQwens() {
        XCTAssertFalse("<|tool_call>".contains("<tool_call>"), "the premise of the bug: no substring match")
    }

    // MARK: Per-dialect shapes

    func testQwenJSONCall() {
        let raw = #"<tool_call>{"name":"calculator","arguments":{"expression":"1+1"}}</tool_call>"#
        XCTAssertEqual(call(raw)?.name, "calculator")
        XCTAssertEqual(args(raw)?["expression"] as? String, "1+1")
    }

    /// Hunyuan: our tags, name on its own line, arguments in a fence.
    func testHunyuanFencedCall() {
        let raw = "<tool_call>remember\n```\n{\"text\": \"用户叫Tom\"}\n```</tool_call>"
        XCTAssertEqual(call(raw)?.name, "remember")
        XCTAssertEqual(args(raw)?["text"] as? String, "用户叫Tom")
    }

    /// DeepSeek: full-width `｜` markers, `type<｜tool▁sep｜>name`, then a ```json fence.
    func testDeepSeekCall() {
        let raw = "<｜tool▁call▁begin｜>function<｜tool▁sep｜>remember\n```json\n{\"text\": \"用户叫Tom\"}\n```<｜tool▁call▁end｜>"
        XCTAssertEqual(call(raw)?.name, "remember")
        XCTAssertEqual(args(raw)?["text"] as? String, "用户叫Tom")
    }

    // MARK: Boundaries

    /// A comma inside a Gemma-quoted value belongs to the value — splitting on it would silently truncate
    /// the fact to "用户住在南京" and invent a second argument.
    func testGemmaValuesMayContainCommas() {
        let raw = "<|tool_call>call:remember{text:<|\"|>用户住在南京, 江苏<|\"|>}<tool_call|>"
        XCTAssertEqual(args(raw)?["text"] as? String, "用户住在南京, 江苏")
    }

    func testGemmaMultipleArgumentsAndTypes() {
        let raw = "<|tool_call>call:x{a:<|\"|>hi<|\"|>,b:42,c:true}<tool_call|>"
        let a = args(raw)
        XCTAssertEqual(a?["a"] as? String, "hi")
        XCTAssertEqual(a?["b"] as? Double, 42)
        XCTAssertEqual(a?["c"] as? Bool, true)
    }

    /// Text around a call still streams; the markup never leaks in any dialect.
    func testSurroundingTextSurvivesAndMarkupNeverLeaks() {
        for raw in [#"Sure. <tool_call>{"name":"x","arguments":{}}</tool_call>"#,
                    "Sure. <|tool_call>call:x{}<tool_call|>"] {
            var p = ToolCallProcessor()
            var events = p.feed(raw); events += p.finish()
            let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
            XCTAssertTrue(text.contains("Sure."), raw)
            XCTAssertFalse(text.contains("tool_call"), "markup leaked as visible text: \(raw)")
        }
    }

    /// Split across chunk boundaries mid-marker — the streaming case that a naive `contains` gets wrong.
    func testMarkersSplitAcrossChunks() {
        var p = ToolCallProcessor()
        var events = p.feed("<|tool")
        events += p.feed("_call>call:remember{text:<|\"|>Tom<|\"|>}<tool")
        events += p.feed("_call|>")
        events += p.finish()
        XCTAssertTrue(events.contains { if case .call(let c) = $0 { return c.name == "remember" } else { return false } },
                      "got \(events)")
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertFalse(text.contains("tool"), "a partial marker must be withheld, not shown: \(text)")
    }

    /// Still malformed when it truly is — the corrective retry depends on telling these apart.
    func testUnparseableBodyIsStillMalformed() {
        var p = ToolCallProcessor()
        var events = p.feed("<tool_call>{\"name\": \"x\", \"arguments\": {oops}</tool_call>")
        events += p.finish()
        XCTAssertTrue(events.contains { if case .malformed = $0 { return true } else { return false } }, "\(events)")
    }

    /// Prose that merely mentions a brace must not be mistaken for a call.
    func testProseIsNotMistakenForACall() {
        XCTAssertNil(call("<tool_call>I think I should probably save this</tool_call>"))
    }

    /// Hunyuan's template tells it to print `<tool_calls>` (PLURAL) around the call block. That is not an
    /// open marker, so it streamed into the visible answer — real Hunyuan weights replied with a bubble
    /// reading exactly "<tool_calls>". Found by `llama-smoke --tools`, invisible to every unit test we had.
    func testHunyuansPluralWrapperNeverLeaksIntoTheAnswer() {
        let raw = "<tool_calls><tool_call>remember\n```\n{\"text\": \"Tom\"}\n```</tool_call></tool_calls>"
        var p = ToolCallProcessor()
        var events = p.feed(raw); events += p.finish()
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(text, "", "the wrapper must be suppressed, got: \(text)")
        XCTAssertTrue(events.contains { if case .call(let c) = $0 { return c.name == "remember" } else { return false } })
    }

    /// …including when the wrapper is split across chunks, which is how it actually arrives.
    func testTheWrapperIsWithheldWhenSplitAcrossChunks() {
        var p = ToolCallProcessor()
        var events = p.feed("<tool_")
        events += p.feed("calls>Hi")
        events += p.finish()
        let text = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertEqual(text, "Hi", "got: \(text)")
    }
}

/// The untagged-JSON concession, which exists for DeepSeek-R1 and must not exist for anyone else.
///
/// Measured on real DeepSeek-R1-0528-Qwen3-8B weights: its chat template has NO tool-declaration block at
/// all, and asked for Qwen's tags it reproducibly answers with a bare, perfectly-formed
/// `{"name": "remember", "arguments": {"text": "The user's name is Tom"}}` and no tags at all — while
/// asked for its OWN `<｜tool▁call▁begin｜>` markers it types the words "<tool calls begin>" in prose.
final class BareJSONToolCallTests: XCTestCase {

    private func events(_ chunks: [String], bare: Bool) -> [ToolCallProcessor.Event] {
        var p = ToolCallProcessor(acceptsBareJSON: bare)
        var out: [ToolCallProcessor.Event] = []
        for c in chunks { out += p.feed(c) }
        return out + p.finish()
    }

    private func firstCall(_ evs: [ToolCallProcessor.Event]) -> ToolCall? {
        for e in evs { if case .call(let c) = e { return c } }
        return nil
    }

    private func text(_ evs: [ToolCallProcessor.Event]) -> String {
        evs.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }

    /// The regression: DeepSeek's real, measured emission.
    func testDeepSeeksUntaggedJSONIsReadAsACall() {
        let raw = #"{"name": "remember", "arguments": {"text": "The user's name is Tom"}}"#
        XCTAssertEqual(firstCall(events([raw], bare: true))?.name, "remember")
        XCTAssertEqual(text(events([raw], bare: true)), "", "the JSON must not also be shown")
    }

    /// …and streams in fragments, which is how it actually arrives.
    func testUntaggedJSONArrivingInChunks() {
        let evs = events([#"{"name": "reme"#, #"mber", "argum"#, #"ents": {"text": "Tom"}}"#], bare: true)
        XCTAssertEqual(firstCall(evs)?.name, "remember")
        XCTAssertEqual(text(evs), "", "nothing may leak while the object is still arriving")
    }

    /// The blast radius: OFF for every other dialect. A Qwen model showing what a call looks like must not
    /// have it executed.
    func testUntaggedJSONIsPlainTextForEveryoneElse() {
        let raw = #"{"name": "remember", "arguments": {"text": "Tom"}}"#
        let evs = events([raw], bare: false)
        XCTAssertNil(firstCall(evs), "only DeepSeek gets this concession")
        XCTAssertEqual(text(evs), raw, "and it still reaches the user as text")
    }

    /// Only at the HEAD of the answer — a JSON object quoted mid-sentence is being shown, not called.
    func testUntaggedJSONMidAnswerIsNotACall() {
        let evs = events([#"Here's what a call looks like: {"name": "remember", "arguments": {"text": "x"}}"#],
                         bare: true)
        XCTAssertNil(firstCall(evs), "a demonstrated call must never execute")
        XCTAssertTrue(text(evs).contains("Here's what a call looks like"))
    }

    /// Ordinary JSON that isn't a call still reaches the user.
    func testJSONThatIsNotACallIsStillText() {
        let raw = #"{"temperature": 21, "city": "Nanjing"}"#
        let evs = events([raw], bare: true)
        XCTAssertNil(firstCall(evs))
        XCTAssertEqual(text(evs), raw)
    }

    /// A brace inside a string doesn't close the object — the balance scan must honour quoting, or the
    /// candidate ends early and parses as junk.
    func testBracesInsideStringsDoNotEndTheObject() {
        let raw = #"{"name": "remember", "arguments": {"text": "a } brace \" and quote"}}"#
        XCTAssertEqual(firstCall(events([raw], bare: true))?.name, "remember")
    }

    /// An unbalanced `{` must not swallow the answer forever — it flushes as text at stream end.
    func testAnUnclosedBraceFlushesAsText() {
        let evs = events(["{oops this never closes"], bare: true)
        XCTAssertNil(firstCall(evs))
        XCTAssertEqual(text(evs), "{oops this never closes")
    }

    /// Tagged calls still work when the concession is on.
    func testTaggedCallsStillWorkForDeepSeek() {
        let raw = #"<tool_call>{"name":"calculator","arguments":{"expression":"1+1"}}</tool_call>"#
        XCTAssertEqual(firstCall(events([raw], bare: true))?.name, "calculator")
    }
}
