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

    func testCalculatorHandlesParenthesesAndFloat() async {
        let paren = await CalculatorTool().execute(argumentsJSON: #"{"expression":"(2+3)*4"}"#)
        XCTAssertEqual(paren, "20")
        let frac = await CalculatorTool().execute(argumentsJSON: #"{"expression":"10/4"}"#)
        XCTAssertEqual(frac, "2.5")
    }

    /// Power, modulo, and unary minus with their precedence (`**` binds tighter than unary `-`).
    func testCalculatorPowerModuloUnary() async {
        await XCTAssertCalc("2**10", "1024")
        await XCTAssertCalc("10%3", "1")
        await XCTAssertCalc("10.5%3", "1.5")     // truncatingRemainder, not integer mod
        await XCTAssertCalc("-5+2", "-3")
        await XCTAssertCalc("-2**2", "-4")       // -(2**2), Python-style
        await XCTAssertCalc("2**3**2", "512")    // right-associative: 2**(3**2)
        await XCTAssertCalc("2^8", "256")        // caret normalized to power
    }

    /// Fuzz: every malformed expression must return an error STRING and NEVER crash. (If any of these
    /// reached `NSExpression`, the ObjC exception would kill the test process — so a green run *is* the
    /// no-crash guarantee.)
    func testCalculatorMalformedNeverCrashes() async {
        let bad = [
            "(2+3",          // unbalanced open paren
            "2+3)",          // unbalanced close paren
            "%",             // bare modulo
            "50%",           // trailing operator, no rhs
            "%%@",           // junk (also fails the char filter)
            "3*/2",          // operator run
            "1//2",          // operator run
            "**5",           // leading power
            "2**",           // trailing power, no exponent
            "1.2.3",         // malformed number literal
            ".",             // lone dot
            "10**100000",    // overflow → ±inf, reported not printed
            "1/0",           // divide by zero → inf
            "０＋１",          // fullwidth unicode digits
            "",              // empty
            "   ",           // whitespace only (→ empty after normalization)
        ]
        for expr in bad {
            let r = await CalculatorTool().execute(argumentsJSON: #"{"expression":"\#(expr)"}"#)
            XCTAssertTrue(r.hasPrefix("Error"), "‘\(expr)’ must return an error string, got ‘\(r)’")
        }
    }

    private func XCTAssertCalc(_ expr: String, _ expected: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let r = await CalculatorTool().execute(argumentsJSON: #"{"expression":"\#(expr)"}"#)
        XCTAssertEqual(r, expected, file: file, line: line)
    }

    func testDateTimeToolReturnsNonEmpty() async {
        let r = await DateTimeTool().execute(argumentsJSON: "{}")
        XCTAssertFalse(r.isEmpty)
        XCTAssertFalse(r.hasPrefix("Error"))
    }

    func testRegistriesExposeExpectedTools() {
        XCTAssertEqual(Set(ToolRegistry.builtIn.tools.map { $0.schema.name }), ["calculator", "current_datetime"])
        XCTAssertTrue(ToolRegistry.standard.tool(named: "web_search") != nil)
        XCTAssertNil(ToolRegistry.builtIn.tool(named: "web_search"))
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

    // MARK: Web search (pure parsers — no network)

    func testWebSearchPicksLanguageByScript() {
        XCTAssertEqual(WebSearchTool.lang(for: "Alan Turing"), "en")
        XCTAssertEqual(WebSearchTool.lang(for: "北京是哪里"), "zh")
        XCTAssertEqual(WebSearchTool.lang(for: "Qwen 模型"), "zh")   // any CJK → zh
    }

    func testWebSearchParsesTopTitle() {
        let json = #"{"query":{"search":[{"title":"Alan Turing","pageid":1},{"title":"Other"}]}}"#
        XCTAssertEqual(WebSearchTool.parseTopTitle(Data(json.utf8)), "Alan Turing")
        XCTAssertNil(WebSearchTool.parseTopTitle(Data(#"{"query":{"search":[]}}"#.utf8)))
        XCTAssertNil(WebSearchTool.parseTopTitle(Data("garbage".utf8)))
    }

    func testWebSearchParsesSummary() {
        let json = #"{"title":"Alan Turing","extract":"  Alan Turing was a British mathematician.  "}"#
        XCTAssertEqual(WebSearchTool.parseSummary(Data(json.utf8)), "Alan Turing was a British mathematician.")
        XCTAssertEqual(WebSearchTool.parseSummary(Data("{}".utf8)), "")
    }

    func testWebSearchSchema() {
        let s = WebSearchTool().schema
        XCTAssertEqual(s.name, "web_search")
        XCTAssertEqual(s.parameters.first?.name, "query")
    }
}
