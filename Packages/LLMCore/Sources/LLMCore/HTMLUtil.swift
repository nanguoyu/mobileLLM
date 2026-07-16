// SPDX-License-Identifier: MIT

import Foundation

/// Small, dependency-free HTML text helpers shared by the web tools (`web_search`, `fetch_webpage`).
///
/// These are deliberately regex/string-scanning heuristics, NOT a real DOM parser — we ship no HTML
/// parsing dependency, and SERP / page markup is messy and changes without notice. Every helper is a pure
/// function so the tools' parsers can be unit-tested against canned fixtures.
enum HTMLUtil {

    // MARK: Entity decoding

    /// Decode the handful of HTML entities that actually show up in titles/snippets/body text, plus any
    /// numeric (`&#8217;` / `&#x2019;`) reference. Unknown entities are left untouched.
    static func unescape(_ s: String) -> String {
        var r = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in named { r = r.replacingOccurrences(of: k, with: v) }
        return replaceNumericEntities(r)
    }

    private static func replaceNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(after: i)
            if s[i] == "&", next < s.endIndex, s[next] == "#",
               let semi = s[i...].firstIndex(of: ";") {
                let inner = s[s.index(i, offsetBy: 2)..<semi]
                let code: UInt32? = (inner.first == "x" || inner.first == "X")
                    ? UInt32(inner.dropFirst(), radix: 16)
                    : UInt32(inner, radix: 10)
                if let code, let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                    i = s.index(after: semi)
                    continue
                }
            }
            result.append(s[i]); i = next
        }
        return result
    }

    // MARK: Tag stripping

    /// Strip all tags and collapse the remaining text to a single whitespace-normalized LINE — for inline
    /// snippets/titles where paragraph structure doesn't matter.
    static func inlineText(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return unescape(noTags)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }

    // MARK: Regex convenience (bounded patterns only — inputs are size-capped by the callers)

    static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// All matches of `pattern`, each as its `groups` capture-group strings (empty string for an
    /// unmatched optional group).
    static func allGroups(_ pattern: String, in s: String, groups: Int) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: range).map { m in
            (1...groups).map { i -> String in
                guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return "" }
                return String(s[r])
            }
        }
    }

    /// Split `s` into the chunks that each begin at an occurrence of `marker` (each chunk runs up to the
    /// next marker). Used to carve a results page into per-result blocks without a fragile "outer element"
    /// regex.
    static func segments(_ s: String, startingAt marker: String) -> [Substring] {
        var starts: [String.Index] = []
        var from = s.startIndex
        while let r = s.range(of: marker, range: from..<s.endIndex) {
            starts.append(r.lowerBound)
            from = r.upperBound
        }
        return starts.enumerated().map { i, start in
            s[start..<(i + 1 < starts.count ? starts[i + 1] : s.endIndex)]
        }
    }
}
