// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// Pure `ToolRegistry` semantics that the app's live registry depends on but no test pins: name-collision
/// shadowing (first registration wins `tool(named:)`, both schemas still advertised), and the deliberate
/// 3-vs-5 divergence between `build(includeStandard:)`'s hard-coded trio and `ToolRegistry.standard`.
final class ToolRegistryContractTests: XCTestCase {

    /// Two tools sharing a `schema.name`: `tool(named:)` returns `.first` (the built-in shadows the later
    /// one), and both schemas remain in the advertised list (NOT de-duplicated). This is exactly what the
    /// app's `builtIns.tools + mcp.tools` concatenation produces when an MCP server collides with a built-in.
    func testCollidingNameResolvesToFirstAndBothSchemasAdvertised() async {
        let registry = ToolRegistry([CalculatorTool(), StubTool(name: "calculator", result: "SHADOW")])

        // Resolution goes to the FIRST — prove it by executing (the real calculator computes; the stub would
        // return "SHADOW").
        let out = await registry.tool(named: "calculator")!.execute(argumentsJSON: #"{"expression":"1+1"}"#)
        XCTAssertEqual(out, "2", "the first-registered (built-in) tool wins tool(named:)")

        // Both colliding schemas are still advertised to the model.
        XCTAssertEqual(registry.schemas.filter { $0.name == "calculator" }.count, 2,
                       "the concatenation does not de-duplicate colliding names")
    }

    /// `ToolRegistry.build(mcpServers:)` hard-codes only [calculator, current_datetime, web_search] for its
    /// "standard" set — deliberately MISSING wikipedia + fetch_webpage that `ToolRegistry.standard` (and
    /// `.assemble`) include. Pin the exact contract so the divergence is caught if it drifts.
    func testBuildStandardTrioDivergesFromStandardFive() async {
        let built = await ToolRegistry.build(mcpServers: [])
        let builtNames = Set(built.schemas.map(\.name))
        XCTAssertEqual(builtNames, ["calculator", "current_datetime", "web_search"],
                       "build()'s includeStandard trio is exactly these three")

        let standardNames = Set(ToolRegistry.standard.schemas.map(\.name))
        XCTAssertEqual(standardNames,
                       ["calculator", "current_datetime", "wikipedia", "web_search", "fetch_webpage"])

        XCTAssertTrue(builtNames.isSubset(of: standardNames), "the trio is a strict subset of .standard")
        XCTAssertEqual(standardNames.subtracting(builtNames), ["wikipedia", "fetch_webpage"],
                       "the documented divergence: build() omits wikipedia + fetch_webpage")
    }
}
