// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

private actor DelayedRestoreEngine: LLMEngine {
    private let delayNanos: UInt64
    private var startedVariantIDs: [String] = []

    init(delayNanos: UInt64 = 150_000_000) {
        self.delayNanos = delayNanos
    }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {
        startedVariantIDs.append(variant.id)
        try await Task.sleep(nanoseconds: delayNanos)
        progress(1)
    }

    func unload() async {}

    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func started(_ variantID: String) -> Bool {
        startedVariantIDs.contains(variantID)
    }
}

/// Conversation ↔ model memory (DESIGN §2.4): launch loads history without entering it, while a thread
/// still restores the model it was talked to with once explicitly selected. Covers a real `bootstrap()`
/// over a pre-seeded directory and `restoreConversationModel` through the REAL
/// `select()` → `restoreModel` closure (not a stubbed test closure).
@MainActor
final class ChatStoreModelMemoryTests: XCTestCase {

    private let mac = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func tempDir(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appending(component: "\(tag)-\(UUID().uuidString)")
    }

    private func makeContainer(conversationDir: URL, defaultModelID: String,
                               engine: any LLMEngine = MockLLMEngine()) -> AppContainer {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "modelmem-\(UUID().uuidString)")!)
        settings.defaultModelID = defaultModelID
        return AppContainer(
            engine: engine,
            downloadBase: tempDir("modelmem-dl"),
            downloader: { _, _, _, p in p(1) },
            device: mac,
            settings: settings,
            conversationStore: ConversationStore(directory: conversationDir),
            installProbe: { _, _ in true },        // everything installed → both models are selectable
            availableMemory: { .max })              // compatibility probe; activation ignores this value
    }

    // MARK: - Cold launch leaves history unselected

    /// Pre-save a conversation that remembers a NON-default model, then build a fresh container over that
    /// directory. Bootstrap must hydrate the list without selecting/entering that thread or following its
    /// model; only the default identity is restored and no weights are loaded.
    func testBootstrapLoadsHistoryWithoutSelectingItOrRestoringItsModel() async throws {
        let convDir = tempDir("modelmem-conv")
        defer { try? FileManager.default.removeItem(at: convDir) }

        // The thread remembers bonsai4b; the Settings default is bonsai8b — they must differ.
        let remembered = LLMCatalog.bonsai4b
        XCTAssertNotEqual(remembered.id, LLMCatalog.bonsai8b.id)
        let seedStore = ConversationStore(directory: convDir)
        let convo = Conversation(modelID: remembered.id, variantID: remembered.defaultVariantValue.id,
                                 messages: [Message(role: .user, answer: "hi"),
                                            Message(role: .assistant, answer: "hello")])
        try await seedStore.save(convo)

        // A FRESH container over the SAME directory (the simulated relaunch).
        let container = makeContainer(conversationDir: convDir, defaultModelID: LLMCatalog.bonsai8b.id)
        await container.bootstrap()

        XCTAssertEqual(container.chat.conversations.map(\.id), [convo.id],
                       "bootstrap still hydrates the conversation list")
        XCTAssertNil(container.chat.activeID, "cold launch must not select the latest conversation")
        XCTAssertNil(container.chat.activeConversation, "cold launch must stay on the list/blank detail")
        XCTAssertEqual(container.models.active?.model.id, LLMCatalog.bonsai8b.id,
                       "launch restores the default identity, not a historical thread's model")
        XCTAssertFalse(container.models.engineResident, "cold launch must not load model weights")
        XCTAssertEqual(container.chat.activeModel?.model.id, LLMCatalog.bonsai8b.id)
    }

    /// Sibling: with NO conversations on disk, selection still restores the Settings default identity.
    func testBootstrapWithNoConversationsBootsTheDefault() async throws {
        let convDir = tempDir("modelmem-empty")
        defer { try? FileManager.default.removeItem(at: convDir) }
        let container = makeContainer(conversationDir: convDir, defaultModelID: LLMCatalog.bonsai8b.id)
        await container.bootstrap()
        XCTAssertEqual(container.models.active?.model.id, LLMCatalog.bonsai8b.id,
                       "no remembered thread → the Settings default is selected")
        XCTAssertFalse(container.models.engineResident, "default selection must remain cold at launch")
    }

    // MARK: - select() restores a thread's model via the real closure

    /// On a live, already-booted container, selecting a thread whose remembered model differs from the
    /// resident one must activate that model through the REAL `restoreConversationModel` closure wired in
    /// `AppContainer.init` — not a stub.
    func testSelectRestoresConversationModelViaRealClosure() async throws {
        let convDir = tempDir("modelmem-select")
        defer { try? FileManager.default.removeItem(at: convDir) }
        let container = makeContainer(conversationDir: convDir, defaultModelID: LLMCatalog.bonsai8b.id)
        await container.bootstrap()
        XCTAssertEqual(container.models.active?.model.id, LLMCatalog.bonsai8b.id, "selected the default")
        XCTAssertFalse(container.models.engineResident, "bootstrap starts with a non-resident selection")

        // Seed a thread that remembers bonsai4b and select it (the real select → restoreModel path).
        let remembered = LLMCatalog.bonsai4b
        let convo = Conversation(modelID: remembered.id, variantID: remembered.defaultVariantValue.id,
                                 messages: [Message(role: .user, answer: "hi"),
                                            Message(role: .assistant, answer: "yo")])
        container.chat.conversations = [convo]
        container.chat.activeID = nil
        container.chat.select(convo.id)

        // restoreConversationModel activates asynchronously (Task) — wait for the resident model to switch.
        let deadline = Date().addingTimeInterval(5)
        while (container.models.active?.model.id != remembered.id || !container.models.engineResident)
                && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(container.models.active?.model.id, remembered.id,
                       "selecting the thread restored ITS model through the real closure")
        XCTAssertTrue(container.models.engineResident, "an explicit live model switch still loads its weights")
        XCTAssertEqual(container.chat.activeModel?.model.id, remembered.id, "the chat store's active model follows")
    }

    /// A conversation also remembers its exact backend/quant variant, not just the base model. This covers
    /// the real AppContainer resolver so a same-model MLX/GGUF switch cannot silently keep the wrong one.
    func testSelectRestoresConversationVariantWithinSameModelViaRealClosure() async throws {
        let convDir = tempDir("modelmem-variant")
        defer { try? FileManager.default.removeItem(at: convDir) }
        let model = LLMCatalog.bonsai8b
        let container = makeContainer(conversationDir: convDir, defaultModelID: model.id)
        await container.bootstrap()

        let residentID = try XCTUnwrap(container.models.active?.variant.id)
        let remembered = try XCTUnwrap(model.variants.first { $0.id != residentID })
        let convo = Conversation(modelID: model.id, variantID: remembered.id,
                                 messages: [Message(role: .user, answer: "hi"),
                                            Message(role: .assistant, answer: "hello")])
        container.chat.conversations = [convo]
        container.chat.activeID = nil
        container.chat.select(convo.id)

        let deadline = Date().addingTimeInterval(5)
        while (container.models.active?.variant.id != remembered.id || !container.models.engineResident)
                && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(container.models.active?.model.id, model.id)
        XCTAssertEqual(container.models.active?.variant.id, remembered.id,
                       "selecting a thread must restore its exact remembered variant")
        XCTAssertTrue(container.models.engineResident)
        XCTAssertEqual(container.chat.activeModel?.variant.id, remembered.id)
    }

    func testRapidConversationSelectionRestoresTheLatestModelAndPreservesItsIdentity() async throws {
        let convDir = tempDir("modelmem-latest")
        defer { try? FileManager.default.removeItem(at: convDir) }
        let engine = DelayedRestoreEngine()
        let container = makeContainer(conversationDir: convDir,
                                      defaultModelID: LLMCatalog.bonsai8b.id,
                                      engine: engine)
        await container.bootstrap()

        let modelA = LLMCatalog.bonsai4b
        let modelB = LLMCatalog.qwen35_4b
        let conversationA = Conversation(modelID: modelA.id,
                                         variantID: modelA.defaultVariantValue.id)
        let conversationB = Conversation(modelID: modelB.id,
                                         variantID: modelB.defaultVariantValue.id)
        container.chat.conversations = [conversationA, conversationB]

        container.chat.select(conversationA.id)
        let startDeadline = Date().addingTimeInterval(2)
        while !(await engine.started(modelA.defaultVariantValue.id)) && Date() < startDeadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let didStartA = await engine.started(modelA.defaultVariantValue.id)
        XCTAssertTrue(didStartA)

        // B is selected while A owns ModelManager's operation lane. The old guard used to drop B.
        container.chat.select(conversationB.id)
        let finishDeadline = Date().addingTimeInterval(4)
        while (container.models.active?.variant.id != modelB.defaultVariantValue.id
               || !container.models.engineResident
               || container.chat.activeModel?.variant.id != modelB.defaultVariantValue.id)
                && Date() < finishDeadline {
            // ModelManager publishes the loaded identity before the awaiting AppContainer continuation
            // synchronizes ChatStore on the same main actor. Wait for the public state as a whole rather
            // than sampling that intentional one-turn handoff window.
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(container.models.active?.variant.id, modelB.defaultVariantValue.id)
        XCTAssertEqual(container.chat.activeModel?.variant.id, modelB.defaultVariantValue.id)
        XCTAssertEqual(container.chat.activeConversation?.modelID, modelB.id)
        XCTAssertEqual(container.chat.activeConversation?.variantID, modelB.defaultVariantValue.id,
                       "a late A completion must not reseed empty conversation B")
    }

    func testLegacyExploreVariantAlwaysResolvesToTheSameCanonicalArtifact() async throws {
        let convDir = tempDir("modelmem-legacy-artifact")
        defer { try? FileManager.default.removeItem(at: convDir) }
        let container = makeContainer(conversationDir: convDir,
                                      defaultModelID: LLMCatalog.bonsai8b.id)
        await container.bootstrap()

        let remote = RemoteModel(
            id: "community/Stable-Legacy-GGUF",
            name: "Stable Legacy",
            publisher: "community",
            engine: .llamaCpp,
            downloads: 1,
            revision: "commit-1",
            variants: [
                RemoteVariant(quantLabel: "Q4_K_M", repo: "community/Stable-Legacy-GGUF",
                              revision: "commit-1", fileName: "stable-q4.gguf", sizeBytes: 4_000),
                RemoteVariant(quantLabel: "Q8_0", repo: "community/Stable-Legacy-GGUF",
                              revision: "commit-1", fileName: "stable-q8.gguf", sizeBytes: 8_000),
            ]
        ).asLLMModel(paramsBillions: 7)
        container.models.adopt(remote)

        let ordered = remote.variants.sorted { $0.id < $1.id }
        let canonical = try XCTUnwrap(ordered.first)
        let sibling = try XCTUnwrap(ordered.last)
        XCTAssertNotEqual(canonical.id, sibling.id)
        XCTAssertEqual(canonical.legacyID, sibling.legacyID)
        _ = container.models.restoreSelection(remote, variant: sibling)
        container.syncActive()

        let conversation = Conversation(modelID: remote.id, variantID: canonical.legacyID)
        container.chat.conversations = [conversation]
        container.chat.select(conversation.id)

        let deadline = Date().addingTimeInterval(3)
        while (container.models.active?.variant.id != canonical.id
               || !container.models.engineResident) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(container.models.active?.variant.id, canonical.id,
                       "legacy aliases resolve independently of the previously active sibling")
        XCTAssertEqual(container.chat.activeModel?.variant.id, canonical.id)
    }
}
