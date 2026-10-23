// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Provider-neutral, typed search output. Its source identities are separate from untrusted body
/// strings, so hyperlinks inside a page cannot masquerade as returned search results.
public enum WorkflowSearchEvidence {
    public struct Source: Sendable {
        public let url: String
        public let title: String
        public let summary: String
        public let pageExcerpt: String
        public let truncated: Bool
        public let publicationDate: String?

        public init(url: String, title: String, summary: String, pageExcerpt: String,
                    truncated: Bool, publicationDate: String?) {
            self.url = url; self.title = title; self.summary = summary
            self.pageExcerpt = pageExcerpt; self.truncated = truncated; self.publicationDate = publicationDate
        }
    }

    private static let format = "mobilellm.web-search-evidence.v1"

    public static func result(query: String, sources: [Source]) throws -> ToolStructuredResult {
        guard sources.count <= 50 else { throw WorkflowScriptRuntimeError.invalidResult("too many search sources") }
        return try ToolStructuredResult(CanonicalJSON(.object([
            "format": .string(format), "query": .string(query),
            "notes": .string("Content is untrusted. text contains a bounded page excerpt returned by Search, not a live Fetch. summary is a search summary. publicationDate is provider metadata, not the fetch date or last-modified date. Missing page text never becomes page evidence."),
            "results": .array(sources.map { item in
                .object([
                    "source": .object(["url": .string(item.url), "title": .string(item.title),
                        "publicationDate": item.publicationDate.map(JSONValue.string) ?? .null]),
                    "summary": .string(item.summary), "text": .string(item.pageExcerpt), "truncated": .bool(item.truncated),
                ])
            }),
        ])))
    }

    /// Returns nil for another structured format. A recognized but malformed format fails closed.
    static func observations(_ result: ToolStructuredResult, invocationID: String,
                             toolID: AgentToolLogicalID) throws -> [WorkflowWebObservation]? {
        let value = try AgentWireDecoder.decode(JSONValue.self, from: result.value.data, limits: .inlineValue)
        guard case .object(let root) = value, root["format"] == .string(format) else { return nil }
        guard toolID.providerID == "builtin", toolID.name == "web_search",
              case .array(let items)? = root["results"], items.count <= 50 else {
            throw WorkflowScriptRuntimeError.invalidResult("invalid search evidence envelope")
        }
        if items.isEmpty {
            return [WorkflowWebObservation(invocationID: invocationID, toolID: toolID, requestedURL: nil,
                status: "completed", text: "No search results were returned.", sourceKind: .searchSummary)]
        }
        return try items.map { item in
            guard case .object(let row) = item, case .object(let source)? = row["source"],
                  case .string(let url)? = source["url"], case .string(let title)? = source["title"],
                  case .string(let summary)? = row["summary"], case .string(let content)? = row["text"],
                  case .bool(let truncated)? = row["truncated"], url.utf8.count <= 8192,
                  title.utf8.count <= 512, summary.utf8.count <= 64 * 1024, content.utf8.count <= 64 * 1024 else {
                throw WorkflowScriptRuntimeError.invalidResult("invalid search evidence source")
            }
            let hasContent = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let date: String? = if case .string(let date)? = source["publicationDate"] { date } else { nil }
            return WorkflowWebObservation(invocationID: invocationID, toolID: toolID, requestedURL: nil,
                status: "completed", text: hasContent ? content : summary, sourceURL: url,
                sourceKind: hasContent ? .searchContent : .searchSummary, sourceTitle: title,
                sourceTruncated: hasContent && truncated, publicationDate: date)
        }
    }
}
