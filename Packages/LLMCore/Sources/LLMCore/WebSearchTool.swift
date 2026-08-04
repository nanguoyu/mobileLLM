// SPDX-License-Identifier: MIT

import Foundation

/// Which SERP engine to scrape. A `WebSearchTool`'s engine list is a priority order — the first engine
/// that returns any results wins, and a failing/empty engine falls through to the next.
public enum SearchEngine: String, Sendable, Codable, CaseIterable, Hashable {
    case duckduckgo
    case bing
    case brave
}

/// One organic web-search hit.
public struct SearchResult: Sendable, Equatable, Hashable, Codable {
    public let title: String
    public let url: String
    public let snippet: String
    public init(title: String, url: String, snippet: String) {
        self.title = title; self.url = url; self.snippet = snippet
    }
}

/// Real, key-less web search by scraping a search engine's HTML results page (FlowDown's approach — no API
/// key, no JS runtime). It tries each engine in priority order and returns the first non-empty result set,
/// so one engine's outage or markup change simply falls through to the next.
///
/// HONEST CAVEAT: SERP scraping is inherently brittle — engines rewrite their HTML without notice and
/// rate-limit aggressively — so the per-engine parsers below are deliberately heuristic and tolerant, and
/// every failure degrades to a readable string the model can act on (`execute` never throws). The
/// URL-building + HTML parsing are pure functions covered by canned-fixture tests; only `fetch` hits the
/// network.
public struct WebSearchTool: Tool {
    /// Engine priority order, public so Tool V2 adapters can plan the same fallback itinerary.
    public let engines: [SearchEngine]
    private let httpClient: WebHTTPClient
    private let maxResults: Int
    private let maxBytes: Int

    public init(engines: [SearchEngine] = [.duckduckgo, .bing, .brave],
                session: URLSession = .shared, maxResults: Int = 6,
                maxBytes: Int = 2 * 1024 * 1024) {
        self.engines = engines.isEmpty ? [.duckduckgo, .bing, .brave] : engines
        self.httpClient = WebHTTPClient(session: session)
        self.maxResults = max(1, maxResults)
        self.maxBytes = max(1, maxBytes)
    }

    init(engines: [SearchEngine] = [.duckduckgo, .bing, .brave],
         session: URLSession, maxResults: Int = 6, maxBytes: Int = 2 * 1024 * 1024,
         dnsResolver: @escaping WebDNSResolver) {
        self.engines = engines.isEmpty ? [.duckduckgo, .bing, .brave] : engines
        self.httpClient = WebHTTPClient(session: session, resolver: dnsResolver)
        self.maxResults = max(1, maxResults)
        self.maxBytes = max(1, maxBytes)
    }

    public var schema: ToolSchema {
        ToolSchema(name: "web_search",
                   description: "Search the live web and return the top results (title, link, snippet). "
                              + "Use for news, current events, prices, or anything newer than your training "
                              + "data; use `wikipedia` instead for stable encyclopedic facts.",
                   parameters: [ToolParam(name: "query", kind: .string, description: "The search query")])
    }

    public func execute(argumentsJSON: String) async -> String {
        guard let q = ToolCall(name: "web_search", argumentsJSON: argumentsJSON).arg("query"),
              !q.trimmingCharacters(in: .whitespaces).isEmpty else { return "Error: missing 'query'." }
        for engine in engines {
            do {
                let html = try await fetch(engine: engine, query: q)
                let results = Array(Self.parse(engine: engine, html: html).prefix(maxResults))
                if !results.isEmpty { return Self.render(results, query: q) }
            } catch {
                continue   // this engine failed — try the next one
            }
        }
        return "Web search failed: all search engines returned no results or were unreachable."
    }

    // MARK: - Network

    public enum ToolNetError: Error { case badURL, badResponse }

