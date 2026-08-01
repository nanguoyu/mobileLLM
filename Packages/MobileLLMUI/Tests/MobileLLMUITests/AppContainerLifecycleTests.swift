// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// A loader that records every resident load and deliberately ignores cancellation while its first load
/// is constructing a context. This catches duplicate restore requests that a cooperative mock hides.
private actor NonCooperativeRestoreEngine: LLMEngine {
    private var loadCount = 0
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private var residentVariantID: String?

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {
        loadCount += 1
        if loadCount == 1 {
            await withCheckedContinuation { firstLoadContinuation = $0 }
        }
        residentVariantID = variant.id
        progress(1)
    }

    func unload() async { residentVariantID = nil }

    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func loads() -> Int { loadCount }
    func residentID() -> String? { residentVariantID }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }
}

/// Holds bootstrap before ChatStore.load so the test can exercise a real user interaction during the
/// launch await chain, rather than mutating state inside a store fake.
private actor BootstrapMemoryBarrier: MemoryStoring {
    private var listStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func save(_ text: String, source: MemoryFact.Source) async throws -> MemoryFact {
        MemoryFact(text: text, source: source)
    }

    func saveIfAbsent(_ text: String, source: MemoryFact.Source) async throws -> MemorySaveResult {
        .saved(MemoryFact(text: text, source: source))
    }

    func list() async -> [MemoryFact] {
        listStarted = true
        await withCheckedContinuation { continuation = $0 }
        return []
    }

    func update(id: String, text: String) async throws {}
    func delete(id: String) async throws {}
    func deleteAll() async throws {}

    func didStartList() -> Bool { listStarted }

    func releaseList() {
        continuation?.resume()
        continuation = nil
    }
}

