// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// The end-to-end wiring that makes Skills actually work: `startGeneration` must compose the system prompt
/// through `composedSystemPrompt()` (base prompt + the active thread's skill) and thread THAT into the
/// `ChatTurn`s the engine receives — NOT `settings.systemPrompt`. Existing skill tests only assert the pure
/// `composedSystemPrompt()` string and the context meter; none drives `send()` and inspects the turns the
/// engine was actually handed, so a regression passing the base prompt instead of the composed one would
/// silently disable every skill and pass the whole suite. A `RecordingEngine` captures the real turns.
@MainActor
final class ChatStoreSkillWiringTests: XCTestCase {

    private func makeChat(engine: LLMEngine)
        -> (chat: ChatStore, skills: SkillStore, settings: AppSettings, store: ConversationStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(component: "skill-wire-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "skill-wire-\(UUID().uuidString)")!)
        let skills = SkillStore(fileURL: dir.appending(component: "skills.json"))
        let model = LLMCatalog.bonsai8b
        let chat = ChatStore(engine: engine, store: store, settings: settings,
                             activeModel: LoadedModel(model: model, variant: model.defaultVariantValue),
                             skillStore: skills)
        return (chat, skills, settings, store, dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Centerpiece: skill instructions ride the system ChatTurn, and the turn commits

    /// A full send → stream → commit cycle with an active skill: the engine's FIRST turn must be a `.system`
    /// turn carrying BOTH the base system prompt and the skill's distinctive instruction sentence, and the
    /// streamed reply must commit with stats.
    func testActiveSkillInstructionsRideTheSystemTurnAndTheTurnCommits() async throws {
        let engine = RecordingEngine()
        let (chat, skills, settings, _, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Distinctive, non-overlapping sentinels so the assertions are unambiguous.
        settings.systemPrompt = "BASE_PROMPT_SENTINEL: be concise and kind."
        let skill = Skill(name: "Francophile", emoji: "🇫🇷", summary: "",
                          instructions: "SKILL_INSTRUCTION_SENTINEL: always answer in French.")
        skills.skills = [skill]
        _ = try XCTUnwrap(chat.newConversation())
        chat.setActiveSkill(skill.id)

        chat.draft = "hello"
        chat.send()
        try await waitUntilIdle(chat)

        // The turns the engine ACTUALLY received.
        let recorded = await engine.lastTurns()
        let turns = try XCTUnwrap(recorded)
        let system = try XCTUnwrap(turns.first, "the engine receives a leading system turn")
        XCTAssertEqual(system.role, .system)
        XCTAssertTrue(system.content.contains("BASE_PROMPT_SENTINEL"),
                      "startGeneration composes the base system prompt (not an empty/hardcoded one)")
        XCTAssertTrue(system.content.contains("SKILL_INSTRUCTION_SENTINEL"),
                      "the active skill's instructions ride the SAME system turn — the wiring that makes skills work")
        XCTAssertTrue(system.content.contains("## Active skill: Francophile"),
                      "the skill is composed with its labelled fragment header")

        // The full cycle committed the streamed reply + its stats.
        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.answer, "ok", "the streamed reply commits onto the message")
        XCTAssertEqual(assistant.stats?.stopReason, .eos, "the .done stats commit onto the message")
        XCTAssertNil(chat.streaming, "streaming ends after commit")
    }

    /// Negative sibling: with no active skill, the system turn is EXACTLY the base prompt — so the positive
    /// test above can only pass because the skill was genuinely folded in, not because of incidental text.
    func testWithoutASkillTheSystemTurnEqualsTheBasePromptExactly() async throws {
        let engine = RecordingEngine()
        let (chat, skills, settings, _, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        settings.systemPrompt = "BASE_PROMPT_SENTINEL: be concise and kind."
        skills.skills = [Skill(name: "Francophile", emoji: "🇫🇷", summary: "",
                               instructions: "SKILL_INSTRUCTION_SENTINEL: always answer in French.")]
        _ = try XCTUnwrap(chat.newConversation())
        // Deliberately do NOT activate the skill.
        XCTAssertNil(chat.activeSkill)

        chat.draft = "hello"
        chat.send()
        try await waitUntilIdle(chat)

        let recorded = await engine.lastTurns()
        let turns = try XCTUnwrap(recorded)
        let system = try XCTUnwrap(turns.first)
        XCTAssertEqual(system.role, .system)
        XCTAssertEqual(system.content, "BASE_PROMPT_SENTINEL: be concise and kind.",
                       "with no skill, the system turn is the base prompt verbatim (no stray fragment)")
        XCTAssertFalse(system.content.contains("SKILL_INSTRUCTION_SENTINEL"))
    }

    /// A skill deleted out from under a thread must degrade cleanly through the LIVE send path: the dangling
    /// `skillID` resolves to no skill, so the system turn falls back to the base prompt alone.
    func testDeletedSkillDegradesToBasePromptThroughSend() async throws {
        let engine = RecordingEngine()
        let (chat, skills, settings, _, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        settings.systemPrompt = "BASE_PROMPT_SENTINEL: be helpful."
        let skill = Skill(name: "Francophile", emoji: "🇫🇷", summary: "",
                          instructions: "SKILL_INSTRUCTION_SENTINEL: answer in French.")
        skills.skills = [skill]
        _ = try XCTUnwrap(chat.newConversation())
        chat.setActiveSkill(skill.id)
        // Delete the skill; its id lingers on the record but must resolve to nothing.
        skills.skills = []

        chat.draft = "hello"
        chat.send()
        try await waitUntilIdle(chat)

        let recorded = await engine.lastTurns()
        let system = try XCTUnwrap(try XCTUnwrap(recorded).first)
        XCTAssertEqual(system.content, "BASE_PROMPT_SENTINEL: be helpful.",
                       "a dangling skill id degrades to the base prompt on the real send path")
    }
}
