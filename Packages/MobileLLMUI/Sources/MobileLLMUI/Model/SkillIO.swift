// SPDX-License-Identifier: MIT

import Foundation

/// SKILL.md interop — the community skill format Google's AI Edge Gallery shares (frontmatter with
/// `name` / `description` / optional `metadata`, markdown body as the instructions), so skills round-trip
/// between the two ecosystems. Two honest limits on this platform, surfaced at import rather than hidden:
/// skills whose instructions invoke the Gallery's `run_js` tool need a JS runtime we don't ship yet, and
/// `require-secret` declarations aren't wired (both flagged; the text still imports for adaptation).
enum SkillIO {

    struct ParsedSkill: Equatable {
        var name: String
        var summary: String
        var instructions: String
        var requiresSecret: Bool
        var secretNote: String?

        /// Gallery skills that call `run_js` (bundled index.html) need the WebView/JS runtime the
        /// Android app ships — detection is textual, over the instruction body.
        var requiresJSRuntime: Bool {
            let lower = instructions.lowercased()
            return lower.contains("run_js") || lower.contains("index.html")
        }
    }

    // MARK: Parse (SKILL.md → skill)

    /// Parse a SKILL.md document. Requires the `---` frontmatter block with at least `name`; the whole
    /// post-frontmatter body becomes the instructions verbatim (Examples/Instructions/Constraints
    /// sections are part of the prompt by design — that's how the Gallery uses them too).
    static func parse(markdown raw: String) -> ParsedSkill? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("---") else { return nil }
        let afterOpen = text.dropFirst(3)
        guard let close = afterOpen.range(of: "\n---") else { return nil }
        let front = String(afterOpen[..<close.lowerBound])
        var body = String(afterOpen[close.upperBound...])
        if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) } else { body = "" }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        var name: String?
        var summary = ""
        var requiresSecret = false
        var secretNote: String?
        for line in front.split(separator: "\n", omittingEmptySubsequences: true) {
            let indented = line.hasPrefix("  ") || line.hasPrefix("\t")
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            switch (indented, key) {
            case (false, "name"): name = value
            case (false, "description"): summary = value
            case (true, "require-secret"): requiresSecret = value.lowercased() == "true"
            case (true, "require-secret-description"): secretNote = value
            default: break   // metadata: header line, unknown keys — tolerated, ignored
            }
        }
        guard let name, !name.isEmpty, !body.isEmpty else { return nil }
        return ParsedSkill(name: name, summary: summary, instructions: body,
                           requiresSecret: requiresSecret, secretNote: secretNote)
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'"))
        else { return s }
        return String(s.dropFirst().dropLast())
    }

    // MARK: Export (skill → SKILL.md)

    /// Serialize one of our skills as a Gallery-compatible SKILL.md (the emoji is ours alone, carried in
    /// a comment-free extra field the Gallery ignores gracefully — frontmatter keys it doesn't know are
    /// skipped, exactly like ours).
    static func export(_ skill: Skill) -> String {
        """
        ---
        name: \(skill.name)
        description: \(skill.summary)
        metadata:
          emoji: \(skill.emoji)
        ---

        \(skill.instructions)
        """
    }

    // MARK: URL normalization

    /// The URLs worth trying for a pasted location, best first: an explicit .md as-is; a GitHub repo page
    /// mapped to its raw SKILL.md (main branch); any other base gets /SKILL.md appended (the GitHub Pages
    /// webhost layout the Gallery instructs skill authors to use).
    static func candidateURLs(from raw: String) -> [URL] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        if !s.contains("://") { s = "https://" + s }
        guard var url = URL(string: s), let host = url.host else { return [] }

        if url.pathExtension.lowercased() == "md" { return [url] }

        if host == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                let owner = parts[0], repo = parts[1]
                let raw = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/SKILL.md")
                return [raw].compactMap { $0 }
            }
        }

        while url.path.hasSuffix("/") {
            url = URL(string: String(url.absoluteString.dropLast())) ?? url
        }
        return [url.appending(path: "SKILL.md")]
    }

    // MARK: Fetch (URL → skill)

    /// Fetch the first candidate for `raw` that yields a readable SKILL.md, and parse it. Walks
    /// `candidateURLs(from:)` in order, gating each on a 2xx status (a non-HTTP response passes), decoding
    /// UTF-8, and parsing; returns the first success, or nil when none is readable. Extracted from
    /// `SkillImportView.fetch()` so the import networking is exercisable end-to-end via a `URLProtocol`
    /// stub — the `session` is injectable and defaults to `.shared`, so the app's behavior is unchanged.
    static func fetchFirstParseable(from raw: String, session: URLSession = .shared) async -> ParsedSkill? {
        for url in candidateURLs(from: raw) {
            if let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
               let text = String(data: data, encoding: .utf8),
               let parsed = parse(markdown: text) {
                return parsed
            }
        }
        return nil
    }
}