/// Cross-store lifecycle contracts that must be tested through AppContainer's production wiring. These
/// are regressions found by the full-call-chain rebuild probes; unit tests of either store alone cannot
/// observe them.
@MainActor
final class AppContainerLifecycleTests: XCTestCase {
    private let phone = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)

    private func tempDirectory(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appending(component: "\(tag)-\(UUID().uuidString)")
    }

    func testSelectThenDetailAppearanceSharesOneNonCooperativeRestore() async throws {
        let engine = NonCooperativeRestoreEngine()
        let conversationDirectory = tempDirectory("restore-conversations")
        let downloadDirectory = tempDirectory("restore-downloads")
        defer {
            try? FileManager.default.removeItem(at: conversationDirectory)
            try? FileManager.default.removeItem(at: downloadDirectory)
        }
        let defaults = UserDefaults(suiteName: "restore-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.defaultModelID = LLMCatalog.bonsai8b.id
        let container = AppContainer(
            engine: engine,
            downloadBase: downloadDirectory,
            downloader: { _, _, _, progress in progress(1) },
            device: phone,
            settings: settings,
            conversationStore: ConversationStore(directory: conversationDirectory),
            installProbe: { _, _ in true }
        )
        await container.bootstrap()

        let target = LLMCatalog.bonsai4b
        let conversation = Conversation(modelID: target.id,
                                        variantID: target.defaultVariantValue.id)
        container.chat.conversations = [conversation]
        container.chat.select(conversation.id)

        let startDeadline = Date().addingTimeInterval(2)
        while await engine.loads() == 0, Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let initialLoadCount = await engine.loads()
        XCTAssertEqual(initialLoadCount, 1)

        // This is the production ChatDetailView.onAppear action immediately following the row selection.
        container.chat.restoreConversationModelIfNeeded()
        await engine.releaseFirstLoad()

        let finishDeadline = Date().addingTimeInterval(3)
        while (container.models.active?.model.id != target.id || !container.models.engineResident),
              Date() < finishDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let completedLoadCount = await engine.loads()
        XCTAssertEqual(completedLoadCount, 1,
                       "one navigation must never cancel and restart the same model load")
        XCTAssertEqual(container.chat.activeModel?.model.id, target.id)
    }

    func testDeletingActiveVariantImmediatelyClearsModelAndChatSelections() async throws {
        let model = LLMCatalog.bonsai8b
        let variant = try XCTUnwrap(model.variant(engine: .llamaCpp, quant: .binary1bit))
        let downloadDirectory = tempDirectory("delete-active")
        defer { try? FileManager.default.removeItem(at: downloadDirectory) }
        let container = AppContainer(
            engine: MockLLMEngine(),
            downloadBase: downloadDirectory,
            downloader: { _, _, _, progress in progress(1) },
            device: phone,
            installProbe: { _, _ in true }
        )
        container.models.refreshInstalled()
        _ = try await container.models.activate(model, variant: variant, context: 2_048)
        XCTAssertEqual(container.models.active?.variant.id, variant.id)
        XCTAssertEqual(container.chat.activeModel?.variant.id, variant.id)

        // ModelsView calls ModelManager directly. Both public mirrors must be coherent when delete returns,
        // before its serialized engine cleanup has a chance to run.
        container.models.delete(variant)

        XCTAssertNil(container.models.active)
        XCTAssertNil(container.chat.activeModel)
        XCTAssertFalse(container.chat.hasModel)
        XCTAssertFalse(container.chat.canSend)
    }

    func testDeletingConversationCancelsItsNonCooperativeModelRestore() async throws {
        let engine = NonCooperativeRestoreEngine()
        let conversationDirectory = tempDirectory("delete-restoring-conversation")
        let downloadDirectory = tempDirectory("delete-restoring-downloads")
        defer {
            try? FileManager.default.removeItem(at: conversationDirectory)
            try? FileManager.default.removeItem(at: downloadDirectory)
        }
        let container = AppContainer(
            engine: engine,
            downloadBase: downloadDirectory,
            downloader: { _, _, _, progress in progress(1) },
            device: phone,
            conversationStore: ConversationStore(directory: conversationDirectory),
            installProbe: { _, _ in true }
        )
        await container.bootstrap()

        let fallbackSelection = try XCTUnwrap(container.models.active)
        let restoringModel = fallbackSelection.model.id == LLMCatalog.bonsai4b.id
            ? LLMCatalog.bonsai8b
            : LLMCatalog.bonsai4b
        let fallback = Conversation(modelID: fallbackSelection.model.id,
                                    variantID: fallbackSelection.variant.id)
        let doomed = Conversation(modelID: restoringModel.id,
                                  variantID: restoringModel.defaultVariantValue.id)
        container.chat.conversations = [fallback, doomed]
        container.chat.select(doomed.id)
        let startDeadline = Date().addingTimeInterval(2)
        while await engine.loads() == 0, Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let startedLoads = await engine.loads()
        XCTAssertEqual(startedLoads, 1)

        container.chat.delete(doomed.id)
        XCTAssertEqual(container.chat.activeID, fallback.id)
        await engine.releaseFirstLoad()

        let finishDeadline = Date().addingTimeInterval(3)
        while container.models.switching, Date() < finishDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(container.models.switching)
        XCTAssertEqual(container.models.active?.variant.id, fallbackSelection.variant.id,
                       "a deleted conversation's late load must never become the selected model")
        XCTAssertEqual(container.chat.activeModel?.variant.id, fallbackSelection.variant.id)
        let residentID = await engine.residentID()
        XCTAssertNil(residentID,
                     "the cancelled native context is unloaded; fallback remains a cold selection")
    }

    func testNewConversationCreatedDuringBootstrapRemainsSelected() async throws {
        let memory = BootstrapMemoryBarrier()
        let conversationDirectory = tempDirectory("bootstrap-conversations")
        let downloadDirectory = tempDirectory("bootstrap-downloads")
        defer {
            try? FileManager.default.removeItem(at: conversationDirectory)
            try? FileManager.default.removeItem(at: downloadDirectory)
        }
        let container = AppContainer(
            engine: MockLLMEngine(),
            downloadBase: downloadDirectory,
            downloader: { _, _, _, progress in progress(1) },
            device: phone,
            conversationStore: ConversationStore(directory: conversationDirectory),
            memoryStore: memory,
            installProbe: { _, _ in true }
        )

        let bootstrap = Task { @MainActor in await container.bootstrap() }
        let startDeadline = Date().addingTimeInterval(2)
        while !(await memory.didStartList()), Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let didStartList = await memory.didStartList()
        XCTAssertTrue(didStartList)
        let conversation = try XCTUnwrap(container.chat.newConversation())
        XCTAssertEqual(container.chat.activeID, conversation.id)

        await memory.releaseList()
        await bootstrap.value

        XCTAssertEqual(container.chat.activeID, conversation.id,
                       "bootstrap completion must not navigate away from live user work")
        XCTAssertEqual(container.chat.activeConversation?.id, conversation.id)
    }

    func testConversationSelectedDuringBootstrapRemainsSelected() async throws {
        let memory = BootstrapMemoryBarrier()
        let conversationDirectory = tempDirectory("bootstrap-select-conversations")
        let downloadDirectory = tempDirectory("bootstrap-select-downloads")
        defer {
            try? FileManager.default.removeItem(at: conversationDirectory)
            try? FileManager.default.removeItem(at: downloadDirectory)
        }
        let container = AppContainer(
            engine: MockLLMEngine(),
            downloadBase: downloadDirectory,
            downloader: { _, _, _, progress in progress(1) },
            device: phone,
            conversationStore: ConversationStore(directory: conversationDirectory),
            memoryStore: memory,
            installProbe: { _, _ in true }
        )
        // A shell may already have a live mirror (for example after scene restoration) before its
        // idempotent bootstrap waiter finishes. Keep the model id empty so this test isolates navigation.
        let conversation = Conversation(modelID: "", variantID: "",
                                        messages: [Message(role: .user, answer: "live draft")])
        container.chat.conversations = [conversation]

        let bootstrap = Task { @MainActor in await container.bootstrap() }
        let startDeadline = Date().addingTimeInterval(2)
        while !(await memory.didStartList()), Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        container.chat.select(conversation.id)
        XCTAssertEqual(container.chat.activeID, conversation.id)

        await memory.releaseList()
        await bootstrap.value

        XCTAssertEqual(container.chat.activeID, conversation.id)
        XCTAssertEqual(container.chat.activeConversation?.messages.first?.answer, "live draft",
                       "disk hydration must not replace the live value for an already-present id")
    }
}
