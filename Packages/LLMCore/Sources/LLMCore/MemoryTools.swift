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
                   // Every clause here is set by measurement, not taste — `llama-smoke --memory-eval` runs
                   // 20 labelled turns against real weights and reports recall vs restraint. The version
                   // that said "their name, a preference or dislike, a constraint (allergy, deadline…)"
                   // scored recall 2/10 on Gemma 4 E2B: it saved the cat (which resembled the example) and
                   // "I'm vegetarian", and silently dropped the user's allergy, job, studies, car, hobby,
                   // daughter, home and language preference. Restraint was already 10/10, so the room was
                   // all on the recall side.
                   //
                   // What moved it: naming the CATEGORIES a person actually has, instead of an abstract
                   // "lasting fact"; a concrete next-week test the model can apply to a sentence; and a
                   // negative list of the four shapes that aren't facts (greeting, question, request,
                   // passing mood) rather than the vague "chatter".
                   description: "Save a lasting fact the user states about themselves, so it survives this "
                              + "conversation. Call this the MOMENT they mention one — without being asked, "
                              + "before you reply. Facts worth saving: their name, where they live, their "
                              + "family, their pets, their job, their studies, their car, their hobbies, "
                              + "what they eat, allergies and other constraints, the tools or languages "
                              + "they use, and anything they like or dislike. The test: if the sentence "
                              + "tells you something about this person that would still be true next week, "
                              + "save it. Answering \"I'll remember that\" does NOT remember anything — this "
                              + "tool is the only thing that does, so call it and then reply. Do NOT save "
                              + "greetings, questions they ask, tasks they request, or how they happen to "
                              + "feel right now.",
                   // "In the user's own language" is load-bearing, not politeness: a fact is retrieved by
                   // word overlap with the user's question, so one saved in English is unreachable from a
                   // question asked in Chinese. Two examples, in both languages and of DIFFERENT shapes —
                   // a single one anchors weak models hard: with only "The user's dog is named Momo" here,
                   // DeepSeek copied "用户的狗叫 Momo" verbatim as the fact for an unrelated turn, and Gemma
                   // saved pets while ignoring everything else.
                   parameters: [ToolParam(name: "text", kind: .string,
                                          description: "One self-contained fact about the user, written in "
                                                     + "their own language — the words they'd use to ask "
                                                     + "about it later. E.g. \"用户在南京大学读计算机\" / "
                                                     + "\"The user is allergic to peanuts\"")])
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