    /// Bounded fetch of ONE engine's results page. Public for Tool V2 adapters that must place the
    /// network call inside an authorized execution boundary (they consume the response bytes through
    /// the boundary control before parsing); the legacy `execute` keeps its tolerant fallback loop.
    public func fetchHTML(query: String, engine: SearchEngine) async throws -> Data {
        guard let url = Self.endpoint(engine: engine, query: query) else { throw ToolNetError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let result = try await httpClient.get(req, maxBytes: maxBytes)
        guard result.response.statusCode == 200 else { throw ToolNetError.badResponse }
        return result.body
    }

    private func fetch(engine: SearchEngine, query: String) async throws -> String {
        guard let url = Self.endpoint(engine: engine, query: query) else { throw ToolNetError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let result = try await httpClient.get(req, maxBytes: maxBytes)
        guard result.response.statusCode == 200 else { throw ToolNetError.badResponse }
        guard let html = String(data: result.body, encoding: .utf8)
                      ?? String(data: result.body, encoding: .isoLatin1) else { throw ToolNetError.badResponse }
        return html
    }

    /// A realistic desktop-Chrome UA — engines serve a stripped/blocked page to obvious bots.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                         + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// Build the results-page URL. DuckDuckGo's `html.duckduckgo.com/html/` is the no-JS HTML endpoint.
    public static func endpoint(engine: SearchEngine, query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch engine {
        case .duckduckgo: return URL(string: "https://html.duckduckgo.com/html/?q=\(q)")
        case .bing:       return URL(string: "https://www.bing.com/search?q=\(q)&count=10")
        case .brave:      return URL(string: "https://search.brave.com/search?q=\(q)")
        }
    }

    // MARK: - Parsing (pure, unit-tested against canned fixtures)

    public static func parse(engine: SearchEngine, html: String) -> [SearchResult] {
        switch engine {
        case .duckduckgo: return parseDuckDuckGo(html)
        case .bing:       return parseBing(html)
        case .brave:      return parseBrave(html)
        }
    }

    /// Parse the DDG HTML endpoint: each result is a `result__a` anchor (title + wrapped href) followed by
    /// a `result__snippet` anchor. Titles and snippets are paired by position.
    static func parseDuckDuckGo(_ html: String) -> [SearchResult] {
        let titles = HTMLUtil.allGroups(
            "<a[^>]+class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>",
            in: html, groups: 2)
        let snippets = HTMLUtil.allGroups(
            "<a[^>]+class=\"[^\"]*result__snippet[^\"]*\"[^>]*>(.*?)</a>",
            in: html, groups: 1)
        var out: [SearchResult] = []
        for (i, t) in titles.enumerated() {
            let title = HTMLUtil.inlineText(t[1])
            guard !title.isEmpty else { continue }
            let snippet = i < snippets.count ? HTMLUtil.inlineText(snippets[i][0]) : ""
            out.append(SearchResult(title: title, url: cleanDuckDuckGoURL(t[0]), snippet: snippet))
        }
        return out
    }

    /// Parse Bing's organic results: each `<li class="b_algo">` block carries the title/link in its `<h2>`
    /// anchor and the snippet in the first `<p>`.
    static func parseBing(_ html: String) -> [SearchResult] {
        var out: [SearchResult] = []
        for block in HTMLUtil.segments(html, startingAt: "<li class=\"b_algo") {
            guard let h2 = HTMLUtil.firstGroup("<h2[^>]*>(.*?)</h2>", in: String(block)),
                  let href = HTMLUtil.firstGroup("<a[^>]+href=\"([^\"]+)\"", in: h2) else { continue }
            let title = HTMLUtil.inlineText(h2)
            guard !title.isEmpty else { continue }
            let snippet = HTMLUtil.firstGroup("<p[^>]*>(.*?)</p>", in: String(block))
                .map(HTMLUtil.inlineText) ?? ""
            out.append(SearchResult(title: title, url: cleanBingURL(href), snippet: snippet))
        }
        return out
    }

    /// Parse Brave's current organic results: each `<div class="result-wrapper">` carries a direct
    /// `<a href>` plus a `title` attribute on its title div and a `generic-snippet` text block. Brave
    /// serves this markup without a redirect wrapper, which keeps URL cleaning trivial.
    static func parseBrave(_ html: String) -> [SearchResult] {
        var out: [SearchResult] = []
        for block in HTMLUtil.segments(html, startingAt: "class=\"result-wrapper") {
            guard let anchor = HTMLUtil.firstGroup("<a[^>]+href=\"([^\"]+)\"", in: String(block)) else {
                continue
            }
            let title = HTMLUtil.firstGroup(
                "class=\"title[^\"]*\"[^>]*title=\"([^\"]+)\"",
                in: String(block)
            ).map(HTMLUtil.unescape) ?? ""
            guard !title.isEmpty else { continue }
            let snippet = HTMLUtil.firstGroup(
                "class=\"generic-snippet[^\"]*\"[^>]*>(.*?)</div>",
                in: String(block)
            ).map(HTMLUtil.inlineText) ?? ""
            out.append(SearchResult(
                title: title,
                url: cleanBraveURL(anchor),
                snippet: snippet
            ))
        }
        return out
    }

    /// Brave links are direct destinations; only make protocol-relative URLs absolute.
    static func cleanBraveURL(_ raw: String) -> String {
        let s = HTMLUtil.unescape(raw)
        return s.hasPrefix("//") ? "https:" + s : s
    }

    /// Unwrap DDG's redirect wrapper (`//duckduckgo.com/l/?uddg=<pct-encoded-target>&rut=…`) back to the
    /// real destination, stripping the tracking params. A direct link is returned as-is.
    static func cleanDuckDuckGoURL(_ raw: String) -> String {
        let s = HTMLUtil.unescape(raw)
        if let r = s.range(of: "uddg=") {
            let enc = String(s[r.upperBound...].prefix { $0 != "&" })
            if let decoded = enc.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        return s.hasPrefix("//") ? "https:" + s : s
    }

    /// Unwrap Bing's `ck/a` click-tracking redirect: the destination is base64url-encoded in the `u=a1…`
    /// param. A direct link is returned as-is.
    static func cleanBingURL(_ raw: String) -> String {
        let s = HTMLUtil.unescape(raw)
        if s.contains("/ck/a"), let r = s.range(of: "u=a1") {
            let enc = String(s[r.upperBound...].prefix { $0 != "&" })
            if let decoded = base64URLDecode(enc), decoded.hasPrefix("http") { return decoded }
        }
        return s.hasPrefix("//") ? "https:" + s : s
    }

    private static func base64URLDecode(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A compact, model-friendly rendering: a numbered list of title / url / snippet.
    public static func render(_ results: [SearchResult], query: String) -> String {
        var lines = ["Web results for \"\(query)\":"]
        for (i, r) in results.enumerated() {
            var entry = "\(i + 1). \(r.title)\n\(r.url)"
            if !r.snippet.isEmpty { entry += "\n\(r.snippet)" }
            lines.append(entry)
        }
        return lines.joined(separator: "\n\n")
    }
}
