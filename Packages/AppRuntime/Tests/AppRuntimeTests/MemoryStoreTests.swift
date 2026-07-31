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

    func testSaveAndListPreservesOrder() async throws {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        try await store.save("alpha")
        try await store.save("beta")
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["alpha", "beta"])
    }

    func testPersistsAcrossReinstantiation() async throws {
        let url = dir.appending(component: "m.json")
        let saved = try await MemoryStore(fileURL: url).save("remember me")
        // A brand-new store at the same URL must read the saved fact back from disk.
        let facts = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(facts.map(\.text), ["remember me"])
        XCTAssertEqual(facts.first?.id, saved.id, "the stable id survives persistence")
    }

    func testDeleteRemovesFact() async throws {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        let keep = try await store.save("keep")
        let drop = try await store.save("drop")
        try await store.delete(id: drop.id)
        let reloaded = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(reloaded.map(\.text), ["keep"])
        XCTAssertEqual(reloaded.first?.id, keep.id)
    }

    func testSaveTrimsWhitespace() async throws {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        let fact = try await store.save("   spaced out   ")
        XCTAssertEqual(fact.text, "spaced out")
    }

    // MARK: - Update (the management UI's inline edit)

    func testUpdateReplacesTextKeepingIdDateAndSource() async throws {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        let fact = try await store.save("the dog is named Momo", source: .user)
        try await store.update(id: fact.id, text: "  the dog is named Mochi  ")

        let reloaded = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(reloaded.map(\.text), ["the dog is named Mochi"], "the edit persists, trimmed")
        XCTAssertEqual(reloaded.first?.id, fact.id, "an edit corrects the fact — it doesn't mint a new one")
        XCTAssertEqual(reloaded.first?.createdAt, fact.createdAt, "the date survives, so the list can't reshuffle")
        XCTAssertEqual(reloaded.first?.source, .user, "provenance survives an edit")
    }

    func testUpdateIgnoresUnknownIdAndBlankText() async throws {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        let fact = try await store.save("keep me")
        try await store.update(id: "not-a-real-id", text: "ghost")
        try await store.update(id: fact.id, text: "   ")
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["keep me"], "neither a bad id nor blank text may touch the store")
    }

    // MARK: - Forget everything

    func testDeleteAllEmptiesTheStoreAndPersists() async throws {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        try await store.save("one")
        try await store.save("two")
        try await store.deleteAll()

        let live = await store.list()
        let reloaded = await MemoryStore(fileURL: url).list()
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(reloaded.isEmpty, "forgetting everything survives a relaunch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
                       "an emptied store stays a valid manifest — it is never mistaken for a corrupt one")
    }

    // MARK: - Source tagging

    func testSourceTagsWhoSavedTheFactAndDefaultsToTheModel() async throws {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        try await store.save("the model noticed this")
        try await store.save("the user typed this", source: .user)

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
    func testSearchRanksTheStoresFactsAndCapsAtLimit() async throws {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        for text in ["the dog barks at night", "dog and cat live together", "the cat sleeps", "unrelated note"] {
            try await store.save(text, source: .model)
        }
        let hits = await store.search("dog cat", limit: 2)
        XCTAssertEqual(hits.count, 2, "search caps at the limit")
        XCTAssertEqual(hits.first?.text, "dog and cat live together", "two token hits outrank one")
        XCTAssertFalse(hits.contains { $0.text == "unrelated note" }, "a fact matching nothing is not returned")
    }

    func testSearchWithABlankQueryReturnsTheMostRecent() async throws {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        try await store.save("older")
        try await store.save("newer")
        let hits = await store.search("   ", limit: 1)
        XCTAssertEqual(hits.map(\.text), ["newer"], "a blank query is 'what's freshest', not 'nothing'")
    }

    /// A failed atomic write must reach the caller and leave the cache at the last state that actually
    /// landed. A regular file used as the would-be parent gives us a deterministic, permission-independent
    /// failure injection on both macOS and CI.
    func testFailedWriteThrowsAndDoesNotPublishToCache() async throws {
        let blocker = dir.appending(component: "not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let store = MemoryStore(fileURL: blocker.appending(component: "memory.json"))

        do {
            _ = try await store.save("must not appear")
            XCTFail("save should throw when its parent is a regular file")
        } catch {
            // Expected.
        }

        let cached = await store.list()
        XCTAssertTrue(cached.isEmpty,
                      "a failed write must not become a session-only fact that vanishes on relaunch")
    }

    // MARK: - Concurrent mutation linearization

    func testConcurrentSavesCannotOverwriteEachOthersSnapshots() async throws {
        let hooks = MemoryMutationHooks()
        let store = hookedStore(hooks)

        let first = Task { try await store.save("first") }
        await hooks.waitUntilFirstPersistIsSuspended()
        let second = Task { try await store.save("second") }
        await hooks.waitUntilSecondMutationWasRequested()
        await hooks.resumeFirstPersist()

        _ = try await first.value
        _ = try await second.value
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["first", "second"],
                       "both read-modify-write transactions must observe their predecessor")
    }

    func testConcurrentEquivalentSaveIfAbsentCallsPersistExactlyOneFact() async throws {
        let hooks = MemoryMutationHooks()
        let store = hookedStore(hooks)

        let first = Task {
            try await store.saveIfAbsent("The user likes jasmine tea.", source: .model)
        }
        await hooks.waitUntilFirstPersistIsSuspended()
        let second = Task {
            try await store.saveIfAbsent("The user   LIKES JASMINE TEA!", source: .model)
        }
        await hooks.waitUntilSecondMutationWasRequested()
        await hooks.resumeFirstPersist()

        let outcomes = [try await first.value, try await second.value]
        XCTAssertEqual(outcomes.filter {
            if case .saved = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(outcomes.filter {
            if case .duplicate = $0 { return true }
            return false
        }.count, 1)
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["The user likes jasmine tea."])
    }

    func testDeleteAllRunsAfterAnAlreadyRequestedSaveWithoutResurrectingIt() async throws {
        let hooks = MemoryMutationHooks()
        let store = hookedStore(hooks)

        let save = Task { try await store.save("must stay deleted") }
        await hooks.waitUntilFirstPersistIsSuspended()
        let erase = Task { try await store.deleteAll() }
        await hooks.waitUntilSecondMutationWasRequested()
        await hooks.resumeFirstPersist()

        _ = try await save.value
        try await erase.value
        let facts = await store.list()
        XCTAssertTrue(facts.isEmpty,
                      "an older suspended save must not land after deleteAll and revive its snapshot")
    }

    func testSaveRequestedAfterDeleteAllSurvivesInTheNewEmptyGeneration() async throws {
        let url = dir.appending(component: "m.json")
        _ = try await MemoryStore(fileURL: url).save("old generation")

        let hooks = MemoryMutationHooks()
        let store = hookedStore(hooks, fileURL: url)
        let erase = Task { try await store.deleteAll() }
        await hooks.waitUntilFirstPersistIsSuspended()
        let save = Task { try await store.save("new generation") }
        await hooks.waitUntilSecondMutationWasRequested()
        await hooks.resumeFirstPersist()

        try await erase.value
        _ = try await save.value
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["new generation"],
                       "a mutation ordered after deleteAll must build on the empty committed state")
    }

    func testFailedMutationReleasesTheLaneAndDoesNotPoisonTheNextMutation() async throws {
        let hooks = MemoryMutationHooks(failFirstPersist: true)
        let store = hookedStore(hooks)

        let failed = Task { try await store.save("must not publish") }
        await hooks.waitUntilFirstPersistIsSuspended()
        let succeeding = Task { try await store.save("durable successor") }
        await hooks.waitUntilSecondMutationWasRequested()
        await hooks.resumeFirstPersist()

        do {
            _ = try await failed.value
            XCTFail("the injected first persistence attempt must fail")
        } catch {
            // Expected.
        }
        _ = try await succeeding.value

        let live = await store.list()
        let reloaded = await MemoryStore(fileURL: dir.appending(component: "m.json")).list()
        XCTAssertEqual(live.map(\.text), ["durable successor"])
        XCTAssertEqual(reloaded.map(\.text), ["durable successor"],
                       "the next queued mutation must start from the last durable snapshot")
    }

    func testSlowInitialLoadCannotOverwriteACompletedDeleteAll() async throws {
        let url = dir.appending(component: "m.json")
        _ = try await MemoryStore(fileURL: url).save("stale disk snapshot")
        let loadReached = AsyncLatch()
        let releaseLoad = AsyncLatch()
        let store = MemoryStore(
            fileURL: url,
            mutationRequested: nil,
            beforePersist: nil,
            afterInitialLoad: {
                await loadReached.signal()
                await releaseLoad.wait()
            }
        )

        let staleRead = Task { await store.list() }
        await loadReached.wait()
        try await store.deleteAll()
        await releaseLoad.signal()

        let observed = await staleRead.value
        XCTAssertTrue(observed.isEmpty,
                      "a load begun before deleteAll must not republish its obsolete disk snapshot")
        let current = await store.list()
        XCTAssertTrue(current.isEmpty)
    }

    private func hookedStore(_ hooks: MemoryMutationHooks,
                             fileURL: URL? = nil) -> MemoryStore {
        MemoryStore(
            fileURL: fileURL ?? dir.appending(component: "m.json"),
            mutationRequested: { await hooks.mutationWasRequested() },
            beforePersist: { try await hooks.beforePersist() },
            afterInitialLoad: nil
        )
    }
}

