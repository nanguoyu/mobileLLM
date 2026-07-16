// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// `ChatStore` ↔ skill wiring (Skills v1, S6): active-skill resolution (incl. the deleted-skill fallback),
/// `setSkill` persistence across a store reload, that the composed system prompt + context meter both count
/// the active skill, and that setting a skill with no thread creates one.
@MainActor
final class ChatStoreSkillTests: XCTestCase {

    private func makeChat() -> (chat: ChatStore, skills: SkillStore, store: ConversationStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(component: "skill-chat-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "skill-chat-\(UUID().uuidString)")!)
        let skills = SkillStore(fileURL: dir.appending(component: "skills.json"))
        let model = LLMCatalog.bonsai8b
        let chat = ChatStore(engine: MockLLMEngine(script: .init()), store: store, settings: settings,
                             activeModel: LoadedModel(model: model, variant: model.defaultVariantValue),
                             skillStore: skills)
        return (chat, skills, store, dir)
    }

    private func pollConversation(_ store: ConversationStore, id: UUID,
                                  until predicate: @escaping (Conversation) -> Bool,
                                  timeout: TimeInterval = 2) async throws -> Conversation {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let c = await store.load(id), predicate(c) { return c }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let last = await store.load(id)
        return try XCTUnwrap(last)   // last read — the assertion will surface the diff
    }

    // MARK: - Resolution

    func testActiveSkillResolvesFromConversation() throws {
        let (chat, skills, _, dir) = makeChat()
        defer { try? FileManager.default.removeItem(at: dir) }
        let skill = Skill(name: "Translator", emoji: "🌐", summary: "", instructions: "Translate.")
        skills.skills = [skill]

        _ = try XCTUnwrap(chat.newConversation())
        XCTAssertNil(chat.activeSkill, "a fresh thread has no skill")

        chat.setActiveSkill(skill.id)
        XCTAssertEqual(chat.activeSkill?.id, skill.id, "the active thread's skill resolves through the store")
        XCTAssertEqual(chat.activeConversation?.skillID, skill.id, "the record remembers the selection")

        chat.setActiveSkill(nil)
        XCTAssertNil(chat.activeSkill, "clearing the selection resolves to nil")
    }

    func testActiveSkillIsNilWhenSkillDeleted() throws {
        let (chat, skills, _, dir) = makeChat()
        defer { try? FileManager.default.removeItem(at: dir) }
        let skill = Skill(name: "Translator", emoji: "🌐", summary: "", instructions: "Translate only.")
        skills.skills = [skill]
        _ = try XCTUnwrap(chat.newConversation())
        chat.setActiveSkill(skill.id)

        // The skill is deleted out from under the thread; its id lingers on the record.
        skills.skills = []
        XCTAssertNil(chat.activeSkill, "a dangling skillID resolves to no skill (nil-safe)")
        XCTAssertEqual(chat.activeConversation?.skillID, skill.id, "resolution is nil-safe; the id is left as-is")
        XCTAssertFalse(chat.composedSystemPrompt().contains("Translate only."),
                       "composition falls back cleanly to the base prompt")
    }

    // MARK: - Composition + meter

    func testComposedPromptAndContextMeterCountTheSkill() throws {
        let (chat, skills, _, dir) = makeChat()
        defer { try? FileManager.default.removeItem(at: dir) }
        let skill = Skill(name: "Translator", emoji: "🌐", summary: "",
                          instructions: String(repeating: "Translate every sentence carefully. ", count: 12))
        skills.skills = [skill]
        _ = try XCTUnwrap(chat.newConversation())

        let usedBefore = chat.contextUsage().used
        chat.setActiveSkill(skill.id)

        XCTAssertTrue(chat.composedSystemPrompt().contains("Translate every sentence carefully."),
                      "the active skill's instructions are composed into the system prompt")
        XCTAssertGreaterThan(chat.contextUsage().used, usedBefore,
                             "the skill text is charged to the context meter (same path as the system prompt)")
    }

    // MARK: - Persistence

    func testSetSkillPersistsAcrossReload() async throws {
        let (chat, skills, _, dir) = makeChat()
        defer { try? FileManager.default.removeItem(at: dir) }
        let skill = Skill(name: "Proofreader", emoji: "✍️", summary: "", instructions: "Fix it.")
        skills.skills = [skill]
        // Seed the conversation directly in the mirror (like ChatStoreTests.testRegenerateTargetingHelpers)
        // so `setSkill` is the SOLE disk writer — `persist` is fire-and-forget, and racing it against the
        // newConversation seed-write would make the reload non-deterministic.
        let convo = Conversation(modelID: "m", variantID: "v")
        chat.conversations = [convo]
        chat.activeID = convo.id

        chat.setSkill(skill.id, for: convo.id)

        // Reload from a FRESH store at the same directory — the selection must survive.
        let fresh = ConversationStore(directory: dir)
        let reloaded = try await pollConversation(fresh, id: convo.id) { $0.skillID == skill.id }
        XCTAssertEqual(reloaded.skillID, skill.id, "the per-thread skill selection is persisted")
    }

    // MARK: - Lazy thread creation

    func testSetActiveSkillCreatesThreadWhenNone() throws {
        let (chat, skills, _, dir) = makeChat()
        defer { try? FileManager.default.removeItem(at: dir) }
        let skill = Skill(name: "Concise", emoji: "⚡", summary: "", instructions: "Be brief.")
        skills.skills = [skill]

        XCTAssertNil(chat.activeConversation, "no thread yet")
        chat.setActiveSkill(skill.id)
        XCTAssertNotNil(chat.activeConversation, "setting a skill with no active thread creates one")
        XCTAssertEqual(chat.activeSkill?.id, skill.id)
    }
}
