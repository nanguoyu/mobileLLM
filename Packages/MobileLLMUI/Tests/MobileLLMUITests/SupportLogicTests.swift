// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// Pure UI-support logic that had slipped through without tests: the markdown block splitter (incl.
/// mid-stream code fences), the compact number formatter, and the streaming "has content" gate.
final class SupportLogicTests: XCTestCase {

    // MARK: MarkdownBlock.parse

    func testParsesPlainProseAsOneBlock() {
        let blocks = MarkdownBlock.parse("Hello **world**, this is prose.")
        XCTAssertEqual(blocks.count, 1)
        guard case .prose(let s) = blocks[0].kind else { return XCTFail("expected prose") }
        XCTAssertTrue(s.contains("world"))
    }

    func testSplitsFencedCodeWithLanguage() {
        let blocks = MarkdownBlock.parse("Here:\n```swift\nlet x = 1\n```\nDone.")
        XCTAssertEqual(blocks.count, 3)   // prose, code, prose
        guard case .code(let lang, let code) = blocks[1].kind else { return XCTFail("expected code block") }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(code, "let x = 1")
        XCTAssertEqual(blocks.map(\.id), [0, 1, 2], "block ids are stable position ids for view reuse")
    }

    func testUnterminatedFenceMidStreamRendersAsCode() {
        // While streaming, an opened-but-not-closed fence should still read as a code block.
        let blocks = MarkdownBlock.parse("```python\nprint(1)")
        XCTAssertEqual(blocks.count, 1)
        guard case .code(let lang, let code) = blocks[0].kind else { return XCTFail("expected code") }
        XCTAssertEqual(lang, "python")
        XCTAssertEqual(code, "print(1)")
    }

    func testEmptyTextYieldsNoBlocks() {
        XCTAssertTrue(MarkdownBlock.parse("").isEmpty)
        XCTAssertTrue(MarkdownBlock.parse("\n\n").isEmpty, "newline-only prose trims to nothing")
    }

    // MARK: Format.shortCount

    func testShortCount() {
        XCTAssertEqual(Format.shortCount(999), "999")
        XCTAssertEqual(Format.shortCount(1000), "1K")
        XCTAssertEqual(Format.shortCount(2048), "2K")
        XCTAssertEqual(Format.shortCount(363790), "363K")
    }

    func testBytesFormatsNonEmpty() {
        XCTAssertFalse(Format.bytes(2_740_937_888).isEmpty)   // platform-formatted, just not blank
    }

    // MARK: StreamingState.hasAnyContent

    func testStreamingHasContentGate() {
        var s = StreamingState(messageID: UUID())
        XCTAssertFalse(s.hasAnyContent, "a fresh warming stream has nothing to show")
        s.answer = "hi"
        XCTAssertTrue(s.hasAnyContent)
        s.answer = ""; s.reasoning = "thinking"
        XCTAssertTrue(s.hasAnyContent)
        // A tool call before any text also counts as content (so we don't show the warming shimmer).
        s.reasoning = ""
        s.toolActivity = [ToolRun(name: "calculator", arguments: "{}")]
        XCTAssertTrue(s.hasAnyContent)
    }
}
