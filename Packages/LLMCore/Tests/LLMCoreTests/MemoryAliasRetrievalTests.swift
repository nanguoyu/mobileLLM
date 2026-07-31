// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore
import AppRuntime

/// Notes are stored in canonical English (measured: a 2B model saves 9/10 that way versus 7/10 storing the
/// user's own wording). But retrieval is word overlap, so an English note scores ZERO against the Chinese
/// question that should find it — measured 0/7 on a realistic store, which silently demoted memory to "the
/// five newest notes" for anyone not asking in English. `ToolLoop` therefore attaches the originating user
/// turn as a search alias. These pin both halves: the English note is what the model reads, the user's own
/// words are what the query matches.
final class MemoryAliasRetrievalTests: XCTestCase {

    private func fact(_ english: String, _ original: String?, _ t: TimeInterval) -> MemoryFact {
        MemoryFact(text: english, createdAt: Date(timeIntervalSince1970: t),
                   source: .model, sourceText: original)
    }

    /// More than the 5-fact injection cap, so the "no match → newest five" fallback cannot mask a miss.
    private var store: [MemoryFact] {
        [
            fact("The user has an orange cat named Momo", "我养了一只叫Momo的橘猫", 1),
            fact("The user is allergic to peanuts", "我对花生过敏，所以那家店我去不了", 2),
            fact("The user is a backend engineer at a medical imaging company",
                 "我在一家做医疗影像的公司当后端工程师", 3),
            fact("The user drives a blue Model 3", "我开的是一辆蓝色的 Model 3", 4),
            fact("The user goes hiking on weekends", "我周末基本都在爬山", 5),
            fact("The user has a five-year-old daughter", "我有个五岁的女儿", 6),
            fact("The user lives in Nanjing", "我住在南京", 7),
            fact("The user is vegetarian", "I'm vegetarian, by the way", 8),
        ]
    }

    private func topHit(_ query: String) -> MemoryFact? {
        MemoryRanking.rank(store, query: query, limit: 5).first
    }

    func testAChineseQuestionFindsItsOwnEnglishNote() {
        let cases: [(q: String, expect: String)] = [
            ("我的猫叫什么名字？", "Momo"),
            ("我对什么过敏？", "peanuts"),
            ("我开什么车？", "Model 3"),
            ("我女儿多大了？", "five-year-old"),
            ("我周末做什么？", "hiking"),
        ]
        for c in cases {
            let ranked = MemoryRanking.rank(store, query: c.q, limit: 5)
            XCTAssertTrue(ranked.contains { $0.text.contains(c.expect) },
                          "“\(c.q)” must reach its English note — got \(ranked.map(\.text))")
        }
    }

    /// The alias is a ranking key only. What the model is shown is always the canonical English note.
    func testTheModelStillReadsTheEnglishNote() {
        let hit = topHit("我住在哪里？")
        XCTAssertEqual(hit?.text, "The user lives in Nanjing")
    }

    /// English questions must keep working exactly as before — the alias adds a lane, it doesn't replace one.
    func testEnglishQuestionsStillMatchTheEnglishNote() {
        XCTAssertTrue(topHit("where do I live")?.text.contains("Nanjing") ?? false)
        XCTAssertTrue(topHit("what am I allergic to")?.text.contains("peanuts") ?? false)
    }

    /// Notes saved before aliases existed rank on their text alone — no crash, no behavior change.
    func testNotesWithoutAnAliasStillRank() {
        let legacy = [fact("The user lives in Nanjing", nil, 1)]
        XCTAssertEqual(MemoryRanking.rank(legacy, query: "where do I live", limit: 5).count, 1)
        XCTAssertTrue(MemoryRanking.rank(legacy, query: "我住在哪里？", limit: 5).isEmpty,
                      "a legacy English note genuinely cannot be matched in Chinese — that is the gap "
                      + "the alias closes for NEW notes, and it must not be papered over here")
    }

    /// A bilingual record must not outrank a single-language one merely for having more text to match.
    func testTheAliasDoesNotInflateScore() {
        let bilingual = fact("The user drives a blue Model 3", "我开的是一辆蓝色的 Model 3", 1)
        let englishOnly = fact("The user drives a blue Model 3 every day", nil, 2)
        let ranked = MemoryRanking.rank([bilingual, englishOnly], query: "blue Model 3", limit: 5)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.text, "The user drives a blue Model 3 every day",
                       "equal scores break newest-first; the alias must not add score for the same words")
    }

    /// `ToolLoop` is what attaches the alias — pinned here so the wiring can't be dropped silently.
    func testCanonicalizedCallCarriesTheUsersOwnSentence() throws {
        let raw = ToolCall(name: "remember",
                           argumentsJSON: #"{"text":"The user lives in Nanjing"}"#)
        let normalized = try XCTUnwrap(
            RememberTool.canonicalizedCall(raw, originalUserText: "我住在南京"))
        XCTAssertEqual(normalized.arg("text"), "The user lives in Nanjing")
        XCTAssertEqual(normalized.arg("original"), "我住在南京")
        // Without a user turn the call is byte-identical to what shipped.
        let bare = try XCTUnwrap(RememberTool.canonicalizedCall(raw))
        XCTAssertNil(bare.arg("original"))
    }
}
