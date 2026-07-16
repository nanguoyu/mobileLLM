// SPDX-License-Identifier: MIT

import Foundation

/// A named, reusable instruction pack a user activates PER CONVERSATION (Skills v1). When active, a
/// skill's `instructions` are appended to the system prompt for that thread (see
/// `ChatStore.systemPrompt(base:skill:)`), so the model behaves like a Translator / Proofreader / … for
/// the length of the chat. Selection is explicit — 2–8B on-device models are unreliable at self-routing,
/// so auto-suggestion is deferred, not built.
///
/// `isBuiltIn` marks the seeded starter skills: they're immutable in the UI (a "Duplicate to edit" action
/// makes an editable custom copy) and carry stable ids so a conversation that references one survives a
/// relaunch. Custom skills are fully editable + deletable. Codable so `SkillStore` can persist them.
public struct Skill: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    /// Short display name shown in the composer menu, the chip, and the management list.
    public var name: String
    /// A single emoji used as the skill's glyph (menu, chip, list row).
    public var emoji: String
    /// One line on WHEN to use it — the management-list subtitle.
    public var summary: String
    /// The system-prompt fragment appended when the skill is active (the actual behavior).
    public var instructions: String
    /// True for the seeded starters (immutable in the UI); false for user-created skills.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, emoji: String, summary: String,
                instructions: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.summary = summary
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
    }
}

public extension Skill {
    /// The five starter skills seeded on first load. Instructions are written for **small on-device
    /// models**: short, imperative, one behavior per line — the same craft as the stock system prompt
    /// (a long, soft prompt makes a small model recite rules instead of following them).
    ///
    /// Built-in ids are FIXED (not random) so the seed is deterministic: a conversation that references a
    /// built-in keeps working across relaunches, and the seed-once check never mints a second copy.
    static let builtIns: [Skill] = [
        Skill(
            id: UUID(uuidString: "5C1A0001-0000-4000-A000-000000000001")!,
            name: "Translator", emoji: "🌐",
            summary: "Translate between Chinese and English — nothing else.",
            instructions: """
            You are a translation engine. Detect whether the user's message is Chinese or English, then \
            translate it into the OTHER language.
            - Output only the translation. No explanations, no notes, no pinyin, no restating the original.
            - Preserve line breaks, formatting, names, numbers, and punctuation.
            - If a message mixes both languages, translate each part into its opposite language.
            """,
            isBuiltIn: true),
        Skill(
            id: UUID(uuidString: "5C1A0002-0000-4000-A000-000000000002")!,
            name: "Proofreader", emoji: "✍️",
            summary: "Fix grammar and clarity, then summarize what changed.",
            instructions: """
            Proofread the user's text.
            - Return the corrected version first, keeping the original meaning, tone, and formatting.
            - Fix grammar, spelling, punctuation, and awkward phrasing. Do not rewrite the style or add content.
            - After the corrected text, add one line starting with "Changes:" briefly listing what you fixed.
            - If the text is already clean, return it unchanged and write "Changes: none."
            """,
            isBuiltIn: true),
        Skill(
            id: UUID(uuidString: "5C1A0003-0000-4000-A000-000000000003")!,
            name: "Code Explainer", emoji: "💡",
            summary: "Explain code by purpose first, then call out pitfalls.",
            instructions: """
            Explain the code the user shares.
            - Start with one sentence on what it does overall.
            - Then go in order, saying what each meaningful line or block is FOR (its purpose), not just \
            what the syntax is.
            - Finish with a short "Pitfalls" list of bugs, edge cases, or risks you notice.
            - Be concrete and skip trivia. If there's no code, ask for it.
            """,
            isBuiltIn: true),
        Skill(
            id: UUID(uuidString: "5C1A0004-0000-4000-A000-000000000004")!,
            name: "Researcher", emoji: "🔎",
            summary: "Search the web, read the best source, answer with citations.",
            instructions: """
            Answer from live sources, not memory. Follow this tool chain:
            1. Call web_search with a focused query.
            2. Pick the most relevant, trustworthy result and call fetch_webpage on its URL to read the page.
            3. If one page isn't enough, search or fetch again.
            Then answer in your own words and cite each claim with the page title and URL you used. If the \
            tools return nothing useful, say so instead of guessing. (Turn Tools on for this skill to work.)
            """,
            isBuiltIn: true),
        Skill(
            id: UUID(uuidString: "5C1A0005-0000-4000-A000-000000000005")!,
            name: "Concise Mode", emoji: "⚡",
            summary: "Answer in three sentences or fewer.",
            instructions: """
            Answer in at most three sentences.
            - Lead with the direct answer, then cut every optional word.
            - No preamble, no filler, and no lists unless the user explicitly asks for detail or steps.
            - If a question truly can't be answered briefly, give the shortest complete answer and stop.
            """,
            isBuiltIn: true),
    ]
}
