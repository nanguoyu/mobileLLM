// SPDX-License-Identifier: MIT

import Foundation

/// The community Skill Gallery's fetch layer: it reads the repo's **Discussions → Skills** board over the
/// GitHub GraphQL API and turns each `[Skill] …` post into a `GalleryItem` the UI can list and install.
///
/// Deliberately UNAUTHENTICATED — no token is bundled, so the request rides GitHub's 60-req/hour anonymous
/// budget. That budget (and GitHub's sign-in gate) is surfaced honestly rather than hidden: a 401/403/429
/// becomes a clear `GalleryError` the view shows with a Retry and an "open on GitHub" escape hatch.
///
/// The two impure pieces are one thin method (`fetch(session:)`, exercised end-to-end via a `URLProtocol`
/// stub like `SkillIO.fetchFirstParseable`) around a body of PURE, unit-tested transforms: GraphQL JSON →
/// `[GalleryItem]`, fenced-block extraction, and title cleaning. Parsing reuses `SkillIO.parse` verbatim, so
/// a gallery install and a manual `Import SKILL.md` produce byte-identical skills.
enum SkillGallery {

    /// One skill post from the board, parsed into what the gallery UI needs. A post whose body carries no
    /// parseable SKILL.md still becomes an item (so it can be listed + opened on GitHub) with `parsed == nil`
    /// — `isInstallable` is false and the detail sheet offers only "Open on GitHub".
    struct GalleryItem: Identifiable, Equatable {
        /// The discussion number — stable across edits, so it's the list identity.
        var number: Int
        /// Display name: the post title with a leading `[Skill]` tag and any trailing emoji peeled off.
        var title: String
        /// A single glyph for the row + a sensible default emoji at install time. Taken from the title's
        /// trailing emoji when present, else a neutral package.
        var emoji: String
        /// The post author's GitHub login (`"unknown"` for a deleted/ghost author).
        var author: String
        /// The discussion permalink — the "Open on GitHub" destination.
        var url: URL
        /// Community upvotes on the post.
        var upvotes: Int
        /// The SKILL.md parsed out of the post body, or nil when the body has no parseable one.
        var parsed: SkillIO.ParsedSkill?
        /// The raw markdown lifted from the first ```` ```markdown ```` fence (nil when there was none) — kept
        /// so a non-installable post can still show what it contained.
        var rawMarkdown: String?

        var id: Int { number }

        /// True when the post yielded a parseable SKILL.md, so it can be installed in-app.
        var isInstallable: Bool { parsed != nil }
    }

    // MARK: - Errors

    /// Failure modes worth telling the user apart. Every case carries a clear, honest message; the gallery
    /// view renders `errorDescription` beside a Retry and an "open on GitHub" link, so any of these is a soft
    /// landing rather than a dead end.
    enum GalleryError: Error, LocalizedError, Equatable {
        /// GitHub's anonymous request budget (60/hour) was spent, or a GraphQL `RATE_LIMITED` came back.
        case rateLimited
        /// GitHub declined anonymous access (401) — sign-in gated at their end, nothing we can retry into.
        case unauthorized
        /// A non-2xx HTTP status we don't handle specially.
        case http(Int)
        /// The transport failed (offline, DNS, timeout).
        case network(String)
        /// A 2xx body that didn't decode as the expected GraphQL shape.
        case malformedResponse
        /// GraphQL answered 200 with a non-empty `errors` array — surface its first message.
        case graphQL(String)

        var errorDescription: String? {
            switch self {
            case .rateLimited:
                return "Reached GitHub's limit for anonymous browsing (60 requests an hour). "
                     + "Wait a little and try again, or open the board on GitHub."
            case .unauthorized:
                return "GitHub isn't allowing anonymous access to the board right now. "
                     + "You can still open it on GitHub."
            case .http(let code):
                return "GitHub returned an unexpected error (code \(code)). Please try again."
            case .network:
                return "Couldn't reach GitHub. Check your connection and try again."
            case .malformedResponse:
                return "GitHub's response couldn't be read. Please try again."
            case .graphQL(let message):
                return message
            }
        }
    }

