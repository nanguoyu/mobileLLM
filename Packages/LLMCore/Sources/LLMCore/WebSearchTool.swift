// SPDX-License-Identifier: MIT

import Foundation

/// A network-backed knowledge tool: looks a query up on Wikipedia (zh for Chinese queries, en otherwise)
/// and returns the article summary. Wikipedia is free, key-less, and reliable — a solid stand-in for
/// general web search without shipping an API key or a scraper. Unlike the calculator/clock this reaches
/// the network, so it's grouped separately and the tool description says so.
///
/// The URL building + response parsing are pure + unit-tested; only `execute` touches the network.
public struct WebSearchTool: Tool {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public var schema: ToolSchema {
        ToolSchema(name: "web_search",
                   description: "Look up current facts on Wikipedia — people, places, definitions, events, "
                              + "history. Returns an article summary.",
                   parameters: [ToolParam(name: "query", kind: .string, description: "What to look up")])
    }

    public func execute(argumentsJSON: String) async -> String {
        guard let q = ToolCall(name: "web_search", argumentsJSON: argumentsJSON).arg("query"),
              !q.trimmingCharacters(in: .whitespaces).isEmpty else { return "Error: missing 'query'." }
        let lang = Self.lang(for: q)
        do {
            guard let title = try await topTitle(q, lang: lang) else {
                return "No Wikipedia article found for \"\(q)\"."
            }
            let summary = try await summary(title, lang: lang)
            return summary.isEmpty ? "Found \"\(title)\" but it has no summary." : "\(title): \(summary)"
        } catch {
            return "Search failed — couldn't reach Wikipedia."
        }
    }

    // MARK: - Network steps

    private func topTitle(_ query: String, lang: String) async throws -> String? {
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "https://\(lang).wikipedia.org/w/api.php?action=query&list=search&srsearch=\(enc)"
                + "&srlimit=1&format=json&origin=*"
        let data = try await get(url)
        return Self.parseTopTitle(data)
    }

    private func summary(_ title: String, lang: String) async throws -> String {
        let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        let url = "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(enc)"
        let data = try await get(url)
        return Self.parseSummary(data)
    }

    private func get(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw ToolNetError.badURL }
        var req = URLRequest(url: u); req.setValue("mobileLLM/1.0 (on-device chat)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ToolNetError.badResponse }
        return data
    }

    // MARK: - Pure helpers (unit-tested)

    enum ToolNetError: Error { case badURL, badResponse }

    /// zh.wikipedia for queries containing CJK, en.wikipedia otherwise.
    static func lang(for query: String) -> String {
        let hasCJK = query.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        return hasCJK ? "zh" : "en"
    }

    /// Pull the first result title out of the MediaWiki search JSON.
    static func parseTopTitle(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let search = query["search"] as? [[String: Any]],
              let first = search.first, let title = first["title"] as? String else { return nil }
        return title
    }

    /// Pull the plain-text `extract` out of the REST summary JSON.
    static func parseSummary(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extract = root["extract"] as? String else { return "" }
        return extract.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
