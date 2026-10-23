// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// An observation read from an authorized run's durable tool journal, never from model prose.
public struct WorkflowWebObservation: Sendable {
    public let invocationID: String
    public let toolID: AgentToolLogicalID
    public let requestedURL: String?
    public let status: String
    public let text: String

    public init(invocationID: String, toolID: AgentToolLogicalID, requestedURL: String?, status: String, text: String) {
        self.invocationID = invocationID
        self.toolID = toolID
        self.requestedURL = requestedURL
        self.status = status
        self.text = text
    }
}

/// A bounded evidence packet. Source content remains untrusted; retrieval type and success come
/// from the host's records. Failed fetches never become read-page evidence or eligible citations.
enum WorkflowWebEvidence {
    static let maximumObservations = 32

    static func packet(_ input: [(label: String, observation: WorkflowWebObservation)], matching query: String? = nil) throws -> JSONValue {
        guard (query?.utf8.count ?? 0) <= 64 * 1024 else {
            throw WorkflowScriptRuntimeError.invalidArguments("web evidence query exceeds 64 KiB")
        }
        let terms = try query.map(queryTerms) ?? []
        var observations: [JSONValue] = []
        var sources: [String: (host: String, kind: String)] = [:]
        var clipped = false
        for (label, item) in input {
            try Task.checkCancellation()
            guard item.toolID.providerID == "builtin",
                  ["web_search", "fetch_webpage"].contains(item.toolID.name) else { continue }
            guard observations.count < maximumObservations else { clipped = true; break }
            let reading = item.toolID.name == "fetch_webpage"
            let prefix = clippedText(item.text, maximumBytes: terms.isEmpty ? 1200 : 400)
            let shortened = prefix.utf8.count < item.text.utf8.count
            var record: [String: JSONValue] = [
                "child": .string(label), "invocationID": .string(item.invocationID),
                "tool": .string(item.toolID.name), "status": .string(item.status),
                "contentDigest": .string(StableDigest.sha256(Data(item.text.utf8)).rawValue),
                "excerpt": .string(prefix), "excerptTruncated": .bool(shortened),
                "sourceTrust": .string("untrusted web content")
            ]
            if let requestedURL = item.requestedURL { record["requestedURL"] = .string(requestedURL) }
            if shortened {
                record["tail"] = .string(clippedText(item.text, maximumBytes: terms.isEmpty ? 400 : 200, suffix: true))
                if terms.isEmpty { record["yearExcerpts"] = .array(try yearExcerpts(item.text).map(JSONValue.string)) }
            }
            if !terms.isEmpty {
                record["matchingExcerpts"] = .array(try matchingExcerpts(item.text, terms: terms).map(JSONValue.string))
            }
            observations.append(.object(record))
            guard item.status == "completed", !item.text.isEmpty else { continue }
            let urls = reading ? item.requestedURL.map { [$0] } ?? [] : try sourceURLs(in: item.text)
            for raw in urls {
                guard let url = normalizedURL(raw), let host = url.host?.lowercased() else { continue }
                if reading || sources[url.absoluteString] == nil {
                    sources[url.absoluteString] = (host, reading ? "page-excerpt" : "search-summary")
                }
            }
        }
        var bytes = 0
        var sourceRows: [JSONValue] = []
        // Prefer actual page reads when the packet's bounded source list is full.
        let ordered = sources.sorted {
            if $0.value.kind != $1.value.kind { return $0.value.kind == "page-excerpt" }
            return $0.key < $1.key
        }
        for (url, source) in ordered {
            guard sourceRows.count < 128, bytes + url.utf8.count <= 16 * 1024 else { clipped = true; continue }
            bytes += url.utf8.count
            sourceRows.append(.object(["url": .string(url), "host": .string(source.host), "kind": .string(source.kind)]))
        }
        return .object(["observations": .array(observations), "sources": .array(sourceRows), "truncated": .bool(clipped)])
    }

