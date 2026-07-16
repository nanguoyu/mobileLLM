// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// MCP client protocol edges driven by CANNED transcripts (no network): a `URLProtocol` stub keyed purely
/// on the request URL + the JSON-RPC method/cursor read from the POST body, injected through the client's
/// `session:` seam. These exercise the wire behaviors the existing pure-`parseSSE` tests can't reach:
/// pagination, per-server fault isolation in `ToolRegistry.build`, an interleaved SSE reply, and a
/// stateless (no `Mcp-Session-Id`) server.
final class MCPClientProtocolTests: XCTestCase {

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPMockProtocol.self]
        return URLSession(configuration: config)
    }

    /// `tools/list` paginates via `nextCursor`: the client must follow the cursor and return the UNION of
    /// every page, in order.
    func testToolsListPaginatesAcrossTwoPages() async throws {
        let client = MCPClient(server: MCPServer(name: "p", url: "https://mock.mcp/paginate"),
                               session: mockSession())
        let tools = try await client.connect()
        XCTAssertEqual(tools.map(\.name), ["page1_tool", "page2_tool"],
                       "both pages are fetched and concatenated in order")
    }

    /// One server erroring (HTTP 500 on `initialize`) must not take the others down: `ToolRegistry.build`
    /// skips the bad server and keeps the good one's tools (plus the standard local tools).
    func testBuildSkipsAFailingServerButKeepsAGoodOne() async {
        let servers = [
            MCPServer(name: "bad", url: "https://mock.mcp/bad500"),
            MCPServer(name: "good", url: "https://mock.mcp/good"),
        ]
        let registry = await ToolRegistry.build(mcpServers: servers, session: mockSession())
        let names = Set(registry.schemas.map(\.name))
        XCTAssertTrue(names.contains("good_echo"), "the reachable server's tool survives")
        XCTAssertTrue(names.isSuperset(of: ["calculator", "current_datetime", "web_search"]),
                      "the standard local tools remain")
    }

    /// The SSE reply carries an UNRELATED-id event before the matching one — the client must skip past it
    /// and parse the tools from the event whose id matches its request, never the decoy.
    func testSSEReplySkipsUnrelatedIdEvent() async throws {
        let client = MCPClient(server: MCPServer(name: "u", url: "https://mock.mcp/unrelated"),
                               session: mockSession())
        let tools = try await client.connect()
        XCTAssertEqual(tools.map(\.name), ["sse_tool"], "the matching-id event is used")
        XCTAssertFalse(tools.contains { $0.name == "WRONG_tool" }, "the unrelated-id decoy is ignored")
    }

    /// An `initialize` response WITHOUT an `Mcp-Session-Id` header means the server is stateless — the
    /// client must keep working (list + call) rather than depend on echoing a session id it never got.
    func testWorksStatelessWhenInitOmitsSessionId() async throws {
        let client = MCPClient(server: MCPServer(name: "n", url: "https://mock.mcp/nosession"),
                               session: mockSession())
        let tools = try await client.connect()
        XCTAssertEqual(tools.map(\.name), ["good_echo"], "listing works with no session id")
        let result = try await client.call(name: "good_echo", argumentsJSON: "{}")
        XCTAssertEqual(result, "CALLED", "calling works with no session id")
    }
}

// MARK: - Canned-transcript URLProtocol (stateless; a pure function of URL + method + cursor)

private final class MCPMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.readBody(request)
        let method = body["method"] as? String ?? ""
        let id = body["id"] as? Int
        let cursor = (body["params"] as? [String: Any])?["cursor"] as? String
        let path = request.url?.path ?? ""

        let (status, headers, payload) = Self.respond(path: path, method: method, id: id, cursor: cursor)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty { client?.urlProtocol(self, didLoad: payload) }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession strips `httpBody` by the time a request reaches a `URLProtocol` — the body is delivered as
    /// `httpBodyStream`. Read it so we can branch on the JSON-RPC `method`/`id`/`cursor`.
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

    private static func respond(path: String, method: String, id: Int?, cursor: String?)
        -> (Int, [String: String], Data) {
        let jsonHeaders = ["Content-Type": "application/json"]
        func result(_ result: [String: Any]) -> Data {
            var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
            if let id { obj["id"] = id }
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        }

        switch method {
        case "initialize":
            if path.hasSuffix("/bad500") {
                return (500, jsonHeaders, Data(#"{"jsonrpc":"2.0","error":{"message":"boom"}}"#.utf8))
            }
            var headers = jsonHeaders
            if !path.hasSuffix("/nosession") { headers["Mcp-Session-Id"] = "sess-123" }
            return (200, headers, result(["protocolVersion": "2025-11-25",
                                          "capabilities": [String: Any](),
                                          "serverInfo": ["name": "mock", "version": "1.0"]]))

        case "notifications/initialized":
            return (202, [:], Data())   // a JSON-RPC notification → empty 202, nothing to read

        case "tools/list":
            if path.hasSuffix("/paginate") {
                return cursor == nil
                    ? (200, jsonHeaders, result(["tools": [toolSpec("page1_tool")], "nextCursor": "CURSOR2"]))
                    : (200, jsonHeaders, result(["tools": [toolSpec("page2_tool")]]))
            }
            if path.hasSuffix("/unrelated") {
                let realId = id ?? 0
                let matching: [String: Any] = ["jsonrpc": "2.0", "id": realId,
                                               "result": ["tools": [toolSpec("sse_tool")]]]
                let decoy: [String: Any] = ["jsonrpc": "2.0", "id": realId + 777,
                                            "result": ["tools": [toolSpec("WRONG_tool")]]]
                func line(_ o: [String: Any]) -> String {
                    String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self)
                }
                // CRLF-framed, decoy first — the client must skip to the id-matching event.
                let sse = "event: message\r\ndata: \(line(decoy))\r\n\r\n"
                        + "event: message\r\ndata: \(line(matching))\r\n\r\n"
                return (200, ["Content-Type": "text/event-stream"], Data(sse.utf8))
            }
            return (200, jsonHeaders, result(["tools": [toolSpec("good_echo")]]))

        case "tools/call":
            return (200, jsonHeaders, result(["content": [["type": "text", "text": "CALLED"]]]))

        default:
            return (200, jsonHeaders, result([:]))
        }
    }
}
