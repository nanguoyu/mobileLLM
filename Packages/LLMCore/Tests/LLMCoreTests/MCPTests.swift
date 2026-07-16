// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// MCP client: pure SSE parsing + JSON-Schema flattening (no network), and — gated behind an env var — a
/// live handshake against the public DeepWiki server.
final class MCPTests: XCTestCase {

    // MARK: Pure — SSE framing

    func testParseSSEMatchesById() {
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}\n\n"
        let obj = MCPClient.parseSSE(Data(sse.utf8), id: 2)
        XCTAssertNotNil(obj)
        XCTAssertEqual((obj?["result"] as? [String: Any])?["ok"] as? Bool, true)
    }

    func testParseSSEIgnoresNonMatchingIdEvents() {
        // A server notification (no id) precedes our reply — must skip to the id:5 event.
        let sse = """
        data: {"jsonrpc":"2.0","method":"notifications/message","params":{}}

        data: {"jsonrpc":"2.0","id":5,"result":{"value":42}}

        """
        let obj = MCPClient.parseSSE(Data(sse.utf8), id: 5)
        XCTAssertEqual((obj?["result"] as? [String: Any])?["value"] as? Int, 42)
        XCTAssertNil(MCPClient.parseSSE(Data(sse.utf8), id: 999))
    }

    func testParseSSEJoinsMultipleDataLines() {
        let sse = "data: {\"jsonrpc\":\"2.0\",\"id\":1,\ndata:  \"result\":{\"a\":1}}\n\n"
        let obj = MCPClient.parseSSE(Data(sse.utf8), id: 1)
        XCTAssertEqual((obj?["result"] as? [String: Any])?["a"] as? Int, 1)
    }

    // MARK: Pure — schema flattening

    func testMCPToolParamsFromSchema() {
        let schema = #"""
        {"type":"object","properties":{
          "repoName":{"type":"string","description":"owner/repo"},
          "page":{"type":"integer","description":"page"},
          "verbose":{"type":"boolean"}
        },"required":["repoName"]}
        """#
        let params = MCPTool.params(fromInputSchema: schema)
        XCTAssertEqual(params.map(\.name), ["page", "repoName", "verbose"])   // sorted
        let repo = params.first { $0.name == "repoName" }!
        XCTAssertEqual(repo.kind, .string)
        XCTAssertTrue(repo.required)
        XCTAssertEqual(params.first { $0.name == "page" }?.kind, .number)
        XCTAssertEqual(params.first { $0.name == "verbose" }?.kind, .boolean)
        XCTAssertFalse(params.first { $0.name == "verbose" }!.required)
    }

    func testMCPToolParamsEmptyForNoArgTool() {
        XCTAssertTrue(MCPTool.params(fromInputSchema: #"{"type":"object"}"#).isEmpty)
    }

    // MARK: Server config — persistence + gating

    /// The dangerous one: `MCPServer` gained `isEnabled`/`disabledTools` after v1 shipped. The synthesized
    /// decoder throws on a missing non-optional key, and this struct decodes *inside* the settings
    /// snapshot — so a regression here doesn't lose your servers, it silently resets every setting.
    func testDecodesASnapshotWrittenBeforeTheNewFieldsExisted() throws {
        let old = #"{"name":"DeepWiki","url":"https://mcp.deepwiki.com/mcp"}"#
        let server = try JSONDecoder().decode(MCPServer.self, from: Data(old.utf8))
        XCTAssertEqual(server.name, "DeepWiki")
        XCTAssertTrue(server.isEnabled, "a server configured before the toggle existed stays on")
        XCTAssertTrue(server.disabledTools.isEmpty)
    }

    func testRoundTripsTheNewFields() throws {
        let server = MCPServer(name: "S", url: "https://h/mcp", token: "t",
                               isEnabled: false, disabledTools: ["noisy_tool"])
        let back = try JSONDecoder().decode(MCPServer.self, from: JSONEncoder().encode(server))
        XCTAssertEqual(back, server)
    }

    /// A disabled server must not even be contacted — the registry is what gates it.
    func testDisabledServerIsNotConsulted() async {
        let unreachable = MCPServer(name: "off", url: "https://127.0.0.1:1/mcp", isEnabled: false)
        let registry = await ToolRegistry.build(mcpServers: [unreachable])
        // Only the three standard local tools; no hang, no attempt.
        XCTAssertEqual(registry.schemas.map(\.name).sorted(),
                       ["calculator", "current_datetime", "web_search"])
    }

    // MARK: Live — DeepWiki (opt-in: MCP_LIVE=1)

    func testLiveDeepWikiConnectAndCall() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MCP_LIVE"] == "1",
                          "network test — set MCP_LIVE=1 to run")
        let client = MCPClient(server: MCPServer(name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp"))
        let tools = try await client.connect()
        XCTAssertTrue(tools.contains { $0.name == "ask_question" }, "DeepWiki should advertise ask_question")
        let answer = try await client.call(
            name: "ask_question",
            argumentsJSON: #"{"repoName":"ggml-org/llama.cpp","question":"What is Q1_0 quantization in one sentence?"}"#)
        XCTAssertFalse(answer.isEmpty)
        XCTAssertFalse(answer.hasPrefix("Tool error"))
    }
}
