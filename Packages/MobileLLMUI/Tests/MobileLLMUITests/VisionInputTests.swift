// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Image-input gating + send path (C2.1 / C2.3): the photo affordance lights up only for an installed
/// vision GGUF variant; an MLX model blocks (never silently drops) an image send; and a real send threads
/// the attached image onto the user `ChatTurn` handed to the engine.
@MainActor
final class VisionInputTests: XCTestCase {

    private let phone8 = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "vision-\(UUID().uuidString)")
    }

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "vision-chat-\(UUID().uuidString)")
        return (ConversationStore(directory: dir), dir)
    }

    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "vision-tests-\(UUID().uuidString)")!)
    }

    private func manager(installed: Bool) -> ModelManager {
        ModelManager(engine: MockLLMEngine(), device: phone8, downloadBase: tempBase(),
                     downloader: { _, _, _, progress in progress(1) },
                     installProbe: { _, _ in installed },
                     availableMemory: { .max })
    }

    private var visionVariant: LLMVariant { LLMCatalog.qwen35_4b.variant(engine: .llamaCpp, quant: .gguf4bit)! }
    private var textVariant: LLMVariant { LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)! }
    private var mlxVariant: LLMVariant { LLMCatalog.bonsai8b.variant(engine: .mlx, quant: .binary1bit)! }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Gating

    func testInstalledVisionVariantIsImageCapable() {
        let models = manager(installed: true)
        models.refreshInstalled()
        XCTAssertTrue(visionVariant.supportsVisionInput, "the catalog variant ships an mmproj")
        XCTAssertTrue(models.supportsImageInput(visionVariant), "installed vision GGUF ⇒ image-capable")
    }

    func testVisionVariantNotImageCapableWhenProjectorMissing() {
        let models = manager(installed: false)   // probe reports nothing on disk (mmproj absent)
        models.refreshInstalled()
        XCTAssertFalse(models.supportsImageInput(visionVariant), "no projector on disk ⇒ not image-capable")
    }

    func testTextOnlyVariantIsNotImageCapable() {
        let models = manager(installed: true)
        models.refreshInstalled()
        XCTAssertFalse(textVariant.supportsVisionInput)
        XCTAssertFalse(models.supportsImageInput(textVariant), "a projector-less GGUF is never image-capable")
    }

    func testMLXVariantIsNotImageCapable() {
        let models = manager(installed: true)
        models.refreshInstalled()
        XCTAssertFalse(models.supportsImageInput(mlxVariant), "MLX has no mtmd image path")
    }

    func testActiveSupportsImageInputTracksResidentModel() async throws {
        let models = manager(installed: true)
        models.refreshInstalled()
        XCTAssertFalse(models.activeSupportsImageInput, "no resident model yet")
        try await models.activate(LLMCatalog.qwen35_4b, variant: visionVariant, context: 4096)
        XCTAssertTrue(models.activeSupportsImageInput, "a resident vision model reports image-capable")
    }

    // MARK: - MLX block (no silent text-only degradation)

    func testImageSendOnMLXModelIsBlockedWithToast() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = ChatStore(engine: MockLLMEngine(script: .init()), store: store, settings: settings(),
                             activeModel: LoadedModel(model: LLMCatalog.bonsai8b, variant: mlxVariant))
        chat.draft = "what is in this photo"
        XCTAssertTrue(chat.attach(imageData: makeTestImageData()))

        chat.send()
        XCTAssertNil(chat.streaming, "the send is blocked, not started")
        XCTAssertEqual(chat.banner?.kind, .warning, "an actionable toast explains the block")
        XCTAssertEqual(chat.activeConversation?.messages.count ?? 0, 0, "no turn is created")
        XCTAssertEqual(chat.pendingImages.count, 1, "the staged image is kept for a retry after switching")
        XCTAssertEqual(chat.draft, "what is in this photo", "the draft is kept too")
    }

    /// Engine family alone is not a vision capability. Bonsai is a llama.cpp GGUF, but its exact variant
    /// has no projector; accepting this send used to discard the staged photo and let it answer the text as
    /// though no image had ever been attached.
    func testImageSendOnTextOnlyLlamaModelIsBlockedWithoutLosingComposer() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = ChatStore(engine: MockLLMEngine(script: .init()), store: store, settings: settings(),
                             activeModel: LoadedModel(model: LLMCatalog.bonsai8b, variant: textVariant))
        chat.draft = "what is in this photo"
        XCTAssertTrue(chat.attach(imageData: makeTestImageData()))
        let stagedID = try XCTUnwrap(chat.pendingImages.first?.id)

        chat.send()

        XCTAssertNil(chat.streaming, "a projector-less llama.cpp variant must be rejected before generation")
        XCTAssertEqual(chat.banner?.kind, .warning)
        XCTAssertTrue(chat.banner?.message.contains("can't read images") == true)
        XCTAssertEqual(chat.activeConversation?.messages.count ?? 0, 0, "no provisional turn is created")
        XCTAssertEqual(chat.pendingImages.map(\.id), [stagedID], "the exact staged image remains retryable")
        XCTAssertEqual(chat.draft, "what is in this photo", "the text draft remains retryable too")
    }

    // MARK: - Send path threads images to the engine turn

    func testSendThreadsAttachedImageOntoUserTurn() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RecordingEngine()
        let chat = ChatStore(engine: engine, store: store, settings: settings(),
                             activeModel: LoadedModel(model: LLMCatalog.qwen35_4b, variant: visionVariant))
        chat.draft = "describe this"
        XCTAssertTrue(chat.attach(imageData: makeTestImageData()))
        XCTAssertEqual(chat.pendingImages.count, 1)

        chat.send()
        try await waitUntilIdle(chat)

        // The engine received the image on the user turn.
        let recorded = await engine.lastTurns()
        let turns = try XCTUnwrap(recorded)
        let userTurn = try XCTUnwrap(turns.last { $0.role == .user })
        XCTAssertEqual(userTurn.content, "describe this")
        XCTAssertEqual(userTurn.images.count, 1, "the attached image is handed to the engine")

        // It's stamped onto the message as a ref and written to disk as a file.
        let user = try XCTUnwrap(chat.activeConversation?.messages.first { $0.role == .user })
        let refs = try XCTUnwrap(user.attachments)
        XCTAssertEqual(refs.count, 1)
        let onDisk = await store.attachmentData(refs[0].id)
        XCTAssertNotNil(onDisk, "the image bytes are persisted to disk")
        XCTAssertTrue(chat.pendingImages.isEmpty, "staged images clear on send")
    }

    func testAttachmentWriteFailureRollsBackTurnAndRestoresComposer() async throws {
        // Make the conversation-store "directory" a regular file. Creating its attachments child must
        // fail deterministically without relying on disk-full state or platform permissions.
        let blockedRoot = FileManager.default.temporaryDirectory
            .appending(component: "vision-blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockedRoot)
        defer { try? FileManager.default.removeItem(at: blockedRoot) }

        let store = ConversationStore(directory: blockedRoot)
        let engine = RecordingEngine()
        let chat = ChatStore(engine: engine, store: store, settings: settings(),
                             activeModel: LoadedModel(model: LLMCatalog.qwen35_4b, variant: visionVariant))
        let conversation = Conversation(title: "Before send", modelID: "old-model", variantID: "old-variant")
        chat.conversations = [conversation]
        chat.activeID = conversation.id
        chat.draft = "please inspect this"
        XCTAssertTrue(chat.attach(imageData: makeTestImageData()))
        let stagedID = try XCTUnwrap(chat.pendingImages.first?.id)

        chat.send()
        try await waitUntilIdle(chat)

        XCTAssertEqual(chat.activeConversation?.messages, [],
                       "a record must never retain refs whose image bytes were not persisted")
        XCTAssertEqual(chat.activeConversation?.title, "Before send")
        XCTAssertEqual(chat.activeConversation?.modelID, "old-model")
        XCTAssertEqual(chat.activeConversation?.variantID, "old-variant")
        XCTAssertEqual(chat.draft, "please inspect this", "the user's text is restored")
        XCTAssertEqual(chat.pendingImages.map(\.id), [stagedID], "the exact staged image is restored")
        XCTAssertEqual(chat.banner?.kind, .error)
        let recordedTurns = await engine.lastTurns()
        XCTAssertNil(recordedTurns, "generation must not start after attachment persistence fails")
    }

    func testLaterAttachmentFailureRemovesEarlierPartialWrite() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RecordingEngine()
        let chat = ChatStore(engine: engine, store: store, settings: settings(),
                             activeModel: LoadedModel(model: LLMCatalog.qwen35_4b, variant: visionVariant))
        let conversation = Conversation(
            title: "Images",
            modelID: LLMCatalog.qwen35_4b.id,
            variantID: visionVariant.id
        )
        chat.conversations = [conversation]
        chat.activeID = conversation.id
        chat.draft = "compare these"
        XCTAssertTrue(chat.attach(imageData: makeTestImageData(width: 320, height: 240)))
        XCTAssertTrue(chat.attach(imageData: makeTestImageData(width: 400, height: 300)))
        let staged = chat.pendingImages
        XCTAssertEqual(staged.count, 2)

        // The first target remains writable. Make only the second target a directory so the first file is
        // committed before the second atomic Data.write fails; rollback must purge both targets.
        let attachments = dir.appending(component: "attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let blockedSecond = attachments.appending(component: "\(staged[1].id.uuidString).jpg")
        try FileManager.default.createDirectory(at: blockedSecond, withIntermediateDirectories: false)

        chat.send()
        try await waitUntilIdle(chat)

        for image in staged {
            let path = attachments.appending(component: "\(image.id.uuidString).jpg")
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path),
                           "rollback must remove every file in a partially written multi-image turn")
        }
        XCTAssertEqual(chat.pendingImages.map(\.id), staged.map(\.id))
        XCTAssertEqual(chat.activeConversation?.messages, [])
        let recordedTurns = await engine.lastTurns()
        XCTAssertNil(recordedTurns)
    }

    func testAttachCapsAtThree() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = ChatStore(engine: MockLLMEngine(script: .init()), store: store, settings: settings(),
                             activeModel: LoadedModel(model: LLMCatalog.qwen35_4b, variant: visionVariant))
        for _ in 0..<3 { XCTAssertTrue(chat.attach(imageData: makeTestImageData())) }
        XCTAssertFalse(chat.canAttachMoreImages)
        XCTAssertFalse(chat.attach(imageData: makeTestImageData()), "the 4th attach is rejected")
        XCTAssertEqual(chat.pendingImages.count, 3)
    }
}