    // MARK: - Endpoint

    /// The Skills board's public Atom feed. This is the ONLY anonymously-readable window onto Discussions:
    /// GitHub's GraphQL and REST-search APIs BOTH require a token (verified — anonymous GraphQL returns 403
    /// "rate limit exceeded" outright, not a 60/hr budget), so an on-device app with no login must read the
    /// feed. It carries each post's title, HTML content (the SKILL.md fence survives), author, and permalink.
    private static let feedURL = URL(string: "https://github.com/nanguoyu/mobileLLM/discussions/categories/skills.atom")!

    /// The Discussions → Skills board, for the "open on GitHub" / contribute links.
    static let boardURL = URL(string: "https://github.com/nanguoyu/mobileLLM/discussions/categories/skills")!

    /// A neutral glyph for a post whose title carries no emoji of its own.
    private static let defaultEmoji = "📦"

    // MARK: - Fetch (network → items)

    /// Fetch the board's Atom feed and map it to gallery items. The `session` is injectable (defaults to
    /// `.shared`) so the whole path — request, status gate, XML decode, parse — runs offline under a
    /// `URLProtocol` stub in tests. Throws a `GalleryError` the view can present verbatim. The feed carries
    /// no upvote count, so `upvotes` is 0 (the row simply omits it) — the honest cost of the only anonymous
    /// path.
    static func fetch(session: URLSession = .shared) async throws -> [GalleryItem] {
        var request = URLRequest(url: feedURL)
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent; identify the app rather than a library default.
        request.setValue("mobileLLM-SkillGallery", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GalleryError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299:  break
            case 401:        throw GalleryError.unauthorized
            case 403, 429:   throw GalleryError.rateLimited
            default:         throw GalleryError.http(http.statusCode)
            }
        }
        return try items(fromFeed: data)
    }

    // MARK: - Pure transforms (unit-tested)

    /// Decode an Atom feed body into gallery items, newest first (the feed's own order). Pure — no network —
    /// so a canned XML fixture drives the full mapping (HTML-unescape → fence extraction → SKILL.md parse →
    /// title cleaning). Throws `.malformedResponse` when the bytes aren't parseable XML.
    static func items(fromFeed data: Data) throws -> [GalleryItem] {
        let parser = AtomFeedParser()
        guard let entries = parser.parse(data) else { throw GalleryError.malformedResponse }
        return entries.map(item(from:))
    }

    private static func item(from entry: AtomEntry) -> GalleryItem {
        let (title, glyph) = titleAndGlyph(entry.title)
        // GitHub's Atom <content> is RENDERED HTML, not markdown source: a ```markdown fence becomes a
        // <div class="highlight" data-snippet-clipboard-copy-content="…the raw block…">. That copy
        // attribute holds the exact code-block source (what the "copy" button yields), so read it first —
        // it's the reliable path on the live feed. Fall back to a literal markdown fence for the manual/raw
        // cases (a pasted body, a plain-markdown source) that the parse tests and importer also share.
        let raw = clipboardBlock(in: entry.content) ?? extractSkillMarkdown(from: unescapeHTML(entry.content))
        let parsed = raw.flatMap { SkillIO.parse(markdown: $0) }
        return GalleryItem(
            number: entry.number,
            title: title.isEmpty ? entry.title : title,
            emoji: glyph ?? defaultEmoji,
            author: entry.author.isEmpty ? "unknown" : entry.author,
            url: URL(string: entry.url) ?? boardURL,
            upvotes: 0,   // the Atom feed doesn't carry upvotes
            parsed: parsed,
            rawMarkdown: raw)
    }

    /// Split a discussion title into its display name and an optional trailing emoji glyph. Peels a leading
    /// `[Skill]` tag (case-insensitive, any inner spacing) and any run of trailing emoji + separators —
    /// `"[Skill] Daily Briefing ☀️"` → `("Daily Briefing", "☀️")`, `"[Skill] Translator"` → `("Translator", nil)`.
    /// The glyph is the left-most of a trailing emoji run, which reads as the post's chosen icon.
    static func titleAndGlyph(_ raw: String) -> (title: String, glyph: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag = s.range(of: #"^\[\s*skill\s*\]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[tag.upperBound...])
        }
        var glyph: String?
        loop: while let last = s.last {
            if isEmoji(last) {
                glyph = String(last)   // overwrite so the final value is the run's left-most emoji
                s.removeLast()
            } else if last.isWhitespace || "·—-–:•".contains(last) {
                s.removeLast()
            } else {
                break loop
            }
        }
        return (s.trimmingCharacters(in: .whitespacesAndNewlines), glyph)
    }

    /// Just the cleaned display name (drops the glyph). The title-cleaning entry point the tests pin.
    static func cleanTitle(_ raw: String) -> String { titleAndGlyph(raw).title }

    /// Lift the raw source of the first code block out of GitHub's RENDERED Atom HTML, via the
    /// `data-snippet-clipboard-copy-content="…"` attribute GitHub attaches to every highlighted block
    /// (its value is the block's exact source — the "copy" button's payload). Returns nil when there's no
    /// such block, so the caller falls back to the literal-fence path. The attribute value is HTML-escaped,
    /// so unescape it before handing it to the SKILL.md parser.
    static func clipboardBlock(in html: String) -> String? {
        let marker = "data-snippet-clipboard-copy-content=\""
        guard let start = html.range(of: marker) else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.range(of: "\"") else { return nil }
        let escaped = String(rest[..<end.lowerBound])
        let source = unescapeHTML(escaped)
        return source.contains("name:") ? source : nil   // must look like a SKILL.md, not an arbitrary snippet
    }

    /// Lift the SKILL.md out of a discussion body: the FIRST ```` ```markdown ```` fenced block's contents.
    /// GitHub's discussion form renders the SKILL.md field inside exactly such a block (`render: markdown`),
    /// so this reliably targets it and skips the plain-text fields (summary, dropdowns) around it. Fence-length
    /// aware, so a SKILL.md that itself contains a shorter ```` ``` ```` code sample doesn't cut the block
    /// short. Returns nil when the body has no markdown fence (e.g. a link-only post).
    static func extractSkillMarkdown(from body: String) -> String? {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            if let fence = openingMarkdownFence(lines[i]) {
                var collected: [String] = []
                var j = i + 1
                while j < lines.count {
                    if isClosingFence(lines[j], atLeast: fence) {
                        return collected.joined(separator: "\n")
                    }
                    collected.append(lines[j])
                    j += 1
                }
                // Unterminated fence — take the rest of the body rather than dropping the post.
                return collected.joined(separator: "\n")
            }
            i += 1
        }
        return nil
    }

    /// The backtick count of a line that opens a ```` ```markdown ```` fence (info string `markdown`/`md`,
    /// case-insensitive), or nil if the line isn't such a fence.
    private static func openingMarkdownFence(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let ticks = trimmed.prefix { $0 == "`" }.count
        let info = trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces).lowercased()
        guard info == "markdown" || info == "md" else { return nil }
        return ticks
    }

    /// Whether `line` is a closing fence for an opener of `atLeast` backticks — only backticks, and at least
    /// as many as the opener (CommonMark's rule; lets a nested shorter fence pass through).
    private static func isClosingFence(_ line: String, atLeast n: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "`" }) else { return false }
        return trimmed.count >= n
    }

    /// Whether a character is an emoji glyph. Any scalar with emoji presentation, or an `isEmoji` symbol
    /// above the ASCII/typographic range — so `☀️`, `☀`, and `🎉` count while `#`, `9`, `©`, and `™` don't.
    private static func isEmoji(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value >= 0x203C)
        }
    }

    // MARK: - HTML entity unescape

    /// Unescape the handful of XML/HTML entities the Atom `<content>` uses (its markdown is escaped), so the
    /// SKILL.md fence — its backticks, `<`/`>`, `&` — reads correctly. `&amp;` is decoded LAST so a
    /// double-escaped `&amp;lt;` resolves in one pass; numeric entities cover anything else.
    static func unescapeHTML(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                               ("&#x27;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        out = decodeNumericEntities(out)
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        guard let re = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else { return s }
        var result = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let digits = Range(m.range(at: 1), in: s) else { continue }
            let token = s[digits]
            let scalarValue = token.hasPrefix("x") || token.hasPrefix("X")
                ? UInt32(token.dropFirst(), radix: 16) : UInt32(token, radix: 10)
            if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                result.replaceSubrange(whole, with: String(scalar))
            }
        }
        return result
    }
}

