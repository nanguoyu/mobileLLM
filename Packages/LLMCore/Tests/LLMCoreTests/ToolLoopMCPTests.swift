// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// MCP driven END-TO-END through the agent loop and the `MCPClient.call` result-mapping branches — the
/// bridge the existing MCP tests (connect/list/pure-parse) never exercise. A canned `URLProtocol` transcript
/// stands in for a real server: the model emits a `<tool_call>` for an MCP tool, `MCPTool.execute` forwards
/// to `MCPClient.call` over the transcript, the result is framed as untrusted and fed back, and the second
/// model turn is asserted. Also pins `call()`'s isError / empty-content branches and argument forwarding.
final class ToolLoopMCPTests: XCTestCase {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoopMCPMockProtocol.self]
        return URLSession(configuration: config)
    }

    private func server(_ path: String) -> MCPServer { MCPServer(name: "mock", url: "https://mock.mcp\(path)") }

    // MARK: - MCP tool executes through the loop

    /// The happy bridge: `good_echo` runs via `MCPTool.execute` → `MCPClient.call` → "CALLED", framed as
    /// untrusted into the follow-up turn, and the second model turn's answer surfaces.
    func testMCPToolExecutesThroughLoopAndFramesResult() async throws {
        let registry = await ToolRegistry.build(mcpServers: [server("/good")], includeStandard: false,
                                                session: mockSession())
        XCTAssertTrue(registry.tool(named: "good_echo") != nil, "the MCP tool bridged into the registry")

        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"good_echo","arguments":{}}</tool_call>"#,
            "The MCP tool replied.",
        ])
        let events = try await collectLoop(ToolLoop(engine: engine, registry: registry), "call the mcp tool")

        XCTAssertEqual(toolCallNames(events), ["good_echo"])
        XCTAssertEqual(toolResults(events), ["CALLED"], "the MCP tool's text content is surfaced")
        // The MCP result is framed as untrusted into turn 2 (MCP output is attacker-controllable too).
        let turn = engine.receivedHistories()[1].first { $0.content.contains("CALLED") }
        XCTAssertNotNil(turn)
        XCTAssertTrue(turn!.content.contains("====="), "the MCP result is fenced")
        XCTAssertTrue(turn!.content.lowercased().contains("untrusted"))
        XCTAssertTrue(answerText(events).contains("The MCP tool replied."))
    }

    /// A tool-level failure (`isError: true`) maps to "Tool error: …" and is fed back through the loop
    /// without crashing — the loop keeps going to a final answer.
    func testMCPToolErrorIsFedBackThroughLoop() async throws {
        let registry = await ToolRegistry.build(mcpServers: [server("/good")], includeStandard: false,
                                                session: mockSession())
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"err_tool","arguments":{}}</tool_call>"#,
            "Acknowledged the error.",
        ])
        let events = try await collectLoop(ToolLoop(engine: engine, registry: registry), "call the failing tool")

        XCTAssertEqual(toolResults(events), ["Tool error: boom"], "a tool-level error maps to a readable string")
        let turn = engine.receivedHistories()[1].first { $0.content.contains("Tool error: boom") }
        XCTAssertNotNil(turn, "the error text is framed back to the model")
        XCTAssertTrue(answerText(events).contains("Acknowledged the error."), "the loop still reaches a final answer")
    }

    /// The `MCPTool.execute` catch path: when `MCPClient.call` THROWS (a JSON-RPC error), execute returns a
    /// "…failed: …" string instead of crashing, and the loop feeds it back and continues.
    func testMCPToolThrowingCallIsCaughtInLoop() async throws {
        let registry = await ToolRegistry.build(mcpServers: [server("/good")], includeStandard: false,
                                                session: mockSession())
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"rpc_error_tool","arguments":{}}</tool_call>"#,
            "Recovered.",
        ])
        let events = try await collectLoop(ToolLoop(engine: engine, registry: registry), "trigger an rpc error")

        XCTAssertEqual(toolCallNames(events), ["rpc_error_tool"])
        XCTAssertTrue(toolResults(events).first?.contains("failed") ?? false,
                      "the thrown call is caught into a failure string: \(toolResults(events))")
        XCTAssertTrue(answerText(events).contains("Recovered."), "no crash — the loop continues")
    }

    // MARK: - MCPClient.call() result-mapping branches + argument forwarding

    func testCallMapsToolLevelError() async throws {
        let client = MCPClient(server: server("/good"), session: mockSession())
        let result = try await client.call(name: "err_tool", argumentsJSON: "{}")
        XCTAssertEqual(result, "Tool error: boom")
    }

    func testCallMapsEmptyContent() async throws {
        let client = MCPClient(server: server("/good"), session: mockSession())
        let result = try await client.call(name: "empty_tool", argumentsJSON: "{}")
        XCTAssertEqual(result, "(the tool returned no text content)")
    }

    /// The arguments JSON must reach the server's `params.arguments` — the mock echoes back what it received,
    /// proving they aren't dropped/misplaced on the wire. Decoded, not substring-matched, because
    /// JSONSerialization escapes `/` as `\/` in the echoed string (the value itself is intact).
    func testCallForwardsArgumentsIntoParams() async throws {
        let client = MCPClient(server: server("/good"), session: mockSession())
        let result = try await client.call(name: "echo_args", argumentsJSON: #"{"repoName":"a/b"}"#)
        let echoed = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        XCTAssertEqual(echoed?["repoName"] as? String, "a/b",
                       "the argument key+value round-tripped into params.arguments: \(result)")
    }

    // MARK: - Combined built-in + MCP registry (collision resolution)

    /// `ToolRegistry.build(includeStandard: true)` concatenates the standard local tools with an MCP server's
    /// tools. When the server advertises a name that collides with a built-in ("web_search"), the built-in
    /// (registered first) wins `tool(named:)`, the unique MCP tool is present, and the schema list carries
    /// BOTH colliding entries (they are NOT de-duplicated — pinning the current contract).
    func testCombinedRegistryResolvesCollisionToBuiltInAndKeepsUnique() async throws {
        let registry = await ToolRegistry.build(mcpServers: [server("/collide")], includeStandard: true,
                                                session: mockSession())
        let names = registry.schemas.map(\.name)
        XCTAssertTrue(names.contains("calculator"), "standard local tools are present")
        XCTAssertTrue(names.contains("unique_mcp"), "the unique MCP tool is present")

        // The collision resolves to the FIRST match — the built-in web_search (which has a 'query' param;
        // the MCP mock's web_search advertises none).
        let resolved = registry.tool(named: "web_search")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.schema.parameters.first?.name, "query",
                       "tool(named:) resolves the colliding name to the built-in web_search")
        XCTAssertEqual(names.filter { $0 == "web_search" }.count, 2,
                       "both colliding schemas are advertised to the model (not de-duplicated)")
    }
}

