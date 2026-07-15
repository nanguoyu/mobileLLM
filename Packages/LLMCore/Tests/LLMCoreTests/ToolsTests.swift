// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The on-device tool core: the calculator's evaluation + safety, argument decoding, and the streaming
/// `<tool_call>` parser (text passes through, calls are extracted + markup suppressed).
final class ToolsTests: XCTestCase {

    // MARK: Calculator

    func testCalculatorEvaluates() async {
        let c = CalculatorTool()
        let r = await c.execute(argumentsJSON: #"{"expression":"17 + 25 * 2"}"#)
        XCTAssertEqual(r, "67")
    }

    func testCalculatorNormalizesUnicodeOperators() async {
        let r = await CalculatorTool().execute(argumentsJSON: #"{"expression":"6 × 7"}"#)
        XCTAssertEqual(r, "42")
    }

    func testCalculatorRejectsUnsafeInput() async {
        let r = await CalculatorTool().execute(argumentsJSON: #"{"expression":"FUNCTION(1)"}"#)
        XCTAssertTrue(r.hasPrefix("Error"), "must refuse non-arithmetic input, got \(r)")
    }

    func testCalculatorMissingArg() async {
        let r = await CalculatorTool().execute(argumentsJSON: "{}")
        XCTAssertTrue(r.contains("missing"))
    }

    // MARK: ToolCall argument decoding

    func testToolCallDecodesStringAndNumberArgs() {
        let call = ToolCall(name: "t", argumentsJSON: #"{"a":"hi","b":42,"c":true}"#)
        XCTAssertEqual(call.arg("a"), "hi")
        XCTAssertEqual(call.arg("b"), "42")
        XCTAssertEqual(call.arg("c"), "true")
        XCTAssertNil(call.arg("missing"))
    }

    // MARK: Streaming parser

    private func run(_ chunks: [String]) -> [ToolCallProcessor.Event] {
        var p = ToolCallProcessor()
        var out: [ToolCallProcessor.Event] = []
        for c in chunks { out += p.feed(c) }
        out += p.finish()
        return out
    }

    func testExtractsToolCallAndSuppressesMarkup() {
        let events = run([#"Let me compute. <tool_call>{"name":"calculator","arguments":{"expression":"2+2"}}</tool_call>"#])
        XCTAssertEqual(events.first, .text("Let me compute. "))
        guard case let .call(call)? = events.last else { return XCTFail("expected a call, got \(events)") }
        XCTAssertEqual(call.name, "calculator")
        XCTAssertEqual(call.arg("expression"), "2+2")
        // The <tool_call> markup must NOT appear as text.
        XCTAssertFalse(events.contains { if case .text(let s) = $0 { return s.contains("tool_call") }; return false })
    }

    func testToolCallSplitAcrossChunks() {
        // Tag + JSON dribbled in pieces (including a mid-tag boundary).
        let events = run(["think ", "<tool_", "call>{\"name\":\"cur", "rent_datetime\",\"arguments\":{}}</tool_", "call> done"])
        XCTAssertTrue(events.contains(.text("think ")))
        XCTAssertTrue(events.contains { if case .call(let c) = $0 { return c.name == "current_datetime" }; return false })
        XCTAssertTrue(events.contains { if case .text(let s) = $0 { return s.contains("done") }; return false })
    }

    func testPlainTextPassesThroughUntouched() {
        let events = run(["Hello, ", "world. No tools here."])
        XCTAssertEqual(events, [.text("Hello, "), .text("world. No tools here.")])
    }

    func testWithheldPartialTagNotLeakedMidStream() {
        // A lone "<tool" that never completes must surface as text on finish, not vanish.
        var p = ToolCallProcessor()
        _ = p.feed("answer <tool")
        let tail = p.finish()
        XCTAssertTrue(tail.contains { if case .text(let s) = $0 { return s.contains("<tool") }; return false })
    }
}
