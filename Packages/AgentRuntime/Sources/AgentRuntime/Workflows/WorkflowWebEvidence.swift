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

    static func packet(_ input: [(label: String, observation: WorkflowWebObservation)]) throws -> JSONValue {
        var observations: [JSONValue] = []
        var sources: [String: (host: String, kind: String)] = [:]
        var clipped = false
        for (label, item) in input {
            try Task.checkCancellation()
            guard item.toolID.providerID == "builtin",
                  ["web_search", "fetch_webpage"].contains(item.toolID.name) else { continue }
            guard observations.count < maximumObservations else { clipped = true; break }
            let reading = item.toolID.name == "fetch_webpage"
            let prefix = clippedText(item.text, maximumBytes: 1200)
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
                record["tail"] = .string(clippedText(item.text, maximumBytes: 400, suffix: true))
                record["yearExcerpts"] = .array(try yearExcerpts(item.text).map(JSONValue.string))
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
