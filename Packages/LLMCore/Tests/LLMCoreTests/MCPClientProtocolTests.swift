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

    /// The bearer token must not follow a redirect. This client is the only HTTP caller in the package that
    /// carries a credential (`Authorization: Bearer <token>` on every request), and URLSession's default is
    /// to replay the whole request — header and all — at whatever host the 3xx `Location` names. The web
    /// tools got manual redirect control while this, the credentialed path, kept the default; that was
    /// backwards. Asserting on the error alone would be worthless here: the token would already be gone by
    /// the time it was raised, so this pins that the target host is never CONTACTED.
    func testARedirectIsRefusedAndTheTokenNeverReachesTheNewHost() async {
        MCPMockProtocol.requestedHosts = []
        let client = MCPClient(server: MCPServer(name: "r", url: "https://mock.mcp/redirect",
                                                 token: "SECRET-TOKEN"),
                               session: mockSession())
        do {
            _ = try await client.connect()
            XCTFail("a redirect away from the configured endpoint must not be followed")
        } catch let error as MCPClient.MCPError {
            XCTAssertEqual(error, .http(307), "the 3xx is surfaced instead of being followed")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(MCPMockProtocol.requestedHosts, ["mock.mcp"],
                       "the credential must never be replayed at the redirect target — contacted: "
                       + "\(MCPMockProtocol.requestedHosts)")
    }

    func testToolsListRejectsARepeatedCursor() async {
        let client = MCPClient(server: MCPServer(name: "r", url: "https://mock.mcp/repeat-cursor"),
                               session: mockSession())
        do {
            _ = try await client.connect()
            XCTFail("a repeated cursor must terminate pagination")
        } catch let error as MCPClient.MCPError {
            XCTAssertEqual(error, .repeatedCursor("LOOP"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testToolsListHasABoundedPageCount() async {
        let client = MCPClient(server: MCPServer(name: "e", url: "https://mock.mcp/endless-pages"),
                               session: mockSession(), maxToolListPages: 2)
        do {
            _ = try await client.connect()
            XCTFail("an endless unique cursor chain must terminate at the configured page cap")
        } catch let error as MCPClient.MCPError {
            XCTAssertEqual(error, .pageLimit(2))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// One server erroring (HTTP 500 on `initialize`) must not take the others down: `ToolRegistry.build`
    /// skips the bad server and keeps the good one's tools (plus the standard local tools).
    func testBuildSkipsAFailingServerButKeepsAGoodOne() async throws {
        let servers = [
            MCPServer(name: "bad", url: "https://mock.mcp/bad500"),
            MCPServer(name: "good", url: "https://mock.mcp/good"),
        ]
        let registry = try await ToolRegistry.build(mcpServers: servers, session: mockSession())
        let names = Set(registry.schemas.map(\.name))
        XCTAssertTrue(names.contains("good_echo"), "the reachable server's tool survives")
        XCTAssertTrue(names.isSuperset(of: ["calculator", "current_datetime", "web_search"]),
                      "the standard local tools remain")
    }

    /// Ordinary server failures stay isolated, but user cancellation is control flow: it must abort the
    /// entire build instead of returning and inviting the caller to cache tools from only the first server.
    func testBuildPropagatesCancellationInsteadOfReturningAPartialRegistry() async throws {
        let reachedSecondServer = expectation(description: "the good server finished and registry-hang started")
        MCPMockProtocol.registryHangStarted = reachedSecondServer
        defer { MCPMockProtocol.registryHangStarted = nil }
        let servers = [
            MCPServer(name: "good", url: "https://mock.mcp/good"),
            MCPServer(name: "hang", url: "https://mock.mcp/registry-hang"),
        ]
        let task = Task {
            try await ToolRegistry.build(mcpServers: servers, includeStandard: false,
                                         session: mockSession())
        }
        await fulfillment(of: [reachedSecondServer], timeout: 1)
        task.cancel()

        do {
            let partial = try await task.value
            XCTFail("cancelled assembly returned a partial registry: \(partial.schemas.map(\.name))")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("cancellation was swallowed or wrapped as \(error)")
        }
    }

    func testHTTPStatusIsPreserved() async {
        let client = MCPClient(server: MCPServer(name: "bad", url: "https://mock.mcp/bad500"),
                               session: mockSession())
        do {
            _ = try await client.connect()
            XCTFail("HTTP 500 must be surfaced")
        } catch let error as MCPClient.MCPError {
            XCTAssertEqual(error, .http(500))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testHTTP200InvalidJSONIsRejected() async {
        let client = MCPClient(server: MCPServer(name: "bad-json", url: "https://mock.mcp/invalid-json"),
                               session: mockSession())
        await assertInvalidResponse(client, contains: "not valid JSON")
    }

    func testHTTP200WrongResponseIDIsRejected() async {
        let client = MCPClient(server: MCPServer(name: "wrong-id", url: "https://mock.mcp/wrong-id"),
                               session: mockSession())
        await assertInvalidResponse(client, contains: "response id does not match")
    }

    func testHTTP200ResponseWithoutResultOrErrorIsRejected() async {
        let client = MCPClient(server: MCPServer(name: "no-outcome", url: "https://mock.mcp/no-outcome"),
                               session: mockSession())
        await assertInvalidResponse(client, contains: "exactly one of result or error")
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

    func testSSEEndingWithoutAMatchingResponseIsRejected() async {
        let client = MCPClient(server: MCPServer(name: "u", url: "https://mock.mcp/sse-no-match"),
                               session: mockSession())
        await assertInvalidResponse(client, contains: "missing response")
    }

    /// Streamable HTTP SSE connections are normally long-lived. The matching JSON-RPC event is complete,
    /// but this fixture deliberately never calls `urlProtocolDidFinishLoading`; connect must still return.
    func testSSEReplyReturnsAfterMatchingEventWithoutWaitingForConnectionClose() async throws {
        let client = MCPClient(server: MCPServer(name: "s", url: "https://mock.mcp/open-sse"),
                               session: mockSession(), requestTimeout: 0.5)
        let tools = try await client.connect()
        XCTAssertEqual(tools.map(\.name), ["open_stream_tool"])
    }

    func testEveryRequestHasAnOverallTimeout() async {
        let client = MCPClient(server: MCPServer(name: "h", url: "https://mock.mcp/hang"),
                               session: mockSession(), requestTimeout: 0.05)
        do {
            _ = try await client.connect()
            XCTFail("a response that never supplies or finishes a body must time out")
        } catch let error as MCPClient.MCPError {
            guard case .timedOut(let seconds) = error else {
                return XCTFail("expected a diagnostic timeout, got \(error)")
            }
            XCTAssertEqual(seconds, 0.05, accuracy: 0.001)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCancellationIsPreservedAsCancellationError() async throws {
        let client = MCPClient(server: MCPServer(name: "h", url: "https://mock.mcp/hang"),
                               session: mockSession(), requestTimeout: 5)
        let task = Task { try await client.connect() }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled connect must not look like an ordinary MCP failure")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("cancellation was wrapped as \(error)")
        }
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

    private func assertInvalidResponse(_ client: MCPClient, contains expectedText: String,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client.connect()
            XCTFail("HTTP 200 must not turn an invalid JSON-RPC response into success", file: file, line: line)
        } catch let error as MCPClient.MCPError {
            guard case .invalidResponse(let reason) = error else {
                return XCTFail("expected invalidResponse, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(expectedText), "unexpected reason: \(reason)", file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}

// MARK: - Canned-transcript URLProtocol (stateless; a pure function of URL + method + cursor)

private final class MCPMockProtocol: URLProtocol {
    static var registryHangStarted: XCTestExpectation?
    /// Every host this protocol was asked to load. Lets a test assert that a redirect target was never
    /// CONTACTED, which is the actual security property — an error alone would also be returned if the
    /// credential had already been replayed at the attacker's host.
    nonisolated(unsafe) static var requestedHosts: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requestedHosts.append(request.url?.host ?? "?")
        let body = Self.readBody(request)
        let method = body["method"] as? String ?? ""
        let id = body["id"] as? Int
        let cursor = (body["params"] as? [String: Any])?["cursor"] as? String
        let path = request.url?.path ?? ""
        if path.hasSuffix("/registry-hang"), method == "initialize" {
            Self.registryHangStarted?.fulfill()
        }

        let responseParts: (Int, [String: String], Data)
        if path.hasSuffix("/open-sse"), method == "tools/list",
           request.value(forHTTPHeaderField: "Mcp-Session-Id") != "sess-123"
            || request.value(forHTTPHeaderField: "MCP-Protocol-Version") != "2025-11-25" {
            responseParts = (409, ["Content-Type": "application/json"], Data())
        } else {
            responseParts = Self.respond(path: path, method: method, id: id, cursor: cursor)
        }
        let (status, headers, payload) = responseParts
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        // A 3xx must be signalled through `wasRedirectedTo:` — merely returning the status code does NOT
        // engage URLSession's redirect machinery (and therefore would not consult the session delegate at
        // all, making a redirect test silently pass with or without the fix).
        if (300...399).contains(status), let location = headers["Location"],
           let target = URL(string: location) {
            var followUp = request
            followUp.url = target
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
            // If the session declines the redirect, the 3xx itself is the task's response; deliver and
            // finish so the request completes instead of hanging until the client's overall deadline.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty { client?.urlProtocol(self, didLoad: payload) }
        let staysOpen = (path.hasSuffix("/open-sse") && method == "tools/list")
            || ((path.hasSuffix("/hang") || path.hasSuffix("/registry-hang")) && method == "initialize")
        if !staysOpen { client?.urlProtocolDidFinishLoading(self) }
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
            if path.hasSuffix("/redirect") {
                // A configured endpoint that answers the credentialed handshake with a redirect to another
                // host. URLSession's default behavior would replay the POST — Authorization header included
                // — at `attacker.example`.
                return (307, ["Location": "https://attacker.example/steal"], Data())
            }
            if path.hasSuffix("/hang") || path.hasSuffix("/registry-hang") {
                // Headers arrive, but the body and connection never finish.
                return (200, jsonHeaders, Data())
            }
            if path.hasSuffix("/bad500") {
                return (500, jsonHeaders, Data(#"{"jsonrpc":"2.0","error":{"message":"boom"}}"#.utf8))
            }
            if path.hasSuffix("/invalid-json") {
                return (200, jsonHeaders, Data("this is not json".utf8))
            }
            if path.hasSuffix("/wrong-id") {
                let wrongID = (id ?? 0) + 1
                let object: [String: Any] = [
                    "jsonrpc": "2.0", "id": wrongID,
                    "result": ["protocolVersion": "2025-11-25"],
                ]
                return (200, jsonHeaders,
                        (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            }
            if path.hasSuffix("/no-outcome") {
                let object: [String: Any] = ["jsonrpc": "2.0", "id": id ?? 0]
                return (200, jsonHeaders,
                        (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
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
            if path.hasSuffix("/repeat-cursor") {
                return (200, jsonHeaders, result(["tools": [toolSpec("loop_tool")], "nextCursor": "LOOP"]))
            }
            if path.hasSuffix("/endless-pages") {
                let page = Int(cursor?.replacingOccurrences(of: "PAGE", with: "") ?? "0") ?? 0
                return (200, jsonHeaders,
                        result(["tools": [toolSpec("page_\(page)")], "nextCursor": "PAGE\(page + 1)"]))
            }
            if path.hasSuffix("/open-sse") {
                let realId = id ?? 0
                let object: [String: Any] = [
                    "jsonrpc": "2.0", "id": realId,
                    "result": ["tools": [toolSpec("open_stream_tool")]],
                ]
                let json = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(),
                                  as: UTF8.self)
                return (200, ["Content-Type": "text/event-stream"],
                        Data("event: message\r\ndata: \(json)\r\n\r\n".utf8))
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
            if path.hasSuffix("/sse-no-match") {
                let decoy: [String: Any] = [
                    "jsonrpc": "2.0", "id": (id ?? 0) + 777,
                    "result": ["tools": [toolSpec("WRONG_tool")]],
                ]
                let json = String(decoding: (try? JSONSerialization.data(withJSONObject: decoy)) ?? Data(),
                                  as: UTF8.self)
                return (200, ["Content-Type": "text/event-stream"],
                        Data("event: message\r\ndata: \(json)\r\n\r\n".utf8))
            }
            return (200, jsonHeaders, result(["tools": [toolSpec("good_echo")]]))

        case "tools/call":
            return (200, jsonHeaders, result(["content": [["type": "text", "text": "CALLED"]]]))

        default:
            return (200, jsonHeaders, result([:]))
        }
    }
}
