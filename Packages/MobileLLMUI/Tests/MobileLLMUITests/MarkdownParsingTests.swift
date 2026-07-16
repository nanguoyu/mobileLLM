// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// `MarkdownBlock.parse` block grammar (DESIGN §4): headings, lists, quotes, tables, and fenced code —
/// plus the streaming-partial cases the composer must survive mid-token.
final class MarkdownParsingTests: XCTestCase {

    private func row(_ level: Int, _ ordered: Bool, _ number: Int?, _ text: String) -> MarkdownBlock.ListRow {
        MarkdownBlock.ListRow(level: level, ordered: ordered, number: number, text: text)
    }

    // MARK: Headings

    func testHeadingsParseWithLevels() {
        let kinds = MarkdownBlock.parse("# Title\n## Section\n#### Deep\nbody").map(\.kind)
        XCTAssertEqual(kinds, [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Section"),
            .heading(level: 4, text: "Deep"),
            .prose("body"),
        ])
    }

    func testHashWithoutSpaceIsProse() {
        // GFM requires a space after the #'s — so "#hashtag" is prose, not an empty h1.
        XCTAssertEqual(MarkdownBlock.parse("#nothashtag").map(\.kind), [.prose("#nothashtag")])
    }

    // MARK: Lists

    func testNestedUnorderedListOneLevel() {
        let kinds = MarkdownBlock.parse("- a\n- b\n  - b1\n- c").map(\.kind)
        XCTAssertEqual(kinds, [.list([
            row(0, false, nil, "a"),
            row(0, false, nil, "b"),
            row(1, false, nil, "b1"),
            row(0, false, nil, "c"),
        ])])
    }

    func testOrderedListKeepsAuthorNumbers() {
        let kinds = MarkdownBlock.parse("1. one\n2. two\n3. three").map(\.kind)
        XCTAssertEqual(kinds, [.list([
            row(0, true, 1, "one"),
            row(0, true, 2, "two"),
            row(0, true, 3, "three"),
        ])])
    }

    func testLooseListToleratesSingleBlankLine() {
        let kinds = MarkdownBlock.parse("- a\n\n- b").map(\.kind)
        XCTAssertEqual(kinds, [.list([row(0, false, nil, "a"), row(0, false, nil, "b")])])
    }

    // MARK: Quotes

    func testBlockquoteCollapsesConsecutiveLines() {
        XCTAssertEqual(MarkdownBlock.parse("> first\n> second").map(\.kind),
                       [.quote(["first", "second"])])
    }

    // MARK: Tables

    func testTableParsesHeaderAndRows() {
        let md = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |"
        XCTAssertEqual(MarkdownBlock.parse(md).map(\.kind),
                       [.table(header: ["Name", "Age"], rows: [["Alice", "30"], ["Bob", "25"]])])
    }

    func testStreamingPartialTable() {
        // Header alone (delimiter not streamed yet) stays prose — no table flash mid-stream.
        XCTAssertEqual(MarkdownBlock.parse("| Name | Age |").map(\.kind), [.prose("| Name | Age |")])
        // Header + delimiter, no body rows yet → an empty table, not broken markup.
        XCTAssertEqual(MarkdownBlock.parse("| Name | Age |\n| --- | --- |").map(\.kind),
                       [.table(header: ["Name", "Age"], rows: [])])
        // Header + delimiter + one row still arriving (no trailing pipe).
        XCTAssertEqual(MarkdownBlock.parse("| Name | Age |\n| --- | --- |\n| Alice | 30").map(\.kind),
                       [.table(header: ["Name", "Age"], rows: [["Alice", "30"]])])
    }

    // MARK: Code (kept working)

    func testCodeFenceStillParses() {
        let kinds = MarkdownBlock.parse("intro\n```swift\nlet x = 1\n```\noutro").map(\.kind)
        XCTAssertEqual(kinds, [.prose("intro"), .code(language: "swift", code: "let x = 1"), .prose("outro")])
    }

    func testUnterminatedCodeFenceMidStreamStaysCode() {
        XCTAssertEqual(MarkdownBlock.parse("```python\nprint(1)").map(\.kind),
                       [.code(language: "python", code: "print(1)")])
    }

    // MARK: Mixed document

    func testMixedDocumentBlockSequence() {
        let md = """
        ## Heading

        A paragraph with **bold**.

        - item one
        - item two

        > a quote

        ```swift
        let x = 1
        ```

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let kinds = MarkdownBlock.parse(md).map(\.kind)
        XCTAssertEqual(kinds.count, 6, "heading, prose, list, quote, code, table")
        if case .heading(let l, _) = kinds[0] { XCTAssertEqual(l, 2) } else { XCTFail("block 0 should be a heading") }
        if case .prose = kinds[1] {} else { XCTFail("block 1 should be prose") }
        if case .list = kinds[2] {} else { XCTFail("block 2 should be a list") }
        if case .quote = kinds[3] {} else { XCTFail("block 3 should be a quote") }
        if case .code = kinds[4] {} else { XCTFail("block 4 should be code") }
        if case .table = kinds[5] {} else { XCTFail("block 5 should be a table") }
    }
}
