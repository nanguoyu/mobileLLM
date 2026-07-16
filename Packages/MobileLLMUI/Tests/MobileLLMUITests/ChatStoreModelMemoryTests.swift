// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Conversation ↔ model memory (DESIGN §2.4): a thread keeps the model it was talked to with across a
/// relaunch instead of silently falling back to the Settings default. Two integration paths that had zero
/// coverage: `AppContainer.bootTarget()` (boot into the ACTIVE conversation's remembered model) driven
/// through a real `bootstrap()` over a pre-seeded conversation directory, and `restoreConversationModel`
/// driven through the REAL `select()` → `restoreModel` closure (not a stubbed test closure).
@MainActor
final class ChatStoreModelMemoryTests: XCTestCase {

    private let mac = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func tempDir(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appending(component: "\(tag)-\(UUID().uuidString)")
    }

    private func makeContainer(conversationDir: URL, defaultModelID: String) -> AppContainer {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "modelmem-\(UUID().uuidString)")!)
        settings.defaultModelID = defaultModelID
        return AppContainer(
            engine: MockLLMEngine(),
            downloadBase: tempDir("modelmem-dl"),
            downloader: { _, _, p in p(1) },
            device: mac,
            settings: settings,
            conversationStore: ConversationStore(directory: conversationDir),
            installProbe: { _, _ in true },        // everything installed → both models are bootable
            availableMemory: { .max })              // sidestep the OOM pre-flight
    }

    // MARK: - Boot into the remembered model across a simulated relaunch

    /// Pre-save a conversation that remembers a NON-default model in a directory, then build a fresh
    /// `AppContainer` over that same directory and bootstrap — it must activate the remembered model, not
    /// the Settings default. This is the crux of conversation-model memory and had no integration coverage.
    func testBootstrapBootsIntoRememberedConversationModelNotDefault() async throws {
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

        XCTAssertEqual(container.models.active?.model.id, remembered.id,
                       "boot activates the active conversation's remembered model, not the Settings default")
        XCTAssertEqual(container.models.active?.variant.id, remembered.defaultVariantValue.id,
                       "and the exact remembered variant, since it's installed")
        // The chat store's active model is kept in sync with the resident one.
        XCTAssertEqual(container.chat.activeModel?.model.id, remembered.id)
    }

    /// Sibling: with NO conversations on disk, boot falls back to the Settings default (proves the test
    /// above passes because of the remembered thread, not because bonsai4b happens to win any tie-break).
    func testBootstrapWithNoConversationsBootsTheDefault() async throws {
        let convDir = tempDir("modelmem-empty")
        defer { try? FileManager.default.removeItem(at: convDir) }
        let container = makeContainer(conversationDir: convDir, defaultModelID: LLMCatalog.bonsai8b.id)
        await container.bootstrap()
        XCTAssertEqual(container.models.active?.model.id, LLMCatalog.bonsai8b.id,
                       "no remembered thread → the Settings default boots")
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
        XCTAssertEqual(container.models.active?.model.id, LLMCatalog.bonsai8b.id, "booted on the default")

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
        while container.models.active?.model.id != remembered.id && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(container.models.active?.model.id, remembered.id,
                       "selecting the thread restored ITS model through the real closure")
        XCTAssertEqual(container.chat.activeModel?.model.id, remembered.id, "the chat store's active model follows")
    }
}
