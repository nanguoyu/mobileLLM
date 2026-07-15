// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMEngineLlama

/// Removing Hunyuan's `<answer>…</answer>` wrapper from the streamed answer, including tags split across
/// chunks — the markers must never reach the UI, and nothing else is dropped.
final class LiteralStripperTests: XCTestCase {

    private func run(_ tags: [String], chunks: [String]) -> String {
        var s = LiteralStripper(tags: tags)
        var out = ""
        for c in chunks { out += s.feed(c) }
        out += s.flush()
        return out
    }

    func testStripsWholeTags() {
        XCTAssertEqual(run(["<answer>", "</answer>"], chunks: ["<answer>巴黎。</answer>"]), "巴黎。")
    }

    func testStripsTagSplitAcrossChunks() {
        // "<answer>" split as "<ans" | "wer>" — must still be removed.
        XCTAssertEqual(run(["<answer>", "</answer>"], chunks: ["<ans", "wer>Hi</an", "swer>"]), "Hi")
    }

    func testKeepsNonTagAngleBrackets() {
        XCTAssertEqual(run(["<answer>", "</answer>"], chunks: ["a < b and c > d"]), "a < b and c > d")
    }

    func testNoopWhenNoTags() {
        var s = LiteralStripper(tags: [])
        XCTAssertTrue(s.isNoop)
    }

    func testFlushReleasesWithheldNonTagTail() {
        // A trailing "<a" that never completes into a tag must be surfaced by flush.
        XCTAssertEqual(run(["<answer>"], chunks: ["done<a"]), "done<a")
    }
}
