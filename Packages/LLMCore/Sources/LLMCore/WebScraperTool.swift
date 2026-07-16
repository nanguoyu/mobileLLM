// SPDX-License-Identifier: MIT

import Foundation

/// Fetch a single web page and hand the model its readable text (FlowDown's web-reader tool). It follows
/// redirects, guards the content type, caps the download, and strips boilerplate (script/style/nav/header/
/// footer/aside/svg/comments) before extracting the article body — so the model gets prose, not markup.
///
/// SSRF HYGIENE: only `http`/`https` are allowed, and obvious private/loopback hosts (localhost, `.local`,
/// 127/10/192.168/172.16-31/169.254) are refused so a model-chosen URL can't be pointed at the device's own
/// network. This is a string-level guard, not a full SSRF defense (it does not resolve DNS, so a public
/// name that resolves to a private IP is not caught) — noted honestly. The parsing is pure + unit-tested;
/// only `execute` touches the network.
public struct WebScraperTool: Tool {
    private let session: URLSession
    private let maxBytes: Int
    private let maxOutputChars: Int

    public init(session: URLSession = .shared, maxBytes: Int = 2 * 1024 * 1024, maxOutputChars: Int = 6000) {
        self.session = session
        self.maxBytes = maxBytes
        self.maxOutputChars = maxOutputChars
    }

    public var schema: ToolSchema {
        ToolSchema(name: "fetch_webpage",
                   description: "Fetch a web page by URL and return its readable text. Use to read an "
                              + "article or page the user linked, or a result returned by web_search.",
                   parameters: [ToolParam(name: "url", kind: .string,
                                          description: "The full http(s) URL of the page to read")])
    }

    public func execute(argumentsJSON: String) async -> String {
        guard let raw = ToolCall(name: "fetch_webpage", argumentsJSON: argumentsJSON).arg("url"),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "Error: missing 'url'." }
        let urlString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return "Error: only http(s) URLs can be fetched."
        }
        guard let host = url.host, !Self.isBlockedHost(host) else {
            return "Error: that host isn't allowed (local/private addresses are blocked)."
        }
        do {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue(WebSearchTool.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,text/plain", forHTTPHeaderField: "Accept")
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return "Error: couldn't fetch the page (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))."
            }
            let mime = (http.mimeType ?? "").lowercased()
            guard mime.isEmpty || mime.hasPrefix("text/html") || mime.hasPrefix("text/plain")
                    || mime.hasPrefix("application/xhtml") else {
                return "Error: that URL isn't a readable web page (content type: \(mime))."
            }
            let capped = data.prefix(maxBytes)
            guard let body = String(data: capped, encoding: .utf8)
                          ?? String(data: capped, encoding: .isoLatin1) else {
                return "Error: couldn't decode the page text."
            }
            let text = mime.hasPrefix("text/plain")
                ? HTMLUtil.unescape(body)   // already plain text — just normalize entities
                : Self.extractReadableText(fromHTML: body)
            let cleaned = Self.collapse(text)
            guard !cleaned.isEmpty else { return "The page loaded but had no readable text." }
            let title = Self.title(ofHTML: body)
            let rendered = Self.truncate(cleaned, to: maxOutputChars)
            return title.map { "\($0)\n\n\(rendered)" } ?? rendered
        } catch {
            return "Error: couldn't reach \(host)."
        }
    }

    // MARK: - Host guard (pure)

    /// Refuse localhost / link-local / RFC-1918 private hosts (string-level SSRF hygiene). A non-IP host
    /// that isn't an obvious local name is allowed.
    static func isBlockedHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" || host == "0.0.0.0" || host.hasPrefix("fe80:") { return true }  // IPv6 loopback / any / link-local
        // IPv4 dotted-quad private / loopback / link-local ranges.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4, !octets.contains(nil) {
            let o = octets.map { $0! }
            if o[0] == 127 || o[0] == 10 { return true }               // loopback / private
            if o[0] == 192 && o[1] == 168 { return true }              // private
            if o[0] == 172 && (16...31).contains(o[1]) { return true } // private
            if o[0] == 169 && o[1] == 254 { return true }              // link-local
        }
        return false
    }

    // MARK: - Readable-text extraction (pure)

    /// Strip boilerplate, prefer the main content region, and turn block structure into line breaks — a
    /// heuristic reader (no DOM), good enough to hand the model prose instead of markup.
    static func extractReadableText(fromHTML html: String) -> String {
        var s = removeComments(html)
        s = removeBlocks(s, tags: ["script", "style", "noscript", "svg", "nav", "header",
                                   "footer", "aside", "form", "iframe", "template", "figure"])
        let region = mainRegion(of: s)
        let withBreaks = insertLineBreaks(region)
        let stripped = withBreaks.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return HTMLUtil.unescape(stripped)
    }

    private static func removeComments(_ s: String) -> String {
        s.replacingOccurrences(of: "<!--.*?-->", with: " ", options: .regularExpression)
    }

    private static func removeBlocks(_ s: String, tags: [String]) -> String {
        var out = s
        for tag in tags {
            out = out.replacingOccurrences(of: "<\(tag)(\\s[^>]*)?>.*?</\(tag)>", with: " ",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// Prefer `<article>`, then `<main>`, then `<body>` — else the whole document. (We stop short of a
    /// full "largest text block" DOM analysis, which would need a real parser.)
    private static func mainRegion(of s: String) -> String {
        for tag in ["article", "main", "body"] {
            if let inner = HTMLUtil.firstGroup("<\(tag)(?:\\s[^>]*)?>(.*)</\(tag)>", in: s) { return inner }
        }
        return s
    }

    /// Put newlines around block-level / heading tags so paragraph and heading breaks survive tag stripping.
    private static func insertLineBreaks(_ s: String) -> String {
        s.replacingOccurrences(
            of: "</?(?:p|div|section|article|h[1-6]|br|li|ul|ol|tr|table|blockquote|pre|hr)(?:\\s[^>]*)?/?>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
    }

    /// The document `<title>`, if any (trimmed) — a useful header for the extracted text.
    static func title(ofHTML html: String) -> String? {
        guard let t = HTMLUtil.firstGroup("<title[^>]*>(.*?)</title>", in: html) else { return nil }
        let clean = HTMLUtil.inlineText(t)
        return clean.isEmpty ? nil : clean
    }

    // MARK: - Whitespace + truncation (pure)

    /// Collapse runs of spaces within a line and runs of blank lines to a single break; trims the result.
    static func collapse(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
        var out: [String] = []
        var lastBlank = false
        for line in lines {
            let blank = line.isEmpty
            if blank && lastBlank { continue }
            out.append(line)
            lastBlank = blank
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cap the output length, appending an honest `[truncated]` marker when we cut.
    static func truncate(_ s: String, to max: Int) -> String {
        guard s.count > max else { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n[truncated]"
    }
}