/// One entry lifted from the Atom feed — exactly what a `GalleryItem` needs.
struct AtomEntry: Equatable {
    var number: Int
    var title: String
    var url: String
    var author: String
    var content: String   // HTML-escaped markdown (the post body)
}

/// A tiny Atom-feed reader over `XMLParser`, tuned to GitHub's discussion feed: one `AtomEntry` per
/// `<entry>`, taking its `<title>`, the alternate `<link href>`, `<author><name>`, `<content>`, and the
/// discussion number off the `<id>` (`tag:github.com,…/discussions/<n>`). Namespace-tolerant. Returns nil
/// only when the bytes aren't XML at all.
final class AtomFeedParser: NSObject, XMLParserDelegate {
    private var entries: [AtomEntry] = []
    private var inEntry = false
    private var inAuthor = false
    private var current = AtomEntry(number: 0, title: "", url: "", author: "", content: "")
    private var text = ""
    private var failed = false

    func parse(_ data: Data) -> [AtomEntry]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), !failed else { return nil }
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        let name = local(element)
        switch name {
        case "entry":
            inEntry = true
            current = AtomEntry(number: 0, title: "", url: "", author: "", content: "")
        case "author": inAuthor = true
        case "link" where inEntry:
            // The alternate (or first) link href is the discussion permalink.
            if attrs["rel"] == "alternate" || (current.url.isEmpty && attrs["href"] != nil) {
                current.url = attrs["href"] ?? current.url
            }
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = local(element)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "entry":
            // The permalink carries the real discussion number (…/discussions/12) — prefer it over the
            // id's internal digits so the row identity matches what the board shows.
            if let n = current.url.split(separator: "/").last.flatMap({ Int($0) }) { current.number = n }
            entries.append(current)
            inEntry = false
        case "author": inAuthor = false
        case "title" where inEntry: current.title = value
        case "content" where inEntry: current.content = text   // keep whitespace — it's markdown
        case "name" where inAuthor && inEntry: current.author = value
        case "id" where inEntry:
            // GitHub's entry id is `tag:github.com,2008:<internal-id>` — NOT a path with the discussion
            // number. Keep its trailing digits as the identity fallback; `number` prefers the permalink
            // below (the number a user actually sees). Getting this wrong made every item id 0, which
            // collapsed the whole list into repeats of the first row under `ForEach`.
            if let digits = value.split(separator: ":").last.flatMap({ Int($0) }) { current.number = digits }
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }

    /// The element name without any namespace prefix.
    private func local(_ element: String) -> String {
        element.split(separator: ":").last.map(String.init) ?? element
    }
}

// MARK: - Install detection (name-based, v1)

extension SkillGallery.GalleryItem {

    /// The name this item would be created under on install — the SKILL.md's own `name`. Nil when the post
    /// carries no parseable SKILL.md (there's nothing to install).
    var installName: String? { parsed?.name }

    /// Whether a skill with this item's name already lives in `store`. Name-based, case- and
    /// whitespace-insensitive: provenance isn't tracked yet, so a matching name reads as "already installed"
    /// (good enough for v1, and it keeps a re-import from silently duplicating a skill in the list).
    @MainActor
    func isInstalled(in store: SkillStore) -> Bool {
        guard let name = installName else { return false }
        let target = SkillGallery.normalizeName(name)
        return store.skills.contains { SkillGallery.normalizeName($0.name) == target }
    }
}

extension SkillGallery {
    /// Fold a skill name to its comparison key for install detection.
    static func normalizeName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
