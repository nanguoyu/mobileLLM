// SPDX-License-Identifier: MIT

import Foundation

/// A remote MCP (Model Context Protocol) server the user configured — a URL and an optional bearer token.
/// Sandboxed iOS can only reach HTTP servers, never stdio, so this is always a remote endpoint.
public struct MCPServer: Sendable, Hashable, Codable, Identifiable {
    public var id: String { url }
    public var name: String
    public var url: String
    public var token: String?
    /// Off = configured but not consulted — keep a server around without paying its connect on every turn.
    public var isEnabled: Bool
    /// Tools the user muted on this server. Muting beats disconnecting when a server advertises 30 tools
    /// and a small model only reliably picks from 3.
    public var disabledTools: Set<String>

    public init(name: String, url: String, token: String? = nil,
                isEnabled: Bool = true, disabledTools: Set<String> = []) {
        self.name = name; self.url = url; self.token = token
        self.isEnabled = isEnabled; self.disabledTools = disabledTools
    }

    /// Hand-written so a snapshot persisted before `isEnabled`/`disabledTools` existed still decodes —
    /// the synthesized decoder would throw on the missing keys and take every other setting down with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        disabledTools = try c.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? []
    }
}

/// A tool advertised by an MCP server (name + description + raw JSON-Schema for its arguments).
public struct MCPToolSpec: Sendable, Hashable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String
}

/// A minimal, self-contained MCP client over **Streamable HTTP** (protocol `2025-11-25`) — hand-rolled
/// JSON-RPC 2.0 on URLSession, no external SDK. Enough to `initialize`, `tools/list`, and `tools/call`
/// against a user-supplied server, so its tools bridge into our local `Tool` protocol. Handles both a
/// plain-JSON response and a single-event SSE response (many servers, incl. DeepWiki, always reply SSE),
/// captures + echoes a session id when the server is stateful, and sends the negotiated protocol-version
/// header on every post after the handshake.
public actor MCPClient {
    public enum MCPError: Error, Sendable { case badURL, http(Int), rpc(String) }

    private let server: MCPServer
    private let session: URLSession
    private var negotiatedVersion = "2025-11-25"
    private var sessionId: String?
    private var nextId = 0
    private var ready = false

    public init(server: MCPServer, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    /// Handshake + list the server's tools (paginating `nextCursor`). Idempotent-ish: re-handshakes only
    /// if not already connected.
    public func connect() async throws -> [MCPToolSpec] {
        if !ready {
            let initResult = try await request(method: "initialize", params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "mobileLLM", "version": "1.0.0"],
            ], isInit: true)
            if let v = initResult?["protocolVersion"] as? String { negotiatedVersion = v }
            try await notify(method: "notifications/initialized")
            ready = true
        }
        var tools: [MCPToolSpec] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let res = try await request(method: "tools/list", params: params)
            for t in (res?["tools"] as? [[String: Any]] ?? []) {
                guard let name = t["name"] as? String else { continue }
                let desc = t["description"] as? String ?? ""
                let schema = t["inputSchema"] ?? ["type": "object"]
                let json = (try? JSONSerialization.data(withJSONObject: schema))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                tools.append(MCPToolSpec(name: name, description: desc, inputSchemaJSON: json))
            }
            cursor = res?["nextCursor"] as? String
        } while cursor != nil
        return tools
    }

    /// Call a tool; returns its text content (or an "error" string for a tool-level failure the model reads).
    public func call(name: String, argumentsJSON: String) async throws -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let res = try await request(method: "tools/call", params: ["name": name, "arguments": args])
        let text = (res?["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        let isError = res?["isError"] as? Bool ?? false
        if isError { return "Tool error: \(text.isEmpty ? "unknown" : text)" }
        return text.isEmpty ? "(the tool returned no text content)" : text
    }

    // MARK: - JSON-RPC

    private func request(method: String, params: [String: Any], isInit: Bool = false) async throws -> [String: Any]? {
        nextId += 1
        let id = nextId
        let obj = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params],
                                 isInit: isInit, expectId: id)
        if let err = obj?["error"] as? [String: Any] {
            throw MCPError.rpc(err["message"] as? String ?? "MCP error")
        }
        return obj?["result"] as? [String: Any]
    }

    private func notify(method: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method], isInit: false, expectId: nil)
    }

    /// POST a JSON-RPC message; branch JSON vs SSE; return the reply object matching `expectId` (nil for
    /// notifications, which get an empty 202).
    private func post(_ body: [String: Any], isInit: Bool, expectId: Int?) async throws -> [String: Any]? {
        guard let url = URL(string: server.url) else { throw MCPError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = server.token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !isInit { req.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionId { req.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.http(0) }
        if isInit, let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = sid }
        guard (200...299).contains(http.statusCode) else { throw MCPError.http(http.statusCode) }
        guard let expectId else { return nil }   // notification → nothing to read

        let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ctype.hasPrefix("text/event-stream") {
            return Self.parseSSE(data, id: expectId)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Parse an SSE body and return the first `data:` event whose JSON-RPC `id` matches (servers may
    /// interleave their own notifications first).
    static func parseSSE(_ data: Data, id: Int) -> [String: Any]? {
        // Normalize CRLF/CR → LF first: servers frame SSE with \r\n, which otherwise leaves the blank-line
        // terminator non-empty and a trailing \r on the JSON (both break naive parsing).
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var dataLines: [String] = []
        func flush() -> [String: Any]? {
            defer { dataLines.removeAll() }
            let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { return nil }
            return (obj["id"] as? Int) == id ? obj : nil
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                if let match = flush() { return match }
            } else if line.hasPrefix("data:") {
                var s = String(line.dropFirst(5))
                if s.hasPrefix(" ") { s.removeFirst() }
                dataLines.append(s)
            }
            // ignore event:/id:/retry:/comment lines
        }
        return flush()
    }
}
