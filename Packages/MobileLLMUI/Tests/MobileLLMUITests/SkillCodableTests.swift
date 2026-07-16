// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// `Skill` Codable + the built-in seed contract, `Conversation.skillID` back-compat (strictly additive,
/// matching the `Message.attachments` pattern), and the pure system-prompt composition (Skills v1, S6).
/// `@MainActor` so the `chatTurns` integration check can call the store's main-actor-isolated helper.
@MainActor
final class SkillCodableTests: XCTestCase {

    // MARK: - Skill Codable + seeds

    func testSkillRoundTrips() throws {
        let skill = Skill(name: "Pirate", emoji: "🏴‍☠️", summary: "Talk like a pirate",
                          instructions: "Answer as a pirate.", isBuiltIn: false)
        let back = try JSONDecoder().decode(Skill.self, from: JSONEncoder().encode(skill))
        XCTAssertEqual(back, skill, "a skill survives a Codable round-trip intact")
    }

    func testBuiltInsAreFiveStableUniqueAndFlagged() {
        XCTAssertEqual(Skill.builtIns.count, 5, "five starter skills")
        XCTAssertEqual(Set(Skill.builtIns.map(\.id)).count, 5, "built-in ids are unique")
        XCTAssertTrue(Skill.builtIns.allSatisfy(\.isBuiltIn), "every seed is flagged built-in")
        // Fixed (not random) ids: evaluating twice yields the same ids, so a thread referencing a built-in
        // survives a relaunch and the seed-once check never mints a duplicate.
        XCTAssertEqual(Skill.builtIns.map(\.id), Skill.builtIns.map(\.id))
        XCTAssertTrue(Skill.builtIns.allSatisfy { !$0.instructions.isEmpty && !$0.name.isEmpty })
    }

    // MARK: - Conversation.skillID back-compat

    func testOldConversationWithoutSkillIDDecodesNil() throws {
        // A record written before `skillID` existed — the key is simply absent.
        let json = Data("""
        {"id":"\(UUID().uuidString)","title":"t","createdAt":0,"updatedAt":0,\
        "modelID":"m","variantID":"v","messages":[],"pinned":false}
        """.utf8)
        let convo = try JSONDecoder().decode(Conversation.self, from: json)
        XCTAssertNil(convo.skillID, "a missing key decodes as nil (back-compat)")
    }

    func testSkilllessConversationReEncodesWithoutSkillIDKey() throws {
        let convo = Conversation(modelID: "m", variantID: "v")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(convo), encoding: .utf8))
        XCTAssertFalse(json.contains("skillID"),
                       "a skill-less thread omits the key (byte-compatible with the old form)")
    }

    func testSkillIDRoundTrips() throws {
        let id = UUID()
        let convo = Conversation(modelID: "m", variantID: "v", skillID: id)
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(convo))
        XCTAssertEqual(back.skillID, id, "the skill id survives a Codable round-trip")
        XCTAssertEqual(back, convo)
    }

    // MARK: - Pure system-prompt composition

    func testComposeWithoutSkillReturnsBaseUnchanged() {
        XCTAssertEqual(ChatStore.systemPrompt(base: "BASE PROMPT", skill: nil), "BASE PROMPT")
    }

    func testComposeAppendsSkillFragment() {
        let skill = Skill(name: "Translator", emoji: "🌐", summary: "", instructions: "Translate only.")
        XCTAssertEqual(ChatStore.systemPrompt(base: "BASE", skill: skill),
                       "BASE\n\n## Active skill: Translator\nTranslate only.")
    }

    func testComposeWithBlankBaseIsFragmentOnly() {
        // System prompt "off" (blank) + an active skill still yields a working prompt (just the fragment).
        let skill = Skill(name: "T", emoji: "🌐", summary: "", instructions: "Do it.")
        XCTAssertEqual(ChatStore.systemPrompt(base: "   \n ", skill: skill), "## Active skill: T\nDo it.")
    }

    /// The composed prompt rides the SAME `chatTurns` path the base system prompt does — so the skill's
    /// instructions reach the model as the system turn, are token-accounted, and are trimming-protected.
    func testSkillInstructionsRideTheSystemTurn() {
        let skill = Skill(name: "Translator", emoji: "🌐", summary: "",
                          instructions: "Translate between Chinese and English only.")
        let composed = ChatStore.systemPrompt(base: "BASE", skill: skill)
        let turns = ChatStore.chatTurns(messages: [Message(role: .user, answer: "hello")],
                                        systemPrompt: composed, cap: 8192)
        XCTAssertEqual(turns.first?.role, .system, "the composed prompt is the system turn")
        XCTAssertTrue(turns.first?.content.contains("Translate between Chinese and English only.") ?? false,
                      "the skill's instructions reach the model via the system turn")
    }
}
