// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit

/// A remote MCP (Model Context Protocol) server the user configured — a URL and an optional bearer token.
/// Sandboxed iOS can only reach HTTP servers, never stdio, so this is always a remote endpoint.
public struct MCPServer: Sendable, Hashable, Codable, Identifiable {
    /// Stable random identity for agent destinations and approval scope. The URL is mutable (editing a
    /// server's address must not re-scope previously approved operations), so identity is NEVER the URL.
    public var stableID: UUID
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
                isEnabled: Bool = true, disabledTools: Set<String> = [],
                stableID: UUID = UUID()) {
        self.stableID = stableID; self.name = name; self.url = url; self.token = token
        self.isEnabled = isEnabled; self.disabledTools = disabledTools
    }

    /// Hand-written so a snapshot persisted before `isEnabled`/`disabledTools` existed still decodes —
    /// the synthesized decoder would throw on the missing keys and take every other setting down with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        // Legacy records predate stable random identity. Derive a deterministic fallback from the URL
        // so a decoded-then-persisted upgrade does not re-scope approvals on every launch; once saved,
        // the record carries its own stable UUID and URL edits no longer move its identity.
        stableID = try c.decodeIfPresent(UUID.self, forKey: .stableID)
            ?? Self.legacyStableID(for: url)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        disabledTools = try c.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? []
    }

    private static func legacyStableID(for url: String) -> UUID {
        let digest = SHA256.hash(data: Data(url.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// A tool advertised by an MCP server (name + description + raw JSON-Schema for its arguments).
public struct MCPToolSpec: Sendable, Hashable, Codable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

/// A minimal, self-contained MCP client over **Streamable HTTP** (protocol `2025-11-25`) — hand-rolled
/// JSON-RPC 2.0 on URLSession, no external SDK. Enough to `initialize`, `tools/list`, and `tools/call`
/// against a user-supplied server, so its tools bridge into our local `Tool` protocol. Handles both a
/// plain-JSON response and a single-event SSE response (many servers, incl. DeepWiki, always reply SSE),
/// captures + echoes a session id when the server is stateful, and sends the negotiated protocol-version
/// header on every post after the handshake.
public actor MCPClient {
    public enum MCPError: Error, Sendable, Equatable, LocalizedError {
        case badURL
        case http(Int)
        case rpc(String)
        case timedOut(TimeInterval)
        case repeatedCursor(String)
        case pageLimit(Int)
        case responseTooLarge
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .badURL:
                "The MCP server URL is invalid."
            case .http(let status):
                "The MCP server returned HTTP \(status)."
            case .rpc(let message):
                message
            case .timedOut(let seconds):
                "The MCP server did not respond within \(seconds.formatted(.number.precision(.fractionLength(0...1)))) seconds."
            case .repeatedCursor(let cursor):
                "The MCP server repeated tools/list cursor “\(cursor)”."
            case .pageLimit(let limit):
                "The MCP server exceeded the \(limit)-page tools/list limit."
            case .responseTooLarge:
                "The MCP server response was too large."
            case .invalidResponse(let reason):
                "The MCP server returned an invalid JSON-RPC response: \(reason)"
            }
        }
    }

    private let server: MCPServer
    private let session: URLSession
    /// Held because `URLSession` keeps only an unowned-ish reference for the lifetime of the session;
    /// see `init` for why this client refuses redirects at all.
    private let redirectBlocker: MCPRedirectBlocker
    private let requestTimeout: TimeInterval
    private let maxToolListPages: Int
    private var negotiatedVersion = "2025-11-25"
    private var sessionId: String?
    private var nextId = 0
    private var ready = false

    /// `requestTimeout` is an overall deadline, not only URLSession's idle timeout: a server that keeps an
    /// SSE connection alive with unrelated events still has to answer this request. `maxToolListPages`
    /// bounds a malicious or broken cursor chain.
    public init(server: MCPServer, session: URLSession = .shared,
                requestTimeout: TimeInterval = 30, maxToolListPages: Int = 50) {
        self.server = server
        // Derived from the caller's CONFIGURATION rather than used directly, so this one client can refuse
        // redirects. It is the only HTTP caller in the package that carries a credential — the server's
        // bearer token rides every request — and URLSession's default behavior replays the whole request,
        // Authorization header included, at whatever host a 3xx `Location` names. The web tools were given
        // manual redirect control (`WebHTTPClient`) while this, the credentialed path, kept the default;
        // that was backwards. A configured MCP endpoint has no legitimate reason to redirect, so the 3xx is
        // surfaced as an HTTP error instead of being followed. Building from `configuration` keeps the
        // injected-session test seam working: URLProtocol stubs live on the configuration.
        self.redirectBlocker = MCPRedirectBlocker()
        self.session = URLSession(configuration: session.configuration,
                                  delegate: self.redirectBlocker, delegateQueue: nil)
        self.requestTimeout = min(max(requestTimeout, 0.01), 300)
        self.maxToolListPages = min(max(maxToolListPages, 1), 1_000)
    }

    /// URLSession retains its delegate until invalidated; without this the session and delegate outlive
    /// every client we build per registry assembly.
    deinit { session.finishTasksAndInvalidate() }

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
        var seenCursors = Set<String>()
        var pageCount = 0
        while true {
            try Task.checkCancellation()
            guard pageCount < maxToolListPages else {
                throw MCPError.pageLimit(maxToolListPages)
            }
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let res = try await request(method: "tools/list", params: params)
            pageCount += 1
            for t in (res?["tools"] as? [[String: Any]] ?? []) {
                guard let name = t["name"] as? String else { continue }
                let desc = t["description"] as? String ?? ""
                let schema = t["inputSchema"] ?? ["type": "object"]
                let json = (try? JSONSerialization.data(withJSONObject: schema))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                tools.append(MCPToolSpec(name: name, description: desc, inputSchemaJSON: json))
            }
            guard let nextCursor = res?["nextCursor"] as? String else { return tools }
            guard seenCursors.insert(nextCursor).inserted else {
                throw MCPError.repeatedCursor(nextCursor)
            }
            cursor = nextCursor
        }
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
        req.timeoutInterval = requestTimeout

        let response = try await perform(req, expectId: expectId)
        if isInit, let sid = response.sessionId { sessionId = sid }
        guard (200...299).contains(response.statusCode) else { throw MCPError.http(response.statusCode) }
        guard let expectId else { return nil }   // notification → nothing to read
        guard let payload = response.payload else {
            throw MCPError.invalidResponse("missing response for request id \(expectId).")
        }
        return try Self.validateResponse(payload, expectedID: expectId)
    }

    // MARK: - Bounded HTTP streaming

    /// A request with an id must receive one complete JSON-RPC response for that same id. Treat malformed
    /// HTTP 200 bodies as protocol failures instead of an empty result: otherwise initialize/list can
    /// appear to succeed and silently install a partial tool registry.
    private static func validateResponse(_ payload: Data, expectedID: Int) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: payload)
        } catch {
            throw MCPError.invalidResponse("the body is not valid JSON.")
        }
        guard let object = value as? [String: Any] else {
            throw MCPError.invalidResponse("the top-level value is not an object.")
        }
        guard object["jsonrpc"] as? String == "2.0" else {
            throw MCPError.invalidResponse("jsonrpc must equal \"2.0\".")
        }
        guard let responseID = object["id"] as? Int, responseID == expectedID else {
            throw MCPError.invalidResponse("response id does not match request id \(expectedID).")
        }

        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            throw MCPError.invalidResponse("exactly one of result or error is required.")
        }
        if hasError {
            guard let error = object["error"] as? [String: Any],
                  error["code"] as? Int != nil,
                  error["message"] as? String != nil else {
                throw MCPError.invalidResponse("error must contain an integer code and string message.")
            }
        }
        return object
    }

    private struct WireResponse: Sendable {
        let statusCode: Int
        let sessionId: String?
        /// For JSON this is the response body. For SSE it is only the first complete JSON-RPC event whose
        /// id matches the request; the stream is abandoned immediately after that event.
        let payload: Data?
    }

    private static let maxResponseBytes = 8 * 1_024 * 1_024

    /// Race the transport against an overall deadline. URLRequest's timeout is also set above for normal
    /// URLSession behavior, while this deadline covers active-but-never-answering SSE streams. Cancelling
    /// the caller cancels both children and URLSession's AsyncBytes task.
    private func perform(_ request: URLRequest, expectId: Int?) async throws -> WireResponse {
        let session = self.session
        let timeout = requestTimeout
        let timeoutNanos = UInt64(timeout * 1_000_000_000)
        do {
            return try await withThrowingTaskGroup(of: WireResponse.self) { group in
                group.addTask {
                    try await Self.readResponse(session: session, request: request, expectId: expectId)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    try Task.checkCancellation()
                    throw MCPError.timedOut(timeout)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            // URLSession reports NSURLErrorCancelled for a cancelled AsyncBytes task. Preserve user
            // cancellation as CancellationError so callers do not present it as an MCP/tool failure.
            throw CancellationError()
        }
    }

    private static func readResponse(session: URLSession, request: URLRequest,
                                     expectId: Int?) async throws -> WireResponse {
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            return WireResponse(statusCode: 0, sessionId: nil, payload: nil)
        }
        let status = http.statusCode
        let sessionId = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        guard (200...299).contains(status) else {
            // The status is the useful failure. Do not wait for a server to finish an error stream.
            return WireResponse(statusCode: status, sessionId: sessionId, payload: nil)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if let expectId, contentType.hasPrefix("text/event-stream") {
            let payload = try await firstMatchingSSEPayload(bytes, id: expectId)
            return WireResponse(statusCode: status, sessionId: sessionId, payload: payload)
        }

        var data = Data()
        data.reserveCapacity(min(http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 0,
                                 maxResponseBytes))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maxResponseBytes else { throw MCPError.responseTooLarge }
            data.append(byte)
        }
        return WireResponse(statusCode: status, sessionId: sessionId,
                            payload: data.isEmpty ? nil : data)
    }

    /// Read complete SSE events one line at a time and stop at the first id-matching JSON-RPC response.
    /// Unlike `data(for:)`, this does not wait for a standards-compliant long-lived SSE connection to close.
    private static func firstMatchingSSEPayload(_ bytes: URLSession.AsyncBytes,
                                                id: Int) async throws -> Data? {
        var dataLines: [String] = []
        var lineBytes = Data()
        var pendingCR = false
        var receivedBytes = 0

        func flush() -> Data? {
            defer { dataLines.removeAll(keepingCapacity: true) }
            let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? Int) == id else { return nil }
            return data
        }

        func processLine() -> Data? {
            defer { lineBytes.removeAll(keepingCapacity: true) }
            let line = String(decoding: lineBytes, as: UTF8.self)
            if line.isEmpty {
                return flush()
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
            // event:/id:/retry:/comment lines are deliberately ignored.
            return nil
        }

        // Parse line endings ourselves instead of relying on AsyncBytes.lines. Besides accepting all SSE
        // terminators (LF, CRLF, and bare CR), this preserves empty lines — the event boundary that lets us
        // return before a long-lived connection closes.
        for try await byte in bytes {
            try Task.checkCancellation()
            receivedBytes += 1
            guard receivedBytes <= maxResponseBytes else { throw MCPError.responseTooLarge }

            if pendingCR {
                pendingCR = false
                if let match = processLine() { return match }
                if byte == 0x0A { continue } // CRLF is one terminator.
            }

            switch byte {
            case 0x0D: pendingCR = true
            case 0x0A:
                if let match = processLine() { return match }
            default: lineBytes.append(byte)
            }
        }
        if pendingCR, let match = processLine() { return match }
        if !lineBytes.isEmpty, let match = processLine() { return match }
        return flush()
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

/// Refuses every HTTP redirect for `MCPClient`.
///
/// The MCP request carries the configured server's bearer token. URLSession's default behavior follows a
/// 3xx by replaying the request — `Authorization` header and all — at the host named in `Location`, so a
/// compromised or hostile MCP endpoint could hand the user's credential to a third party with a one-line
/// response. Returning `nil` here stops the redirect; the 3xx status reaches `readResponse`, fails its
/// `200...299` guard, and surfaces as `MCPError.http`. A configured endpoint that genuinely moved should
/// be re-entered in Settings, not followed silently while holding a token.
final class MCPRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
