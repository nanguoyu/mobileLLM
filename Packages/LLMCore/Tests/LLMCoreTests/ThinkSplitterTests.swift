// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

final class ThinkSplitterTests: XCTestCase {

    private func collect(_ deltas: [ThinkSplitter.Delta]) -> (reasoning: String, answer: String) {
        var r = "", a = ""
        for d in deltas {
            switch d {
            case .reasoning(let s): r += s
            case .answer(let s):    a += s
            }
        }
        return (r, a)
    }

    /// A whole-string feed splits cleanly on the tags.
    func testSingleFeedSplits() {
        var s = ThinkSplitter()
        var out = s.feed("<think>reasoning here</think>the answer")
        out += s.finish()
        let (r, a) = collect(out)
        XCTAssertEqual(r, "reasoning here")
        XCTAssertEqual(a, "the answer")
    }

    /// Tags split across chunk boundaries must still be detected (the withhold logic).
    func testTagsSplitAcrossChunks() {
        var s = ThinkSplitter()
        var out: [ThinkSplitter.Delta] = []
        // "<think>" is split; "</think>" is split across two chunks.
        for chunk in ["<thi", "nk>rea", "soning", "</thi", "nk>ans", "wer"] {
            out += s.feed(chunk)
        }
        out += s.finish()
        let (r, a) = collect(out)
        XCTAssertEqual(r, "reasoning")
        XCTAssertEqual(a, "answer")
    }

    /// Char-by-char streaming (the mock's default) reconstructs exactly, with no lost characters.
    func testCharByCharStream() {
        let reasoning = "let me think"
        let answer = "final answer!"
        let raw = "<think>\(reasoning)</think>\(answer)"
        var s = ThinkSplitter()
        var out: [ThinkSplitter.Delta] = []
        for ch in raw { out += s.feed(String(ch)) }
        out += s.finish()
        let (r, a) = collect(out)
        XCTAssertEqual(r, reasoning)
        XCTAssertEqual(a, answer)
    }

    /// CRITICAL (critique F1): finish() flushes the withheld tail. If a stream ends on what looked
    /// like a partial close tag but wasn't complete, those characters must NOT be lost.
    func testFinishFlushesWithheldTail() {
        var s = ThinkSplitter()
        // Enter the think block, then end mid-"</thin" — a plausible partial close tag that never
        // completes. Without finish() those 6 chars would be silently withheld forever.
        var out = s.feed("<think>done</thin")
        let beforeFinish = collect(out)
        XCTAssertEqual(beforeFinish.reasoning, "done", "the partial-tag tail is withheld until finish")

        out = s.finish()
        let flushed = collect(out)
        XCTAssertEqual(flushed.reasoning, "</thin", "finish must flush the withheld tail, losing nothing")
    }

    /// No characters are lost across the whole stream: reasoning + answer == input minus the tags.
    func testNoCharactersLost() {
        let raw = "<think>abc</think>xyz</thi"   // trailing partial tag in the answer region
        var s = ThinkSplitter()
        var out: [ThinkSplitter.Delta] = []
        for ch in raw { out += s.feed(String(ch)) }
        out += s.finish()
        let (r, a) = collect(out)
        XCTAssertEqual(r, "abc")
        XCTAssertEqual(a, "xyz</thi")
        XCTAssertEqual(r.count + a.count, raw.count - "<think>".count - "</think>".count)
    }

    /// Plain text with no think block is all answer.
    func testNoThinkBlockIsAllAnswer() {
        var s = ThinkSplitter()
        var out = s.feed("just a direct answer")
        out += s.finish()
        let (r, a) = collect(out)
        XCTAssertEqual(r, "")
        XCTAssertEqual(a, "just a direct answer")
    }
}
