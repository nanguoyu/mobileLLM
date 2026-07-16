// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

/// The durable `MemoryStore`: save→list round-trip, persistence across re-instantiation (the tool's whole
/// point — facts survive an app relaunch), the CRUD the management UI drives (update / delete / forget
/// everything), ranked search, source tagging, and whitespace trimming. Backed by a temp file so the suite
/// stays hermetic.
final class MemoryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(component: "MemoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveAndListPreservesOrder() async {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        await store.save("alpha")
        await store.save("beta")
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["alpha", "beta"])
    }

    func testPersistsAcrossReinstantiation() async {
        let url = dir.appending(component: "m.json")
        let saved = await MemoryStore(fileURL: url).save("remember me")
        // A brand-new store at the same URL must read the saved fact back from disk.
        let facts = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(facts.map(\.text), ["remember me"])
        XCTAssertEqual(facts.first?.id, saved.id, "the stable id survives persistence")
    }

    func testDeleteRemovesFact() async {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        let keep = await store.save("keep")
        let drop = await store.save("drop")
        await store.delete(id: drop.id)
        let reloaded = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(reloaded.map(\.text), ["keep"])
        XCTAssertEqual(reloaded.first?.id, keep.id)
    }

    func testSaveTrimsWhitespace() async {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        let fact = await store.save("   spaced out   ")
        XCTAssertEqual(fact.text, "spaced out")
    }

    // MARK: - Update (the management UI's inline edit)

    func testUpdateReplacesTextKeepingIdDateAndSource() async {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        let fact = await store.save("the dog is named Momo", source: .user)
        await store.update(id: fact.id, text: "  the dog is named Mochi  ")

        let reloaded = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(reloaded.map(\.text), ["the dog is named Mochi"], "the edit persists, trimmed")
        XCTAssertEqual(reloaded.first?.id, fact.id, "an edit corrects the fact — it doesn't mint a new one")
        XCTAssertEqual(reloaded.first?.createdAt, fact.createdAt, "the date survives, so the list can't reshuffle")
        XCTAssertEqual(reloaded.first?.source, .user, "provenance survives an edit")
    }

    func testUpdateIgnoresUnknownIdAndBlankText() async {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        let fact = await store.save("keep me")
        await store.update(id: "not-a-real-id", text: "ghost")
        await store.update(id: fact.id, text: "   ")
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["keep me"], "neither a bad id nor blank text may touch the store")
    }

    // MARK: - Forget everything

    func testDeleteAllEmptiesTheStoreAndPersists() async {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        await store.save("one")
        await store.save("two")
        await store.deleteAll()

        let live = await store.list()
        let reloaded = await MemoryStore(fileURL: url).list()
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(reloaded.isEmpty, "forgetting everything survives a relaunch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
                       "an emptied store stays a valid manifest — it is never mistaken for a corrupt one")
    }

    // MARK: - Source tagging

    func testSourceTagsWhoSavedTheFactAndDefaultsToTheModel() async {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        await store.save("the model noticed this")
        await store.save("the user typed this", source: .user)

        let reloaded = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(reloaded.map(\.source), [.model, .user],
                       "the tool's saves are the model's; the UI's are the user's — and both survive a relaunch")
    }

    /// The upgrade path: facts written before `source` existed must still load. `DurableStore` skips a
    /// record it can't decode, so a strict decoder here would silently forget everything already saved.
    func testLegacyFactsWithoutASourceKeyDecodeAsModelSaved() async throws {
        let url = dir.appending(component: "m.json")
        let legacy = """
        {"records":[{"createdAt":761000000,"id":"legacy-1","text":"saved before source existed"}],"version":1}
        """
        try Data(legacy.utf8).write(to: url)

        let facts = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(facts.map(\.text), ["saved before source existed"], "a pre-source fact is not dropped")
        XCTAssertEqual(facts.first?.source, .model, "the tool was the only writer back then")
    }

    // MARK: - Search

    /// `MemoryRanking` itself is unit-tested next to the tools; this pins that the STORE ranks its own
    /// contents through it (score first, then the cap) rather than handing back insertion order.
    func testSearchRanksTheStoresFactsAndCapsAtLimit() async {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        for text in ["the dog barks at night", "dog and cat live together", "the cat sleeps", "unrelated note"] {
            await store.save(text, source: .model)
        }
        let hits = await store.search("dog cat", limit: 2)
        XCTAssertEqual(hits.count, 2, "search caps at the limit")
        XCTAssertEqual(hits.first?.text, "dog and cat live together", "two token hits outrank one")
        XCTAssertFalse(hits.contains { $0.text == "unrelated note" }, "a fact matching nothing is not returned")
    }

    func testSearchWithABlankQueryReturnsTheMostRecent() async {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        await store.save("older")
        await store.save("newer")
        let hits = await store.search("   ", limit: 1)
        XCTAssertEqual(hits.map(\.text), ["newer"], "a blank query is 'what's freshest', not 'nothing'")
    }
}