// MARK: - Extended canned-transcript URLProtocol (good_echo + err/empty/echo/rpc + collision listing)

/// A stateless MCP mock: a pure function of URL path + the JSON-RPC method/name/arguments read from the POST
/// body. Extends the base transcript with tools that map to `call()`'s error / empty / argument-echo
/// branches, and a `/collide` listing that advertises a name colliding with a built-in.
private final class LoopMCPMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.readBody(request)
        let method = body["method"] as? String ?? ""
        let id = body["id"] as? Int
        let params = body["params"] as? [String: Any] ?? [:]
        let path = request.url?.path ?? ""

        let (status, headers, payload) = Self.respond(path: path, method: method, id: id, params: params)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty { client?.urlProtocol(self, didLoad: payload) }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession delivers the body via `httpBodyStream` by the time a request reaches a `URLProtocol`.
    private static func readBody(_ request: URLRequest) -> [String: Any] {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            let n = 8192
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: n); defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: n)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
        } else if let b = request.httpBody {
            data = b
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private static func toolSpec(_ name: String) -> [String: Any] {
        ["name": name, "description": "mock \(name)", "inputSchema": ["type": "object"]]
    }

    private static func respond(path: String, method: String, id: Int?, params: [String: Any])
        -> (Int, [String: String], Data) {
        let jsonHeaders = ["Content-Type": "application/json"]
        func result(_ result: [String: Any]) -> Data {
            var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
            if let id { obj["id"] = id }
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        }

        switch method {
        case "initialize":
            return (200, jsonHeaders.merging(["Mcp-Session-Id": "sess-1"]) { a, _ in a },
                    result(["protocolVersion": "2025-11-25", "capabilities": [String: Any](),
                            "serverInfo": ["name": "mock", "version": "1.0"]]))

        case "notifications/initialized":
            return (202, [:], Data())

        case "tools/list":
            if path.hasSuffix("/collide") {
                return (200, jsonHeaders, result(["tools": [toolSpec("web_search"), toolSpec("unique_mcp")]]))
            }
            return (200, jsonHeaders, result(["tools": [
                toolSpec("good_echo"), toolSpec("err_tool"), toolSpec("empty_tool"),
                toolSpec("echo_args"), toolSpec("rpc_error_tool"),
            ]]))

        case "tools/call":
            let name = params["name"] as? String ?? ""
            switch name {
            case "err_tool":
                return (200, jsonHeaders, result(["content": [["type": "text", "text": "boom"]], "isError": true]))
            case "empty_tool":
                return (200, jsonHeaders, result(["content": [[String: Any]]()]))
            case "echo_args":
                let args = params["arguments"] ?? [String: Any]()
                let echoed = (try? JSONSerialization.data(withJSONObject: args))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return (200, jsonHeaders, result(["content": [["type": "text", "text": echoed]]]))
            case "rpc_error_tool":
                // A JSON-RPC error (not a tool-level isError) makes MCPClient.call THROW.
                var obj: [String: Any] = ["jsonrpc": "2.0", "error": ["code": -32000, "message": "kaboom"]]
                if let id { obj["id"] = id }
                return (200, jsonHeaders, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
            default:
                return (200, jsonHeaders, result(["content": [["type": "text", "text": "CALLED"]]]))
            }

        default:
            return (200, jsonHeaders, result([:]))
        }
    }
}
