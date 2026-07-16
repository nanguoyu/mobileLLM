// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore

/// The `remember` / `recall` tools: save→recall round-trip, the pure ranking (token score + newest-first
/// tie-break + cap), and the empty/blank guard messages. Driven through an in-memory fake store.
final class MemoryToolsTests: XCTestCase {

    func testRememberThenRecallRoundTrips() async {
        let store = FakeMemoryStore()
        let saved = await RememberTool(store: store).execute(argumentsJSON: #"{"text":"The user's cat is named Momo"}"#)
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

    func testRecallEmptyStoreMessage() async {
        let out = await RecallTool(store: FakeMemoryStore()).execute(argumentsJSON: #"{"query":"anything"}"#)
        XCTAssertTrue(out.contains("No saved notes"), out)
    }

    func testRecallNoMatchMessage() async {
        let store = FakeMemoryStore([MemoryFact(text: "likes tea")])
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
        let old = MemoryFact(text: "the dog barks at night", createdAt: Date(timeIntervalSince1970: 1000))
        let mid = MemoryFact(text: "dog and cat live together", createdAt: Date(timeIntervalSince1970: 2000))
        let new = MemoryFact(text: "the cat sleeps", createdAt: Date(timeIntervalSince1970: 3000))
        let ranked = MemoryRanking.rank([old, mid, new], query: "dog cat", limit: 5)
        // mid hits both tokens (score 2) → first; old/new hit one each → newest (new) before old.
        XCTAssertEqual(ranked.map(\.text),
                       ["dog and cat live together", "the cat sleeps", "the dog barks at night"])
    }

    func testRankBlankQueryReturnsNewestFirst() {
        let a = MemoryFact(text: "one", createdAt: Date(timeIntervalSince1970: 1))
        let b = MemoryFact(text: "two", createdAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(MemoryRanking.rank([a, b], query: "   ", limit: 5).map(\.text), ["two", "one"])
    }

    func testRankCapsAtLimit() {
        let facts = (0..<10).map { MemoryFact(text: "note \($0) dog",
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

/// A `MemoryStoring` whose `search` returns something `list` never contains — so a tool that ranks the raw
/// list itself cannot pass.
private actor SentinelSearchStore: MemoryStoring {
    @discardableResult func save(_ text: String, source: MemoryFact.Source) -> MemoryFact {
        MemoryFact(text: text, source: source)
    }
    func list() -> [MemoryFact] { [MemoryFact(text: "the dog barks")] }
    func update(id: String, text: String) {}
    func delete(id: String) {}
    func deleteAll() {}
    func search(_ query: String, limit: Int) -> [MemoryFact] { [MemoryFact(text: "SEARCH_SENTINEL")] }
}