/// Query tokenization — pinned because getting it wrong fails silently. The ranker drops any fact scoring
/// zero, so a tokenizer that can't find word boundaries doesn't merely reorder results, it returns NONE:
/// `memoryBlock` goes nil and the model is never told what it knows.
///
/// That is what shipped. Splitting on non-alphanumerics assumes spaces separate words; every CJK character
/// is `isLetter`, so a whole Chinese question came out as ONE token and `contains` it against a fact was
/// never true. Memory worked in English and was dead in Chinese — in the half of the feature whose entire
/// point is reaching the model without the model having to ask for it.
final class MemoryRankingTokenizationTests: XCTestCase {

    private func fact(_ text: String, _ t: TimeInterval = 0) -> MemoryFact {
        MemoryFact(text: text, createdAt: Date(timeIntervalSince1970: t))
    }

    /// The regression in the user's own words: "我叫什么名字？" against a fact saved in Chinese.
    func testAChineseQuestionFindsAChineseFact() {
        let name = fact("用户的名字是 Dong", 2)
        let other = fact("用户喜欢喝茶", 1)
        let hits = MemoryRanking.rank([name, other], query: "我叫什么名字？", limit: 5)
        XCTAssertTrue(hits.contains { $0.text == "用户的名字是 Dong" },
                      "a Chinese question must reach a Chinese fact — got \(hits.map(\.text))")
    }

    /// The tokenizer has to see words inside a space-less script at all. One token for a whole sentence is
    /// the shipped bug's signature.
    func testCJKIsSegmentedIntoWordsNotOneToken() {
        XCTAssertEqual(MemoryRanking.tokenize("我叫什么名字"), ["我", "叫", "什么", "名字"])
        XCTAssertEqual(MemoryRanking.tokenize("こんにちは世界"), ["こんにちは", "世界"])
    }

    /// Mixed CJK + Latin is the normal case here (product names, code, brands) — both sides must survive.
    func testMixedScriptQueryTokenizesBothSides() {
        XCTAssertEqual(MemoryRanking.tokenize("我用 Swift 写 iOS app"),
                       ["我", "用", "swift", "写", "ios", "app"])
    }

    /// English keeps working exactly as before — punctuation dropped, case folded.
    func testEnglishStillTokenizesOnWords() {
        XCTAssertEqual(MemoryRanking.tokenize("What is my dog's name?"), ["what", "is", "my", "dog's", "name"])
    }

    /// Scoring still ranks by hit count then recency, now in Chinese too.
    func testChineseRanksByHitCountThenRecency() {
        let both = fact("用户的猫和狗都住在南京", 1)
        let one = fact("用户有一只猫", 3)
        let none = fact("用户是工程师", 2)
        let hits = MemoryRanking.rank([both, one, none], query: "猫和狗", limit: 5)
        XCTAssertEqual(hits.map(\.text), ["用户的猫和狗都住在南京", "用户有一只猫"],
                       "more token hits win; the fact matching nothing is excluded")
    }

    /// The honest limit, pinned so it isn't mistaken for a regression later: matching is word overlap, so a
    /// fact saved in one language is NOT reachable from a question in another. `RememberTool` asks the model
    /// to save in the user's language — that, not the tokenizer, is what keeps both sides in one vocabulary.
    func testCrossLanguageIsNotMatched() {
        let english = fact("The user's name is Dong")
        XCTAssertTrue(MemoryRanking.rank([english], query: "我叫什么名字？", limit: 5).isEmpty)
    }
}
