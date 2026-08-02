// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore

/// The `remember` / `recall` tools: save→recall round-trip, the pure ranking (token score + newest-first
/// tie-break + cap), and the empty/blank guard messages. Driven through an in-memory fake store.
final class MemoryToolsTests: XCTestCase {

    func testRememberThenRecallRoundTrips() async {
        let store = FakeMemoryStore()
        let saved = await RememberTool(store: store).execute(argumentsJSON: #"{"text":"The user has a cat named Momo"}"#)
        XCTAssertTrue(saved.contains("Saved"), saved)
        let recalled = await RecallTool(store: store).execute(argumentsJSON: #"{"query":"cat"}"#)
        XCTAssertTrue(recalled.contains("Momo"), recalled)
    }

    /// What the tool saves is the MODEL's note: the memory screen labels it that way, so what the assistant
    /// decided to write down stays distinguishable from what the user typed themselves.
    func testRememberTagsTheFactAsModelSaved() async {
        let store = FakeMemoryStore()
        _ = await RememberTool(store: store).execute(argumentsJSON: #"{"text":"The user bikes to work"}"#)
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.source), [.model])
    }

    func testRememberRejectsNonCanonicalTextWithoutWriting() async {
        let store = FakeMemoryStore()
        let output = await RememberTool(store: store).execute(argumentsJSON: #"{"text":"用户叫Dong"}"#)
        let facts = await store.list()
        XCTAssertTrue(output.hasPrefix("Error:"), output)
        XCTAssertTrue(output.contains(#""The user ""#), output)
        XCTAssertTrue(facts.isEmpty)
    }

    func testRememberRejectsCJKProseHiddenBehindTheCanonicalPrefix() async {
        let store = FakeMemoryStore()
        let tool = RememberTool(store: store)

        for text in [
            "The user 用户叫 Dong",
            "The user says 用户叫董王",
            "The user 使用 Swift 工作",
            "The user is named 用户叫Dong.",
            "The user is named 王东住在北京.",
        ] {
            let encoded = try! JSONSerialization.data(withJSONObject: ["text": text])
            let output = await tool.execute(argumentsJSON: String(decoding: encoded, as: UTF8.self))
            XCTAssertTrue(output.hasPrefix("Error:"), "\(text) should be rejected: \(output)")
        }
        let facts = await store.list()
        XCTAssertTrue(facts.isEmpty)
    }

    /// Both real device models used this natural possessive form. It is valid English, so rejecting it
    /// because "user's" was not in a finite predicate allowlist prevented the remember tool from running.
    func testRememberNormalizesNaturalPossessiveEnglishBeforeStorage() async {
        let store = FakeMemoryStore()
        let tool = RememberTool(store: store)

        let straight = await tool.execute(
            argumentsJSON: #"{"text":"The user's temporary device-test name is QuartzBonsai52039."}"#
        )
        let curly = await tool.execute(
            argumentsJSON: #"{"text":"The user’s preferred editor is Nova."}"#
        )

        XCTAssertEqual(straight, "Saved to memory.")
        XCTAssertEqual(curly, "Saved to memory.")
        let facts = await store.list()
        XCTAssertEqual(
            facts.map(\.text),
            [
                "The user says their temporary device-test name is QuartzBonsai52039.",
                "The user says their preferred editor is Nova.",
            ]
        )
    }

    /// Canonicalization must not encode an ever-growing list of verbs. Any safe English predicate remains
    /// eligible; the tool prompt supplies the language contract and the boundary rejects script leakage.
    func testRememberAcceptsEnglishPredicateOutsideTheOldVerbAllowlist() async {
        let store = FakeMemoryStore()
        let output = await RememberTool(store: store).execute(
            argumentsJSON: #"{"text":"The user commutes by tram."}"#
        )

        XCTAssertEqual(output, "Saved to memory.")
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["The user commutes by tram."])
    }

    func testRememberAllowsCJKProperNameInsideEnglishScaffold() async {
        let store = FakeMemoryStore()
        let output = await RememberTool(store: store)
            .execute(argumentsJSON: #"{"text":"The user is named 王东."}"#)

        XCTAssertEqual(output, "Saved to memory.")
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["The user is named 王东."])
    }

    func testRememberSuccessDoesNotEchoTheCanonicalFact() async {
        let store = FakeMemoryStore()
        let output = await RememberTool(store: store)
            .execute(argumentsJSON: #"{"text":"The user is named Dong."}"#)
        XCTAssertEqual(output, "Saved to memory.")
        XCTAssertFalse(output.contains("Dong"))
    }

    func testRememberExactDuplicateDoesNotGrowStore() async {
        let store = FakeMemoryStore()
        let tool = RememberTool(store: store)

        let firstOutput = await tool.execute(
            argumentsJSON: #"{"text":"The user likes jasmine tea."}"#
        )
        let duplicateOutput = await tool.execute(
            argumentsJSON: #"{"text":"The user likes jasmine tea."}"#
        )
        let storedTexts = await store.list().map(\.text)

        XCTAssertEqual(firstOutput, "Saved to memory.")
        XCTAssertEqual(duplicateOutput, "Already in memory.")
        XCTAssertEqual(storedTexts, ["The user likes jasmine tea."])
    }

    func testRememberNormalizesSurroundingWhitespaceBeforeDeduplication() async {
        let store = FakeMemoryStore()
        let tool = RememberTool(store: store)

        let spacedOutput = await tool.execute(
            argumentsJSON: #"{"text":"  \nThe user lives in Vienna.\t  "}"#
        )
        let canonicalOutput = await tool.execute(
            argumentsJSON: #"{"text":"The user lives in Vienna."}"#
        )
        let storedTexts = await store.list().map(\.text)

        XCTAssertEqual(spacedOutput, "Saved to memory.")
        XCTAssertEqual(canonicalOutput, "Already in memory.")
        XCTAssertEqual(storedTexts, ["The user lives in Vienna."])
    }

    func testRememberDeduplicatesCaseWhitespaceAndPunctuation() async {
        let store = FakeMemoryStore()
        let tool = RememberTool(store: store)
        let first = await tool.execute(
            argumentsJSON: #"{"text":"The user likes jasmine tea."}"#
        )
        let equivalent = await tool.execute(
            argumentsJSON: #"{"text":"The user   LIKES JASMINE TEA!"}"#
        )

        XCTAssertEqual(first, "Saved to memory.")
        XCTAssertEqual(equivalent, "Already in memory.")
        let facts = await store.list()
        XCTAssertEqual(facts.count, 1)
    }

    func testConcurrentEquivalentRememberCallsAreOneAtomicTransaction() async {
        let store = FakeMemoryStore()
        let tool = RememberTool(store: store)

        let outputs = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for index in 0..<24 {
                let text = index.isMultiple(of: 2)
                    ? "The user likes jasmine tea."
                    : "The user   LIKES JASMINE TEA!"
                group.addTask {
                    let encoded = try! JSONSerialization.data(withJSONObject: ["text": text])
                    return await tool.execute(argumentsJSON: String(decoding: encoded, as: UTF8.self))
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(outputs.filter { $0 == "Saved to memory." }.count, 1)
        XCTAssertEqual(outputs.filter { $0 == "Already in memory." }.count, 23)
        let facts = await store.list()
        XCTAssertEqual(facts.count, 1)
    }

    func testRememberReportsDurableWriteFailureInsteadOfClaimingSuccess() async {
        let output = await RememberTool(store: FailingMemoryStore())
            .execute(argumentsJSON: #"{"text":"The user likes tea."}"#)
        XCTAssertTrue(output.hasPrefix("Error:"), output)
        XCTAssertTrue(output.contains("could not be saved"), output)
    }

    func testRecallEmptyStoreMessage() async {
        let out = await RecallTool(store: FakeMemoryStore()).execute(argumentsJSON: #"{"query":"anything"}"#)
        XCTAssertTrue(out.contains("No saved notes"), out)
    }

    func testRecallNoMatchMessage() async {
        let store = FakeMemoryStore([MemoryFact(text: "The user likes tea.")])
        let out = await RecallTool(store: store).execute(argumentsJSON: #"{"query":"spaceship"}"#)
        XCTAssertTrue(out.contains("No saved notes match"), out)
    }

    func testRememberRejectsBlank() async {
        let out = await RememberTool(store: FakeMemoryStore()).execute(argumentsJSON: #"{"text":"   "}"#)
        XCTAssertTrue(out.contains("missing"), out)
    }

    // MARK: Pure ranking
    //
    // The scoring moved to `AppRuntime.MemoryRanking` when the store and the prompt injector needed the
    // same answers as the tool; these still pin the behavior `recall` depends on.

    func testRankScoresByTokenHitsThenRecency() {
        let old = MemoryFact(text: "The user says the dog barks at night.",
                             createdAt: Date(timeIntervalSince1970: 1000))
        let mid = MemoryFact(text: "The user says the dog and cat live together.",
                             createdAt: Date(timeIntervalSince1970: 2000))
        let new = MemoryFact(text: "The user says the cat sleeps.",
                             createdAt: Date(timeIntervalSince1970: 3000))
        let ranked = MemoryRanking.rank([old, mid, new], query: "dog cat", limit: 5)
        // mid hits both tokens (score 2) → first; old/new hit one each → newest (new) before old.
        XCTAssertEqual(ranked.map(\.text),
                       [
                           "The user says the dog and cat live together.",
                           "The user says the cat sleeps.",
                           "The user says the dog barks at night.",
                       ])
    }

    func testRankBlankQueryReturnsNewestFirst() {
        let a = MemoryFact(text: "The user likes one thing.", createdAt: Date(timeIntervalSince1970: 1))
        let b = MemoryFact(text: "The user likes two things.", createdAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(
            MemoryRanking.rank([a, b], query: "   ", limit: 5).map(\.text),
            ["The user likes two things.", "The user likes one thing."]
        )
    }

    func testRankCapsAtLimit() {
        let facts = (0..<10).map { MemoryFact(text: "The user has note \($0) about a dog.",
                                              createdAt: Date(timeIntervalSince1970: Double($0))) }
        XCTAssertEqual(MemoryRanking.rank(facts, query: "dog", limit: 5).count, 5)
    }

    /// `recall` must route through the store's `search`, not re-rank a raw `list()` of its own: the tool,
    /// the memory screen, and the auto-injected prompt block agree on relevance only while there is one
    /// ranker. A store whose search is deliberately wrong proves the tool is asking it.
    func testRecallDelegatesRankingToTheStoresSearch() async {
        let store = SentinelSearchStore()
        let out = await RecallTool(store: store).execute(argumentsJSON: #"{"query":"dog"}"#)
        XCTAssertTrue(out.contains("SEARCH_SENTINEL"), out)
    }
}

private actor FailingMemoryStore: MemoryStoring {
    private struct WriteFailure: LocalizedError {
        var errorDescription: String? { "Injected disk failure" }
    }

    func save(_ text: String, source: MemoryFact.Source) throws -> MemoryFact {
        throw WriteFailure()
    }
    func saveIfAbsent(_ text: String, source: MemoryFact.Source) throws -> MemorySaveResult {
        throw WriteFailure()
    }
    func list() -> [MemoryFact] { [] }
    func update(id: String, text: String) throws { throw WriteFailure() }
    func delete(id: String) throws { throw WriteFailure() }
    func deleteAll() throws { throw WriteFailure() }
}

/// A `MemoryStoring` whose `search` returns something `list` never contains — so a tool that ranks the raw
/// list itself cannot pass.
private actor SentinelSearchStore: MemoryStoring {
    @discardableResult func save(_ text: String, source: MemoryFact.Source) -> MemoryFact {
        MemoryFact(text: text, source: source)
    }
    @discardableResult func saveIfAbsent(_ text: String,
                                         source: MemoryFact.Source) -> MemorySaveResult {
        .saved(MemoryFact(text: text, source: source))
    }
    func list() -> [MemoryFact] { [MemoryFact(text: "The user says the dog barks.")] }
    func update(id: String, text: String) {}
    func delete(id: String) {}
    func deleteAll() {}
    func search(_ query: String, limit: Int) -> [MemoryFact] {
        [MemoryFact(text: "The user has SEARCH_SENTINEL data.")]
    }
}
