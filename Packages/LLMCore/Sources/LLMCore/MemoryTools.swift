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

    /// Deterministic, offline canonicalization. Storage always starts with `The user `, while the natural
    /// possessive form smaller models commonly emit (`The user's name is …`) is accepted at the boundary
    /// and rewritten before it reaches the store. We deliberately do not try to recognize English with a
    /// finite verb list: that rejected perfectly ordinary facts such as "commutes" or "uses a wheelchair".
    /// Instead, the schema establishes the English contract and this last character boundary rejects the
    /// known mixed-script failure behind the magic prefix. CJK remains possible only as a short terminal
    /// proper name after an explicit English naming phrase, so `The user 用户叫Dong` is rejected but
    /// `The user is named 王东` is retained. Latin-script language cannot be proven by a character check;
    /// that part is deliberately governed by the English schema/prompt rather than a heavyweight language
    /// recognizer. No device locale, network service, or second LLM pass participates in this decision.
    static let canonicalPrefix = CanonicalMemoryText.canonicalPrefix

    static func canonicalMemory(from text: String) -> String? {
        try? CanonicalMemoryText(text).value
    }

    /// Normalize a parsed remember call as well as direct `execute` callers. Keeping this at the tool
    /// boundary means the UI event, duplicate fingerprint, execution argument, and durable note all agree
    /// on the one canonical representation.
    /// `originalUserText` is the turn the fact came from, attached by `ToolLoop` as a search alias.
    ///
    /// It is supplied by the APP, not the model. Asking the model for it was tried and measured: Gemma 4
    /// E2B ignored a second `original` parameter entirely — optional or required — while its save rate
    /// stayed at 9/10, so a 2B model simply will not emit two fields. The app already holds the user's
    /// sentence, and those are exactly the words a later question in that language will overlap with, so
    /// the deterministic source is also the better one. Never shown, never sent to a model: it exists only
    /// so `MemoryRanking` can find an English note from a question asked in another language.
    static func canonicalizedCall(_ call: ToolCall, originalUserText: String? = nil) -> ToolCall? {
        guard call.name == ToolID.remember.rawValue,
              let text = call.arg("text"),
              let canonical = canonicalMemory(from: text) else { return nil }
        var arguments: [String: String] = ["text": canonical]
        if let original = originalUserText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !original.isEmpty {
            arguments["original"] = original
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments,
                                                     options: [.sortedKeys]) else { return nil }
        return ToolCall(name: call.name, argumentsJSON: String(decoding: data, as: UTF8.self))
    }

    static let canonicalRetryInstruction =
        "The memory was not saved. Translate the same fact into English and call remember once more. "
        + "Translate the whole fact, not only the prefix. The text MUST begin exactly with \"The user \", "
        + "followed by an English sentence. Preserve proper "
        + "names and identifiers; a CJK name is allowed after an English phrase such as \"is named\". "
        + "Output only the corrected tool call."

    static let requiredCallInstruction =
        "Nothing was saved because you did not complete the remember tool call. Call remember exactly once "
        + "for the lasting fact in the latest user message. Its text must be one concise English statement "
        + "beginning exactly with \"The user \". Output only the remember tool call, with no acknowledgement."

    static let rejectedMemoryResult =
        "Error: The memory was not saved because the model did not produce a valid English memory note."

    static let rejectedMemoryReply =
        "I couldn't save that memory. Nothing was saved."

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
                              + "feel right now. HARD RULE: Save only a new fact explicitly stated in the "
                              + "latest user message. Never copy or infer a fact from saved memory, system "
                              + "instructions, conversation history, or tool output, and never save a fact "
                              + "that is already in memory.",
                   // One canonical language lets every model and every conversation consume the same
                   // durable notes. Do not add bilingual examples here: weak models copy concrete examples
                   // as content (the old Chinese-first example caused an English turn to save 用户叫Dong).
                   parameters: [ToolParam(name: "text", kind: .string,
                                          description: "One concise, self-contained third-person statement "
                                                     + "in English, regardless of the conversation language. "
                                                     + "Translate the user's fact into English, preserve "
                                                     + "proper names and identifiers, and begin the text "
                                                     + "exactly with \"The user \". Only the stored note is "
                                                     + "English; reply to the user in their language.")])
        // NOTE: the stored note also carries a search alias (the user's own sentence), but the model is
        // never asked for it — `ToolLoop` attaches it. Adding a second parameter here was tried and
        // measured: Gemma 4 E2B ignored it whether optional or required. See `canonicalizedCall`.
    }

    public func execute(argumentsJSON: String) async -> String {
        let call = ToolCall(name: "remember", argumentsJSON: argumentsJSON)
        guard let text = call.arg("text"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: missing 'text' to remember."
        }
        guard let canonicalText = Self.canonicalMemory(from: text) else {
            return "Error: \(Self.canonicalRetryInstruction)"
        }
        // `original` is not advertised in the schema and is rebuilt by `canonicalizedCall` from the
        // runtime-owned latest user turn after the model call is parsed. It stays separate from the
        // model-produced canonical `text`; the future Agent adapter will bind the same trusted source
        // directly rather than carrying this legacy-loop transport field.
        let original = call.arg("original")?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch try await store.saveIfAbsent(canonicalText, source: .model,
                                                sourceText: (original?.isEmpty ?? true) ? nil : original) {
            case .saved:
                return "Saved to memory."
            case .duplicate:
                return "Already in memory."
            }
        } catch {
            return "Error: Memory could not be saved to this device: \(error.localizedDescription)"
        }
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
                                          description: "English search words for what to find. Translate the "
                                                     + "user's request into English before calling.")])
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
