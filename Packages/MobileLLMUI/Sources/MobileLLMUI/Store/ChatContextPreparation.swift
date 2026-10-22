// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime
import LLMCore

extension ChatStore {
    /// The search query for the memory block: the outgoing user turn, plus the one before it. A follow-up
    /// often can't stand alone ("and his birthday?"), so one turn of carry-over is what makes the right
    /// fact surface — but only one: more history dilutes the token scoring into "everything matches".
    /// `draft` is the text not yet sent (the meter's view of the next turn); on the send path it's already
    /// in `history`, so it's left empty there.
    public nonisolated static func memoryQuery(draft: String = "", history: [Message]) -> String {
        let recentUserTurns = history.filter { $0.role == .user && !$0.answer.isEmpty }.suffix(2).map(\.answer)
        return ([draft] + recentUserTurns).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The "what you remember" block: the top `limit` facts for `query`, one per line, hard-capped at
    /// `maxChars` — the whole point is a small model reading a short list, and an unbounded block would eat
    /// the 4K window it has to answer in. Model-saved notes use canonical English. If a query in another
    /// language has no lexical hit, the newest notes are the small deterministic fallback; `recall` keeps
    /// strict search semantics and asks the model for English search terms. Each line is clipped first, so
    /// one rambling fact can't crowd the rest out; then lines are taken while the block fits.
    /// Pure + nonisolated so the bound is unit-testable off the main actor.
    nonisolated static func memoryBlock(_ facts: [MemoryFact], query: String,
                                        limit: Int = 5, maxChars: Int = 400) -> String? {
        let header = "## What you remember about the user\n"
            + "These notes are already saved; use them as facts and never call remember for them. "
            + "Notes are stored in English, but reply in the user's language."
        let selected = selectedMemoryFacts(facts, query: query, limit: limit)
        var block = header
        for fact in selected {
            let flat = fact.text.replacingOccurrences(of: "\n", with: " ")
            let line = "\n- " + (flat.count > 120 ? String(flat.prefix(120)) + "…" : flat)
            guard block.count + line.count <= maxChars else { break }
            block += line
        }
        return block == header ? nil : block
    }

    /// Shared by production frozen inputs, the context meter, and legacy preview composition.
    public nonisolated static func selectedMemoryFacts(
        _ facts: [MemoryFact], query: String, limit: Int = 5
    ) -> [MemoryFact] {
        let matches = MemoryRanking.rank(facts, query: query, limit: limit)
        return matches.isEmpty ? MemoryRanking.rank(facts, query: "", limit: limit) : matches
    }

    // MARK: - Pure helpers (unit-tested)

    /// Trim history to `cap` tokens, ALWAYS keeping the system turn (DESIGN §2.3). Assistant turns are
    /// fed back as their answer text only (reasoning is not re-sent). Empty placeholder turns are
    /// skipped — but a user turn that carries image attachments is kept even with no text (a "describe
    /// this" turn). The most recent turn is kept even if it alone exceeds the budget. `images` supplies
    /// the (already-loaded) encoded bytes for a message's attachments; user turns carry them to the
    /// vision engine.
    public static func chatTurns(messages: [Message], systemPrompt: String?, cap: Int,
                                 images: (Message) -> [Data] = { _ in [] }) -> [ChatTurn] {
        var systemTurn: ChatTurn?
        var systemTokens = 0
        if let prompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            systemTurn = ChatTurn(role: .system, content: prompt)
            systemTokens = TokenEstimate.tokens(in: prompt)   // CJK-aware, matching the per-message estimate
        }
        let candidates = messages.filter { $0.role != .system && ($0.hasVisibleContent) }
        var budget = max(0, cap - systemTokens)
        var kept: [ChatTurn] = []
        for message in candidates.reversed() {
            let tokens = message.approximateTokens
            if !kept.isEmpty && tokens > budget { break }
            let role: ChatTurn.Role = message.role == .assistant ? .assistant : .user
            let turnImages = role == .user ? images(message) : []
            kept.append(ChatTurn(role: role, content: message.answer, images: turnImages))
            budget -= tokens
            if budget <= 0 { break }
        }
        // Auto-compaction (DESIGN §2.3): rather than silently dropping the oldest turns, leave the model a
        // breadcrumb of what they were about — an extractive summary of the dropped user turns (no extra
        // model call). This keeps continuity on the small on-device contexts where trimming bites often.
        let dropped = Array(candidates.dropLast(kept.count))
        let note = compactionNote(dropped)

        var turns: [ChatTurn] = []
        if let systemTurn { turns.append(systemTurn) }
        if let note { turns.append(ChatTurn(role: .system, content: note)) }
        turns.append(contentsOf: kept.reversed())
        return turns
    }

    /// Add the narrow instruction used by the single reasoning-only recovery pass. It deliberately
    /// contains no tool declarations and does not replay the first pass's private reasoning as conversation
    /// content: the same user request is enough to ask for the missing visible answer, while keeping hidden
    /// reasoning out of a synthetic prompt and out of the eventual answer.
    static func answerRecoveryTurns(_ messages: [ChatTurn]) -> [ChatTurn] {
        let instruction = """
        The previous attempt produced internal reasoning but ended before producing a user-visible answer. \
        Complete the same turn now. Output only the final answer: do not think aloud, repeat hidden \
        reasoning, call tools, or emit tool-call markup. Reply in the language of the latest user request.
        """
        var recovered = messages
        if let index = recovered.firstIndex(where: { $0.role == .system }) {
            let separator = recovered[index].content.isEmpty ? "" : "\n\n"
            recovered[index] = ChatTurn(
                role: .system,
                content: recovered[index].content + separator + instruction,
                images: recovered[index].images
            )
        } else {
            recovered.insert(ChatTurn(role: .system, content: instruction), at: 0)
        }
        return recovered
    }

    /// Load the encoded image bytes for every attachment across `messages` (current thread only), keyed by
    /// message id, for `chatTurns`' image provider. Awaits the store actor per file; the returned map is a
    /// generation-scoped local that's released when the caller's task ends (memory discipline).
    static func loadAttachmentImages(for messages: [Message],
                                     from store: ConversationStore) async -> [UUID: [Data]] {
        var result: [UUID: [Data]] = [:]
        for message in messages {
            guard let refs = message.attachments, !refs.isEmpty else { continue }
            var datas: [Data] = []
            for ref in refs {
                if let data = await store.attachmentData(ref.id) { datas.append(data) }
            }
            if !datas.isEmpty { result[message.id] = datas }
        }
        return result
    }

    /// A compact system note summarizing dropped turns, or nil when nothing was dropped.
    static func compactionNote(_ dropped: [Message]) -> String? {
        let topics = dropped.filter { $0.role == .user }
            .map { firstFragment($0.answer) }.filter { !$0.isEmpty }
        guard !topics.isEmpty else { return nil }
        let recent = topics.suffix(6).joined(separator: "; ")
        return "[Earlier in this conversation, older turns were summarized to save space. The user "
             + "previously asked about: \(recent). Ask if you need those details again.]"
    }

    private static func firstFragment(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(60)) + "…" : t
    }

    /// First-line title from the first user message, trimmed to a reasonable length.
    static func autoTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : (trimmed.isEmpty ? "New Chat" : trimmed)
    }
}
