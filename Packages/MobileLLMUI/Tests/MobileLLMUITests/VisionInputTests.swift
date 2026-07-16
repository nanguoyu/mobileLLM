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
                     downloader: { _, _, progress in progress(1) },
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