    private static func normalizedURL(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func sourceURLs(in text: String) throws -> [String] {
        let bounded = clippedText(text, maximumBytes: 64 * 1024)
        let pattern = try NSRegularExpression(pattern: #"https?://[^\s<>()\\\[\]"']+"#)
        return pattern.matches(in: bounded, range: NSRange(bounded.startIndex..., in: bounded)).prefix(128).compactMap {
            guard let range = Range($0.range, in: bounded) else { return nil }
            return String(bounded[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;，。；、"))
        }
    }

    private static func yearExcerpts(_ text: String) throws -> [String] {
        let bounded = clippedText(text, maximumBytes: 64 * 1024)
        let pattern = try NSRegularExpression(pattern: #"\b20[0-9]{2}\b"#)
        var byYear: [String: String] = [:]
        for match in pattern.matches(in: bounded, range: NSRange(bounded.startIndex..., in: bounded)) {
            guard let range = Range(match.range, in: bounded) else { continue }
            let year = String(bounded[range])
            guard byYear[year] == nil else { continue }
            let start = bounded.index(range.lowerBound, offsetBy: -35, limitedBy: bounded.startIndex) ?? bounded.startIndex
            let end = bounded.index(range.upperBound, offsetBy: 65, limitedBy: bounded.endIndex) ?? bounded.endIndex
            byYear[year] = clippedText(String(bounded[start..<end]), maximumBytes: 120)
        }
        return byYear.keys.sorted(by: >).prefix(4).compactMap { byYear[$0] }
    }

    private struct QueryTerm { let text: String; let weight: Int }

    /// Literal query terms only. Code/field names receive priority; source data never supplies a
    /// regex or an instruction. All matching is local to already-authorized recorded observations.
    private static func queryTerms(_ query: String) throws -> [QueryTerm] {
        let words = try NSRegularExpression(pattern: #"[\p{L}\p{N}_-]{3,64}"#)
        let code = try NSRegularExpression(pattern: #"`([^`\n]{3,96})`"#)
        let stop: Set<String> = ["the", "and", "with", "from", "this", "that", "for", "are", "not", "https", "http", "www", "com", "org", "api", "true", "false", "return", "using", "must", "should", "which", "have", "into"]
        var terms: [QueryTerm] = []
        var seen: Set<String> = []
        func add(_ text: String, code: Bool) {
            for match in words.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard terms.count < 48, let range = Range(match.range, in: text) else { break }
                let term = String(text[range]).lowercased()
                guard !stop.contains(term), seen.insert(term).inserted else { continue }
                terms.append(QueryTerm(text: term, weight: (code ? 32 : 1) + min(term.count, 16)))
            }
        }
        for match in code.matches(in: query, range: NSRange(query.startIndex..., in: query)).prefix(64) {
            if let range = Range(match.range(at: 1), in: query) { add(String(query[range]), code: true) }
        }
        add(query, code: false)
        return terms
    }

    /// Greedy coverage of distinct query terms selects at most three verbatim line windows.
    /// The 400-byte head + 200-byte tail + 3×480-byte matches fit within the legacy excerpt budget.
    private static func matchingExcerpts(_ text: String, terms: [QueryTerm]) throws -> [String] {
        let bounded = clippedText(text, maximumBytes: 64 * 1024)
        var candidates: [(line: String, hits: Set<Int>)] = []
        for line in bounded.components(separatedBy: .newlines) where !line.isEmpty {
            try Task.checkCancellation()
            let lower = line.lowercased()
            let hits = Set(terms.indices.filter { lower.contains(terms[$0].text) })
            if !hits.isEmpty { candidates.append((line, hits)) }
        }
        var covered: Set<Int> = []
        var result: [String] = []
        for _ in 0..<3 {
            try Task.checkCancellation()
            var best: Int?
            var bestScore = 0
            for (index, candidate) in candidates.enumerated() {
                let score = candidate.hits.subtracting(covered).reduce(0) { $0 + terms[$1].weight }
                if score > bestScore { best = index; bestScore = score }
            }
            guard let best else { break }
            let candidate = candidates.remove(at: best)
            let newHits = candidate.hits.subtracting(covered)
            guard let term = newHits.sorted(by: {
                terms[$0].weight == terms[$1].weight ? $0 < $1 : terms[$0].weight > terms[$1].weight
            }).first,
                  let range = candidate.line.range(of: terms[term].text, options: .caseInsensitive) else { break }
            let start = candidate.line.index(range.lowerBound, offsetBy: -70, limitedBy: candidate.line.startIndex) ?? candidate.line.startIndex
            let excerpt = clippedText(String(candidate.line[start...]), maximumBytes: 480)
            result.append(excerpt)
            // Only terms visible in the actual bounded excerpt count as covered.
            covered.formUnion(terms.indices.filter { excerpt.lowercased().contains(terms[$0].text) })
        }
        return result
    }

    private static func clippedText(_ text: String, maximumBytes: Int, suffix: Bool = false) -> String {
        var bytes = suffix ? Array(text.utf8.suffix(maximumBytes)) : Array(text.utf8.prefix(maximumBytes))
        // UTF-8 slicing may split one scalar. Drop only its incomplete boundary bytes.
        for _ in 0..<4 {
            if let result = String(bytes: bytes, encoding: .utf8) { return result }
            guard !bytes.isEmpty else { break }
            if suffix { bytes.removeFirst() } else { bytes.removeLast() }
        }
        return ""
    }
}
