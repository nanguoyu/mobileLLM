// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore
import AppRuntime

/// The memory switch, which has to be reachable from the screen that always reaches memory.
///
/// The trap this pins: auto-injection is deliberately NOT gated on the master tools switch. The switch
/// therefore also lives on the Memory screen, where saved facts are visible and controllable regardless
/// of tool-call authorization.
@MainActor
final class MemorySwitchTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "MemorySwitchTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeSettings() -> AppSettings { AppSettings(defaults: defaults) }

    /// With tool calls off, memory remains independently switchable. A get-only `memoryEnabled` (the shape
    /// this shipped as) makes this contract impossible to express.
    func testMemoryStaysSwitchableWithToolsOff() {
        let settings = makeSettings()
        settings.toolsEnabled = false
        XCTAssertTrue(settings.memoryEnabled, "memory is on by default")

        settings.memoryEnabled = false
        XCTAssertFalse(settings.memoryEnabled,
                       "the tools master switch must not strand the memory switch out of reach")

        settings.memoryEnabled = true
        XCTAssertTrue(settings.memoryEnabled)
    }

    /// Off moves `remember` with `recall` — the same pair the Manage-tools row moves. Leaving `remember`
    /// on would keep writing notes the model can never read.
    func testSwitchingOffDisablesBothMemoryTools() {
        let settings = makeSettings()
        settings.memoryEnabled = false
        XCTAssertTrue(settings.disabledBuiltInTools.contains(ToolID.recall.rawValue))
        XCTAssertTrue(settings.disabledBuiltInTools.contains(ToolID.remember.rawValue))
        XCTAssertFalse(settings.builtInToolConfig.enabled.contains(.recall))
        XCTAssertFalse(settings.builtInToolConfig.enabled.contains(.remember))

        settings.memoryEnabled = true
        XCTAssertTrue(settings.builtInToolConfig.enabled.contains(.recall))
        XCTAssertTrue(settings.builtInToolConfig.enabled.contains(.remember))
    }

    /// The switch touches memory and nothing else — turning memory off must not cost you your calculator.
    func testSwitchingMemoryLeavesOtherToolsAlone() {
        let settings = makeSettings()
        settings.disabledBuiltInTools = [ToolID.webSearch.rawValue]
        settings.memoryEnabled = false
        settings.memoryEnabled = true
        XCTAssertEqual(settings.disabledBuiltInTools, [ToolID.webSearch.rawValue],
                       "an unrelated disabled tool survives a memory round-trip")
        XCTAssertTrue(settings.builtInToolConfig.enabled.contains(.calculator))
    }

    /// It's one setting whichever surface writes it, so it has to persist like one.
    func testTheSwitchSurvivesARelaunch() {
        makeSettings().memoryEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).memoryEnabled)
    }
}

