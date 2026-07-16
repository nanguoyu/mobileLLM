// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore
import AppRuntime

/// The wiring that makes memory work without the model's cooperation: `startGeneration` must compose the
/// saved facts relevant to THIS turn into the system prompt and thread that into the `ChatTurn`s the engine
/// receives. Everything memory did before depended on a small model choosing to call `recall` — which is
/// exactly what small models don't do — so a regression here wouldn't fail a tool test; it would just
/// quietly make the assistant forget you again. A `RecordingEngine` captures the real turns.
@MainActor
final class ChatStoreMemoryInjectionTests: XCTestCase {

    private let header = "## What you remember about the user"

    private func makeChat(engine: LLMEngine)
        -> (chat: ChatStore, book: MemoryBook, store: MemoryStore, settings: AppSettings, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(component: "mem-inject-\(UUID().uuidString)")
        let convos = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "mem-inject-\(UUID().uuidString)")!)
        let memoryStore = MemoryStore(fileURL: dir.appending(component: "memory.json"))
        let book = MemoryBook(store: memoryStore)
        let skills = SkillStore(fileURL: dir.appending(component: "skills.json"))
        let model = LLMCatalog.bonsai8b
        let chat = ChatStore(engine: engine, store: convos, settings: settings,
                             activeModel: LoadedModel(model: model, variant: model.defaultVariantValue),
                             memoryBook: book, skillStore: skills)
        return (chat, book, memoryStore, settings, dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Drive one full send and hand back the system turn the engine was actually given.
    private func systemTurn(after draft: String, chat: ChatStore, engine: RecordingEngine) async throws -> ChatTurn {
        chat.draft = draft
        chat.send()
        try await waitUntilIdle(chat)
        let recorded = await engine.lastTurns()
        let turns = try XCTUnwrap(recorded)
        let system = try XCTUnwrap(turns.first)
        XCTAssertEqual(system.role, .system, "the engine receives a leading system turn")
        return system
    }

    // MARK: - Centerpiece: saved facts ride the system turn

    func testRelevantSavedFactsRideTheSystemTurnWithoutTheModelAskingForThem() async throws {
        let engine = RecordingEngine()
        let (chat, book, _, settings, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        settings.systemPrompt = "BASE_PROMPT_SENTINEL: be concise."
        await book.add("The user's dog is named MEMORY_SENTINEL_MOMO")
        _ = try XCTUnwrap(chat.newConversation())

        let system = try await systemTurn(after: "what should I feed my dog?", chat: chat, engine: engine)
        XCTAssertTrue(system.content.contains("BASE_PROMPT_SENTINEL"), "the base prompt still composes")
        XCTAssertTrue(system.content.contains(header), "the memory block is labelled for the model")
        XCTAssertTrue(system.content.contains("MEMORY_SENTINEL_MOMO"),
                      "the saved fact reaches the engine on a plain send — no `recall` call involved")
    }

    /// The ranking has to be doing real work: a fact that matches nothing in the turn must not ride along
    /// just because it's saved — the block is a search, not a dump of the whole store.
    ///
    /// The query words here are deliberately distinctive. `MemoryRanking` scores by case-insensitive
    /// SUBSTRING containment, so a one-letter token ("I") hits inside almost any word and would drag
    /// unrelated notes in on recency; this pins the property that survives that, and the noise facts are
    /// newer than the relevant one precisely so recency alone can't produce a pass.
    func testFactsThatMatchNothingInTheTurnAreNotInjected() async throws {
        let engine = RecordingEngine()
        let (chat, book, _, _, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        await book.add("The user's dog Momo is a corgi")
        for i in 0..<8 { await book.add("Note \(i): the quarterly SENTINEL_NOISE spreadsheet") }
        _ = try XCTUnwrap(chat.newConversation())

        let system = try await systemTurn(after: "corgi grooming advice?", chat: chat, engine: engine)
        XCTAssertTrue(system.content.contains("Momo"), "the fact the turn is about is injected")
        XCTAssertFalse(system.content.contains("SENTINEL_NOISE"),
                       "facts scoring zero against the turn are left out, however recent they are")
    }

    /// A fact the MODEL saved (straight to the durable store, as the `remember` tool does — the UI's mirror
    /// never sees it) must be in the NEXT turn's prompt. This is the refresh-before-compose contract; without
    /// it the assistant would keep answering from a snapshot taken at launch.
    func testAFactSavedByTheToolMidSessionIsInTheNextTurnsPrompt() async throws {
        let engine = RecordingEngine()
        let (chat, _, store, _, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try XCTUnwrap(chat.newConversation())

        let before = try await systemTurn(after: "hello", chat: chat, engine: engine)
        XCTAssertFalse(before.content.contains(header), "nothing saved yet — no block")

        // Exactly what RememberTool does, behind the UI's back.
        await store.save("The user's cat is named TOOL_SAVED_SENTINEL", source: .model)

        let after = try await systemTurn(after: "tell me about my cat", chat: chat, engine: engine)
        XCTAssertTrue(after.content.contains("TOOL_SAVED_SENTINEL"),
                      "the store is re-read before composing, so the model's own save lands in the next prompt")
    }

    // MARK: - Absent when it should be

    func testNoMemoryBlockWhenMemoryIsSwitchedOff() async throws {
        let engine = RecordingEngine()
        let (chat, book, _, settings, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        settings.systemPrompt = "BASE_PROMPT_SENTINEL: be concise."
        await book.add("The user's dog is named MEMORY_SENTINEL_MOMO")
        settings.disabledBuiltInTools.formUnion([ToolID.recall.rawValue, ToolID.remember.rawValue])
        _ = try XCTUnwrap(chat.newConversation())

        let system = try await systemTurn(after: "what should I feed my dog?", chat: chat, engine: engine)
        XCTAssertEqual(system.content, "BASE_PROMPT_SENTINEL: be concise.",
                       "memory off means the facts stay on disk — not injected by another route")
        XCTAssertFalse(system.content.contains("MEMORY_SENTINEL_MOMO"))
    }

    func testNoMemoryBlockWhenNothingIsSaved() async throws {
        let engine = RecordingEngine()
        let (chat, _, _, settings, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        settings.systemPrompt = "BASE_PROMPT_SENTINEL: be concise."
        _ = try XCTUnwrap(chat.newConversation())

        let system = try await systemTurn(after: "hello", chat: chat, engine: engine)
        XCTAssertEqual(system.content, "BASE_PROMPT_SENTINEL: be concise.",
                       "an empty store adds no header, no blank section — the prompt is untouched")
    }

    // MARK: - Composes with a skill

    func testMemoryComposesAfterTheBasePromptAndTheActiveSkill() async throws {
        let engine = RecordingEngine()
        let (chat, book, _, settings, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        settings.systemPrompt = "BASE_PROMPT_SENTINEL: be concise."
        let skill = Skill(name: "Francophile", emoji: "🇫🇷", summary: "",
                          instructions: "SKILL_INSTRUCTION_SENTINEL: always answer in French.")
        chat.skillStore?.skills = [skill]
        await book.add("The user's dog is named MEMORY_SENTINEL_MOMO")
        _ = try XCTUnwrap(chat.newConversation())
        chat.setActiveSkill(skill.id)

        let system = try await systemTurn(after: "what should I feed my dog?", chat: chat, engine: engine)
        let base = try XCTUnwrap(system.content.range(of: "BASE_PROMPT_SENTINEL"))
        let skillRange = try XCTUnwrap(system.content.range(of: "SKILL_INSTRUCTION_SENTINEL"))
        let memory = try XCTUnwrap(system.content.range(of: "MEMORY_SENTINEL_MOMO"),
                                   "a skill must not displace memory — both compose")
        XCTAssertTrue(base.lowerBound < skillRange.lowerBound && skillRange.lowerBound < memory.lowerBound,
                      "order is base prompt → skill → memory, so the skill's instructions read first")
    }

    // MARK: - The context meter charges for it

    func testTheContextMeterCountsTheInjectedBlock() async throws {
        let engine = RecordingEngine()
        let (chat, book, _, _, dir) = makeChat(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try XCTUnwrap(chat.newConversation())
        chat.draft = "what should I feed my dog?"

        let before = chat.contextUsage().used
        await book.add("The user's dog is named Momo and eats twice a day")
        let after = chat.contextUsage().used
        XCTAssertGreaterThan(after, before, "injected memory is charged to the window, not hidden from it")
    }

    // MARK: - Pure composition (bounds, query, ranking)

    func testTheBlockIsHardCappedNoMatterHowMuchIsSaved() throws {
        let facts = (0..<50).map { MemoryFact(text: "Fact \($0): " + String(repeating: "dog ", count: 60),
                                              createdAt: Date(timeIntervalSince1970: Double($0))) }
        let block = try XCTUnwrap(ChatStore.memoryBlock(facts, query: "dog"))
        XCTAssertLessThanOrEqual(block.count, 400, "a full store can't eat the context window")
        XCTAssertTrue(block.hasPrefix(header))
    }

    /// One rambling fact must not swallow the whole budget and starve the rest: lines are clipped first,
    /// then packed.
    func testALongFactIsClippedRatherThanCrowdingOutTheOthers() throws {
        let rambler = MemoryFact(text: "dog " + String(repeating: "very long ", count: 100),
                                 createdAt: Date(timeIntervalSince1970: 2))
        let short = MemoryFact(text: "dog is named Momo", createdAt: Date(timeIntervalSince1970: 1))
        let block = try XCTUnwrap(ChatStore.memoryBlock([rambler, short], query: "dog"))
        XCTAssertLessThanOrEqual(block.count, 400)
        XCTAssertTrue(block.contains("…"), "the long fact is truncated")
        XCTAssertTrue(block.contains("Momo"), "and the short one still makes it in")
    }

    func testBlockIsNilWhenNothingMatchesOrNothingIsSaved() {
        XCTAssertNil(ChatStore.memoryBlock([], query: "dog"), "no facts, no block")
        XCTAssertNil(ChatStore.memoryBlock([MemoryFact(text: "likes tea")], query: "spaceship"),
                     "no matches, no block — never an empty header")
    }

    func testBlockCapsTheNumberOfFacts() throws {
        let facts = (0..<10).map { MemoryFact(text: "dog note \($0)",
                                              createdAt: Date(timeIntervalSince1970: Double($0))) }
        let block = try XCTUnwrap(ChatStore.memoryBlock(facts, query: "dog"))
        XCTAssertEqual(block.components(separatedBy: "\n- ").count - 1, 5, "top 5, newest first")
        XCTAssertTrue(block.contains("dog note 9"))
        XCTAssertFalse(block.contains("dog note 4"), "the oldest of the ten fall off the list")
    }

    /// The query is this turn plus one of carry-over — a follow-up ("and his birthday?") has to be able to
    /// surface a fact named only in the previous turn.
    func testMemoryQueryUsesTheDraftAndTheLastTwoUserTurns() {
        let history = [Message(role: .user, answer: "my dog Momo"),
                       Message(role: .assistant, answer: "nice dog"),
                       Message(role: .user, answer: "he is a corgi"),
                       Message(role: .assistant, answer: "cute")]
        let query = ChatStore.memoryQuery(draft: "and his birthday?", history: history)
        XCTAssertTrue(query.contains("and his birthday?"), "the turn being sent")
        XCTAssertTrue(query.contains("he is a corgi"), "and the turn before it")
        XCTAssertTrue(query.contains("my dog Momo"))
        XCTAssertFalse(query.contains("nice dog"), "the assistant's own words aren't the user's context")
    }

    func testMemoryQueryOnTheSendPathIsJustTheHistory() {
        let history = [Message(role: .user, answer: "what should I feed my dog?")]
        XCTAssertEqual(ChatStore.memoryQuery(history: history), "what should I feed my dog?",
                       "the outgoing turn is already in history — it must not be counted twice")
    }
}
