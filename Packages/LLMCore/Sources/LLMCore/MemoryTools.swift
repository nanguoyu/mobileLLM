// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// Save a short fact the user wants remembered across the conversation and future launches. Backed by an
/// injected `MemoryStoring` so the tool is unit-testable and the UI can manage the same store.
///
/// This tool IS the auto-save path: the schema description below is what a 2B model reads in the tool
/// block (`ToolPrompt.systemBlock` renders every schema's description verbatim), so it carries both the
/// trigger — save the moment a durable fact appears — and the criteria that keep it from saving chatter.
/// There is deliberately NO background extraction pass: a second LLM call per turn to mine facts would
/// double generation cost on a phone, for a feature the user can also just type in. The tool plus a sharp
/// description is the honest v1; the memory screen is where anything it misses gets fixed by hand.
public struct RememberTool: Tool {
    private let store: any MemoryStoring
    public init(store: any MemoryStoring) { self.store = store }

    public var schema: ToolSchema {
        ToolSchema(name: "remember",
                   description: "Save a lasting fact about the user, as soon as they mention one, so it "
                              + "survives this conversation: their name, a preference or dislike, a "
                              + "constraint (allergy, deadline, the tools they use), or context that will "
                              + "still matter next week. Save it in the same turn they say it — don't wait "
                              + "to be asked. Do NOT save one-off chatter, or things they merely asked about.",
                   parameters: [ToolParam(name: "text", kind: .string,
                                          description: "One self-contained fact, e.g. \"The user's dog is named Momo\"")])
    }

    public func execute(argumentsJSON: String) async -> String {
        guard let text = ToolCall(name: "remember", argumentsJSON: argumentsJSON).arg("text"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing 'text' to remember."
        }
        let fact = await store.save(text, source: .model)
        return "Saved: \(fact.text)"
    }
}

/// Search previously saved facts for the ones most relevant to a query — ranked by `MemoryRanking` (the
/// same scoring the store and the auto-injected prompt block use), capped at `limit` (default 5).
///
/// Kept even though the most relevant facts now ride the system prompt automatically: injection is capped
/// at a handful, and a model that thinks to ask deserves the rest of the store.
public struct RecallTool: Tool {
    private let store: any MemoryStoring
    private let limit: Int
    public init(store: any MemoryStoring, limit: Int = 5) { self.store = store; self.limit = max(1, limit) }

    public var schema: ToolSchema {
        ToolSchema(name: "recall",
                   description: "Search your saved notes for something the user told you earlier. Anything "
                              + "already listed under \"What you remember about the user\" is in front of "
                              + "you — use this to look for what isn't, before saying you don't know "
                              + "something personal they may have shared.",
                   parameters: [ToolParam(name: "query", kind: .string,
                                          description: "What to look for, e.g. \"dog\" or \"birthday\"")])
    }

    public func execute(argumentsJSON: String) async -> String {
        let query = ToolCall(name: "recall", argumentsJSON: argumentsJSON).arg("query") ?? ""
        let matches = await store.search(query, limit: limit)
        guard !matches.isEmpty else {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? "No saved notes yet." : "No saved notes match \"\(q)\"."
        }
        return matches.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
    }
}