/// `MemoryBook` — the memory screen's main-actor mirror over the durable store. What matters here is that
/// the mirror never lies: every edit lands in the store AND on screen, a fact the model saved behind the
/// UI's back shows up on refresh, and the ordering is the one the list renders.
@MainActor
final class MemoryBookTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(component: "membook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeBook() -> (book: MemoryBook, store: MemoryStore) {
        let store = MemoryStore(fileURL: dir.appending(component: "memory.json"))
        return (MemoryBook(store: store), store)
    }

    func testAddTagsTheFactAsTheUsersAndShowsItNewestFirst() async throws {
        let (book, store) = makeBook()
        try await book.add("first")
        try await book.add("second")

        XCTAssertEqual(book.facts.map(\.text), ["second", "first"], "the list reads newest first")
        XCTAssertEqual(book.facts.map(\.source), [.user, .user], "what you type is yours, not the model's")
        let persisted = await store.list()
        XCTAssertEqual(persisted.map(\.text), ["first", "second"], "and it reached the durable store")
    }

    func testAddIgnoresBlankTextAndTrims() async throws {
        let (book, _) = makeBook()
        try await book.add("   ")
        XCTAssertTrue(book.isEmpty, "a blank memory is not a memory")
        try await book.add("  spaced out  ")
        XCTAssertEqual(book.facts.map(\.text), ["spaced out"])
    }

    func testUpdateEditsInPlaceOnScreenAndOnDisk() async throws {
        let (book, store) = makeBook()
        try await book.add("the dog is named Momo")
        let id = book.facts[0].id
        try await book.update(id: id, text: "the dog is named Mochi")

        XCTAssertEqual(book.facts.map(\.text), ["the dog is named Mochi"])
        XCTAssertEqual(book.facts[0].id, id, "the row keeps its identity through an edit")
        let persisted = await store.list()
        XCTAssertEqual(persisted.map(\.text), ["the dog is named Mochi"])
    }

    func testDeleteRemovesFromBothTheMirrorAndTheStore() async throws {
        let (book, store) = makeBook()
        try await book.add("keep")
        try await book.add("drop")
        try await book.delete(id: book.facts[0].id)   // newest first ⇒ [0] is "drop"

        XCTAssertEqual(book.facts.map(\.text), ["keep"])
        let persisted = await store.list()
        XCTAssertEqual(persisted.map(\.text), ["keep"], "a deleted memory doesn't linger on disk")
    }

    func testDeleteAllForgetsEverything() async throws {
        let (book, store) = makeBook()
        try await book.add("one")
        try await book.add("two")
        try await book.deleteAll()

        XCTAssertTrue(book.isEmpty)
        let persisted = await store.list()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testWriteFailureReachesUIAndDoesNotChangeMirror() async throws {
        let blocker = dir.appending(component: "not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let book = MemoryBook(store: MemoryStore(fileURL: blocker.appending(component: "memory.json")))

        do {
            try await book.add("must not appear")
            XCTFail("the UI-facing write should throw")
        } catch {
            // Expected.
        }
        XCTAssertTrue(book.facts.isEmpty)
    }

    /// The tool writes to the store, not the book. The screen has to be able to catch up, or a fact the
    /// model just saved would be invisible on the very screen that exists to show it.
    func testRefreshPicksUpAFactSavedByTheToolBehindTheUIsBack() async throws {
        let (book, store) = makeBook()
        try await book.add("typed by the user")
        try await store.save("saved by the model", source: .model)

        XCTAssertEqual(book.facts.count, 1, "the mirror hasn't been told yet")
        await book.refresh()
        XCTAssertEqual(book.facts.map(\.text), ["saved by the model", "typed by the user"])
        XCTAssertEqual(book.facts.map(\.source), [.model, .user], "both provenances survive the round trip")
        XCTAssertEqual(book.userAuthoredCount, 1)
    }

    // MARK: - The Settings row's summary

    func testSummaryReportsCountsAndWhoWroteThem() async throws {
        let (book, _) = makeBook()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "membook-\(UUID().uuidString)")!)

        XCTAssertEqual(MemoryView.summary(book: book, settings: settings), "Nothing saved yet")
        try await book.add("mine")
        XCTAssertEqual(MemoryView.summary(book: book, settings: settings), "1 memory · 1 added by you")
        try await book.store.save("the model's", source: .model)
        await book.refresh()
        XCTAssertEqual(MemoryView.summary(book: book, settings: settings), "2 memories · 1 added by you")
    }

    /// A count alone would imply the model is using these; when memory is switched off in Choose tools the
    /// row has to say so.
    func testSummarySaysOffWhenMemoryIsDisabled() async throws {
        let (book, _) = makeBook()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "membook-\(UUID().uuidString)")!)
        settings.disabledBuiltInTools.formUnion([ToolID.recall.rawValue, ToolID.remember.rawValue])

        XCTAssertEqual(MemoryView.summary(book: book, settings: settings), "Off")
        try await book.add("mine")
        XCTAssertEqual(MemoryView.summary(book: book, settings: settings), "Off · 1 saved")
    }

    // MARK: - Container wiring

    /// The memory screen and the chat must share ONE book over ONE store. Two stores would be the exact
    /// failure this screen exists to prevent: the user curating a list the model never reads.
    func testContainerGivesTheScreenAndTheChatTheSameBook() async throws {
        let container = AppContainer(
            engine: MockLLMEngine(),
            downloadBase: dir.appending(component: "downloads"),
            downloader: { _, _, _, p in p(1) },
            settings: AppSettings(defaults: UserDefaults(suiteName: "membook-\(UUID().uuidString)")!),
            conversationStore: ConversationStore(directory: dir.appending(component: "convos")),
            memoryStore: MemoryStore(fileURL: dir.appending(component: "container-memory.json")),
            installProbe: { _, _ in false },
            availableMemory: { .max })

        XCTAssertTrue(container.chat.memoryBook === container.memory,
                      "what you edit in Settings → Memory is what the next turn's prompt is composed from")
        try await container.memory.add("the user's dog is named Momo")
        XCTAssertEqual(container.chat.memoryBook?.facts.map(\.text), ["the user's dog is named Momo"])
    }

    func testProvenanceNamesTheAuthor() {
        let now = Date()
        let mine = MemoryFact(text: "x", createdAt: now, source: .user)
        let theirs = MemoryFact(text: "x", createdAt: now, source: .model)
        XCTAssertTrue(MemoryView.provenance(mine, now: now).hasPrefix("Added by you"))
        XCTAssertTrue(MemoryView.provenance(theirs, now: now).hasPrefix("Saved by mobileLLM"))
    }
}
