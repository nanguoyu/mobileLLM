// SPDX-License-Identifier: MIT

import Foundation

public enum DeepSeekWebOperation: String, Sendable {
    case search, fetch

    public var toolName: String { self == .search ? "web_search" : "fetch_webpage" }
    public var argumentName: String { self == .search ? "query" : "url" }
}

public enum DeepSeekWebError: Error, LocalizedError, Equatable {
    case invalidArgument, missingAPIKey, httpStatus(Int), responseTooLarge, invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidArgument: "DeepSeek search needs 1–128 Unicode characters; page reads need a public HTTPS URL of at most 8192 characters without credentials."
        case .missingAPIKey: "The selected DeepSeek service has no API key. Add its key in Online models."
        case .httpStatus(401): "DeepSeek rejected the API key. Check the selected service's key."
        case .httpStatus(402): "The DeepSeek account has insufficient balance."
        case .httpStatus(403): "DeepSeek's security policy rejected this page."
        case .httpStatus(404): "DeepSeek could not retrieve readable content from this page."
        case .httpStatus(429): "DeepSeek's search or page-reading rate limit was reached. Try again later."
        case .httpStatus(let status): "DeepSeek web service returned HTTP \(status)."
        case .responseTooLarge: "DeepSeek's response exceeded the allowed size."
        case .invalidResponse: "DeepSeek returned an invalid web-service response."
        }
    }
}

public struct DeepSeekWebResponse: Sendable {
    public let text: String
    public let requestBytes: UInt64
    public let responseBytes: UInt64
}

/// Official Search/Fetch JSON APIs. Credentials never follow redirects or enter tool arguments.
/// Authentication is supplied only by the authorized caller. No model inference occurs here.
/// API contract: https://api-docs.deepseek.com/guides/search/
public struct DeepSeekWebClient: Sendable {
    public static let maximumResponseBytes = 1_048_576
    private let transport: WebHTTPTransport
    private let pagePolicy: WebURLPolicy

    public init(session: URLSession = .shared) {
        transport = .urlSession(session)
        pagePolicy = WebURLPolicy()
    }

    init(policy: WebURLPolicy, transport: WebHTTPTransport) {
        self.transport = transport
        pagePolicy = policy
    }

    public static func requestBody(operation: DeepSeekWebOperation, argument: String) throws -> Data {
        let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        switch operation {
        case .search:
            guard !value.isEmpty, value.unicodeScalars.count <= 128 else { throw DeepSeekWebError.invalidArgument }
            return try JSONSerialization.data(withJSONObject: ["query": value, "count": 6, "need_content": false], options: [.sortedKeys])
        case .fetch:
            guard value.unicodeScalars.count <= 8192, let url = URL(string: value),
                  url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, !WebURLPolicy.isBlockedHost(host)
            else { throw DeepSeekWebError.invalidArgument }
            return try JSONSerialization.data(withJSONObject: ["url": value], options: [.sortedKeys])
        }
    }

    public func perform(operation: DeepSeekWebOperation, argument: String, apiKey: String,
                        consumeResponseBytes: @Sendable (UInt64) async throws -> Void = { _ in }) async throws -> DeepSeekWebResponse {
        let body = try Self.requestBody(operation: operation, argument: argument)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n") else { throw DeepSeekWebError.missingAPIKey }
        if operation == .fetch, let url = URL(string: argument.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try await pagePolicy.validate(url)
        }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/tools/\(operation.rawValue)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        try await pagePolicy.validate(request.url!)
        // This transport never follows redirects. Every non-200 response is accounted and rejected.
        let response = try await transport.load(request, Self.maximumResponseBytes)
        // Failed HTTP responses still consume the authorized network budget.
        try await consumeResponseBytes(UInt64(response.body.count))
        guard !response.wasTruncated else { throw DeepSeekWebError.responseTooLarge }
        guard response.response.statusCode == 200 else { throw DeepSeekWebError.httpStatus(response.response.statusCode) }
        let text: String
        do {
            switch operation {
            case .search:
                let results = try JSONDecoder().decode(SearchResponse.self, from: response.body).results
                let entries = results.prefix(6).enumerated().compactMap { index, item -> String? in
                    guard let url = URL(string: item.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                          url.host != nil, url.user == nil, url.password == nil else { return nil }
                    let summary = item.summary.isEmpty ? item.snippet : item.summary
                    return "[\(index + 1)] \(item.title.prefix(512))\n\(item.url)\n\(summary.prefix(6000))"
                }
                text = "Retrieval: SEARCH_SUMMARIES_ONLY. No source page was fetched by this call.\n\n"
                    + (entries.isEmpty ? "No web results found for: \(argument)" : entries.joined(separator: "\n\n"))
            case .fetch:
                let page = try JSONDecoder().decode(PageResponse.self, from: response.body)
                guard !page.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeepSeekWebError.invalidResponse }
                text = "Retrieval: FETCHED_PAGE_EXCERPT (up to 20000 characters, not necessarily the full page).\n"
                    + "\(page.title.prefix(512))\nSource: \(argument)\n\n\(page.content.prefix(20000))"
            }
        } catch { throw DeepSeekWebError.invalidResponse }
        return DeepSeekWebResponse(text: text, requestBytes: UInt64(body.count), responseBytes: UInt64(response.body.count))
    }

    private struct SearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable { let title: String; let url: String; let snippet: String; let summary: String }
    }
    private struct PageResponse: Decodable { let title: String; let content: String }
}
