// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// Save a short fact the user wants remembered across the conversation and future launches. Backed by an
/// injected `MemoryStoring` so the tool is unit-testable and the UI can manage the same store.
public struct RememberTool: Tool {
    private let store: any MemoryStoring
    public init(store: any MemoryStoring) { self.store = store }

    public var schema: ToolSchema {
        ToolSchema(name: "remember",
                   description: "Save a short fact or preference the user asks you to remember (their name, "
                              + "a deadline, a like/dislike) so you can recall it in a later conversation.",
                   parameters: [ToolParam(name: "text", kind: .string,
                                          description: "The fact to save, e.g. \"The user's dog is named Momo\"")])
    }

    public func execute(argumentsJSON: String) async -> String {
        guard let text = ToolCall(name: "remember", argumentsJSON: argumentsJSON).arg("text"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing 'text' to remember."
        }
        let fact = await store.save(text)
        return "Saved: \(fact.text)"
    }
}

/// Search previously saved facts for the ones most relevant to a query. Ranking is case-insensitive token
/// containment, newest-first among ties, capped at `limit` (default 5).
public struct RecallTool: Tool {
    private let store: any MemoryStoring
    private let limit: Int
    public init(store: any MemoryStoring, limit: Int = 5) { self.store = store; self.limit = max(1, limit) }

    public var schema: ToolSchema {
        ToolSchema(name: "recall",
                   description: "Search your saved notes for facts the user told you earlier. Check this "
                              + "before saying you don't know something personal the user may have shared.",
                   parameters: [ToolParam(name: "query", kind: .string,
                                          description: "What to look for, e.g. \"dog\" or \"birthday\"")])
    }

    public func execute(argumentsJSON: String) async -> String {
        let query = ToolCall(name: "recall", argumentsJSON: argumentsJSON).arg("query") ?? ""
        let matches = Self.rank(await store.list(), query: query, limit: limit)
        guard !matches.isEmpty else {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? "No saved notes yet." : "No saved notes match \"\(q)\"."
        }
        return matches.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
    }

    /// Rank saved facts against a query — a fact scores by how many query tokens it contains
    /// (case-insensitive substring), ties broken newest-first, capped at `limit`. A blank query returns the
    /// most recent facts. Pure + unit-tested. (Deliberately simple: no stemming or fuzzy matching.)
    static func rank(_ facts: [MemoryFact], query: String, limit: Int) -> [MemoryFact] {
        let byRecency = facts.sorted { $0.createdAt > $1.createdAt }
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else { return Array(byRecency.prefix(limit)) }
        let scored: [(fact: MemoryFact, score: Int)] = byRecency.compactMap { fact in
            let hay = fact.text.lowercased()
            let score = tokens.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
            return score > 0 ? (fact, score) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fact.createdAt > $1.fact.createdAt }
            .prefix(limit)
            .map(\.fact)
    }
}