private actor AsyncLatch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct InjectedMemoryMutationFailure: Error {}

/// Makes the first durable write wait while a second mutation reaches the store. The final assertions are
/// therefore deterministic: without an explicit mutation lane the second operation writes first, then the
/// released stale first snapshot overwrites it.
private actor MemoryMutationHooks {
    private let firstPersistReached = AsyncLatch()
    private let secondMutationRequested = AsyncLatch()
    private let releaseFirstPersist = AsyncLatch()
    private let failFirstPersist: Bool
    private var requestCount = 0
    private var persistCount = 0

    init(failFirstPersist: Bool = false) {
        self.failFirstPersist = failFirstPersist
    }

    func mutationWasRequested() async {
        requestCount += 1
        if requestCount == 2 { await secondMutationRequested.signal() }
    }

    func beforePersist() async throws {
        persistCount += 1
        guard persistCount == 1 else { return }
        await firstPersistReached.signal()
        await releaseFirstPersist.wait()
        if failFirstPersist { throw InjectedMemoryMutationFailure() }
    }

    func waitUntilFirstPersistIsSuspended() async { await firstPersistReached.wait() }
    func waitUntilSecondMutationWasRequested() async { await secondMutationRequested.wait() }
    func resumeFirstPersist() async { await releaseFirstPersist.signal() }
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
