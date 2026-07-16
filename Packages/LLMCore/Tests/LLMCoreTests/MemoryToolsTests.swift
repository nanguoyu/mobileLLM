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

    func testRankScoresByTokenHitsThenRecency() {
        let old = MemoryFact(text: "the dog barks at night", createdAt: Date(timeIntervalSince1970: 1000))
        let mid = MemoryFact(text: "dog and cat live together", createdAt: Date(timeIntervalSince1970: 2000))
        let new = MemoryFact(text: "the cat sleeps", createdAt: Date(timeIntervalSince1970: 3000))
        let ranked = RecallTool.rank([old, mid, new], query: "dog cat", limit: 5)
        // mid hits both tokens (score 2) → first; old/new hit one each → newest (new) before old.
        XCTAssertEqual(ranked.map(\.text),
                       ["dog and cat live together", "the cat sleeps", "the dog barks at night"])
    }

    func testRankBlankQueryReturnsNewestFirst() {
        let a = MemoryFact(text: "one", createdAt: Date(timeIntervalSince1970: 1))
        let b = MemoryFact(text: "two", createdAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(RecallTool.rank([a, b], query: "   ", limit: 5).map(\.text), ["two", "one"])
    }

    func testRankCapsAtLimit() {
        let facts = (0..<10).map { MemoryFact(text: "note \($0) dog",
                                              createdAt: Date(timeIntervalSince1970: Double($0))) }
        XCTAssertEqual(RecallTool.rank(facts, query: "dog", limit: 5).count, 5)
    }
}
