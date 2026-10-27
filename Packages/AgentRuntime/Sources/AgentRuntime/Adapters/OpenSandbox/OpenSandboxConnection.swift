// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public enum OpenSandboxError: Error, Sendable, LocalizedError {
    case invalidConfiguration, unavailable, responseTooLarge, invalidResponse, identityMismatch, staleState
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Use an HTTPS execution endpoint, or HTTP on localhost for Simulator development."
        case .unavailable: "The configured execution environment is unavailable or disabled."
        case .responseTooLarge: "The execution environment response exceeds its byte limit."
        case .invalidResponse: "The execution environment returned an invalid response."
        case .identityMismatch: "The execution environment identity or request binding changed."
        case .staleState: "The execution state changed; refresh before issuing the command."
        case .http(let status): "The execution environment returned HTTP \(status)."
        }
    }
}

/// Public, non-secret configuration captured only after an explicit connection check.
public struct OpenSandboxConnection: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let endpoint: URL
    public let image: String
    public let capabilities: [WorkflowDeliveryCapability]
    public let allowedHosts: [String]
    public let backendVersion: String

    public init(id: UUID, endpoint: URL, image: String, capabilities: [WorkflowDeliveryCapability],
                allowedHosts: [String] = [], backendVersion: String = "1.1.1") throws {
        let endpoint = try Self.validatedEndpoint(endpoint.absoluteString)
        func boundedText(_ value: String, _ maximum: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= maximum
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard boundedText(image, 512), boundedText(backendVersion, 128), !capabilities.contains(.publication),
              allowedHosts.count <= 16, allowedHosts.allSatisfy({ host in
                  guard boundedText(host, 253) else { return false }
                  return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                          && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                              || (97...122).contains($0) || $0 == 45 }
                  }
              }) else { throw OpenSandboxError.invalidConfiguration }
        self.id = id; self.endpoint = endpoint; self.image = image
        self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
        self.allowedHosts = Array(Set(allowedHosts)).sorted(); self.backendVersion = backendVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), endpoint: values.decode(URL.self, forKey: .endpoint),
            image: values.decode(String.self, forKey: .image), capabilities: values.decode([WorkflowDeliveryCapability].self, forKey: .capabilities),
            allowedHosts: values.decode([String].self, forKey: .allowedHosts), backendVersion: values.decode(String.self, forKey: .backendVersion))
    }
    private enum CodingKeys: String, CodingKey { case id, endpoint, image, capabilities, allowedHosts, backendVersion }

    public static func validatedEndpoint(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              text.utf8.count <= 2_048 else { throw OpenSandboxError.invalidConfiguration }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw OpenSandboxError.invalidConfiguration }
        return url
    }

    public var fingerprint: StableDigest {
        StableDigest.fingerprint(domain: "opensandbox-connection.v1", components: [
            Data(id.uuidString.utf8), Data(endpoint.absoluteString.utf8), Data(image.utf8),
            Data(capabilities.map(\.rawValue).sorted().joined(separator: ",").utf8),
            Data(allowedHosts.sorted().joined(separator: ",").utf8), Data(backendVersion.utf8)])
    }
    public var destination: ExternalDestination {
        try! ExternalDestination(kind: .sandboxProvider, normalizedIdentity: "opensandbox:" + fingerprint.rawValue)
    }
    /// OpenSandbox's egress policy scopes DNS targets, not HTTP methods or URL paths.
    public var networkDestinations: [ExternalDestination] {
        allowedHosts.map { try! ExternalDestination(kind: .networkEndpoint, normalizedIdentity: "sandbox-egress:" + $0) }
    }
    public static let dataCategory = try! AgentDataCategory(rawValue: "sandbox.workspace")
}

private final class OpenSandboxRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class OpenSandboxHTTPClient: @unchecked Sendable {
    public let connection: OpenSandboxConnection
    private let key: @Sendable () -> String?
    private let session: URLSession

    public init(connection: OpenSandboxConnection, apiKey: @escaping @Sendable () -> String?,
                sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection; key = apiKey
        sessionConfiguration.urlCache = nil; sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: sessionConfiguration, delegate: OpenSandboxRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public static func connect(endpoint: String, apiKey: String) async throws -> OpenSandboxConnection {
        let url = try OpenSandboxConnection.validatedEndpoint(endpoint)
        let temporary = try OpenSandboxConnection(id: UUID(), endpoint: url, image: "discovery", capabilities: [])
        let client = OpenSandboxHTTPClient(connection: temporary, apiKey: { apiKey })
        let data = try await client.request("GET", path: "v1/capabilities", discover: true)
        struct Response: Decodable {
            let protocolVersion: Int; let serverID: UUID; let backend: String; let backendVersion: String
            let image: String; let features: [WorkflowDeliveryCapability]; let allowedHosts: [String]
        }
        let value = try JSONDecoder().decode(Response.self, from: data)
        guard value.protocolVersion == 1, value.backend == "OpenSandbox" else { throw OpenSandboxError.invalidResponse }
        return try OpenSandboxConnection(id: value.serverID, endpoint: url, image: value.image,
            capabilities: value.features, allowedHosts: value.allowedHosts, backendVersion: value.backendVersion)
    }

    func request(_ method: String, path: String, body: Data? = nil, discover: Bool = false,
                 maximumResponseBytes: UInt64 = 1_048_576,
                 onResponseBytes: (@Sendable (UInt64) async throws -> Void)? = nil) async throws -> Data {
        guard let secret = key(), !secret.isEmpty, secret.utf8.count <= 4_096,
              secret.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw OpenSandboxError.unavailable }
        var request = URLRequest(url: connection.endpoint.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !discover { request.setValue(connection.id.uuidString.lowercased(), forHTTPHeaderField: "X-MobileLLM-Server-ID") }
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw OpenSandboxError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw OpenSandboxError.http(response.statusCode) }
        let limit = min(maximumResponseBytes, 1_048_576)
        guard response.expectedContentLength < 0 || UInt64(response.expectedContentLength) <= limit else { throw OpenSandboxError.responseTooLarge }
        var data = Data()
        var chunk = Data()
        for try await byte in stream {
            guard UInt64(data.count + chunk.count) < limit else { throw OpenSandboxError.responseTooLarge }
            chunk.append(byte)
            if chunk.count == 8_192 {
                try await onResponseBytes?(UInt64(chunk.count))
                data.append(chunk); chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try await onResponseBytes?(UInt64(chunk.count)); data.append(chunk) }
        return data
    }
}

struct OpenSandboxJob: Codable, Sendable {
    let operationID: UUID
    let workspaceID: UUID
    let state: String
    let version: UInt64
    let acceptedAtMS: UInt64
    let startedAtMS: UInt64?
    let finishedAtMS: UInt64?
    let submitted: Bool
    let error: String?
    let output: JSONValue?
}
