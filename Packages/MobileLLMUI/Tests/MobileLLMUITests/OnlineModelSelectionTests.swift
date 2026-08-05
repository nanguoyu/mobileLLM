// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// The online model is a first-class selection: no local weights, no installed model, and conversations
/// remember the service identity across relaunch.
@MainActor
final class OnlineModelSelectionTests: XCTestCase {

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-online-tests-\(UUID().uuidString)")
        return (ConversationStore(directory: dir), dir)
    }

    private func makeOnlineSettings() -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "online-tests-\(UUID().uuidString)")!)
        settings.openAIModelID = "gateway-model"
        settings.openAIOnlineEnabled = true
        return settings
    }

    func testOnlineIdentityRoundTrips() {
        XCTAssertEqual(
            OnlineModelIdentity.conversationModelID("svc-1", model: "gateway-model"),
            "online.responses:svc-1:gateway-model"
        )
        XCTAssertEqual(
            OnlineModelIdentity.serviceParts(
                fromConversationModelID: "online.responses:svc-1:gateway-model"
            )?.serviceID,
            "svc-1"
        )
        XCTAssertNil(OnlineModelIdentity.serviceParts(fromConversationModelID: "bonsai-8b"))
        XCTAssertNil(OnlineModelIdentity.serviceParts(fromConversationModelID: "online.responses:svc-1:"))
        XCTAssertEqual(OnlineModelIdentity.displayLabel("Gateway"), "Online · Gateway")
    }

    func testOnlineSelectionMakesChatSendableWithoutAnyLocalModel() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: makeOnlineSettings(),
            activeModel: nil
        )

        XCTAssertTrue(chat.isOnlineActive)
        XCTAssertTrue(chat.hasModel)
        XCTAssertEqual(chat.activeModelLabel, "Online · OpenAI")
        chat.draft = "hello"
        XCTAssertTrue(chat.canSend)

        let convo = chat.newConversation()
        XCTAssertEqual(convo?.modelID, "online.responses:responses-api-key:gateway-model")
        XCTAssertEqual(convo?.variantID, OnlineModelIdentity.variantID)
    }

    func testOfflineWithoutLocalModelIsNotSendable() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "online-off-\(UUID().uuidString)")!)
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: settings,
            activeModel: nil
        )

        XCTAssertFalse(chat.isOnlineActive)
        XCTAssertFalse(chat.hasModel)
        XCTAssertEqual(chat.activeModelLabel, "No model")
        chat.draft = "hello"
        XCTAssertFalse(chat.canSend)
    }

    func testReopeningAnOnlineConversationRearmsTheOnlineSelection() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeOnlineSettings()
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: settings,
            activeModel: nil
        )
        let convo = chat.newConversation()
        XCTAssertEqual(convo?.modelID, "online.responses:responses-api-key:gateway-model")

        // User turned the online service off and opened a local thread; reopening the online thread
        // must bring the same service model back without loading any weights.
        settings.openAIOnlineEnabled = false
        settings.openAIModelID = nil
        chat.restoreConversationModelIfNeeded()

        XCTAssertTrue(settings.openAIOnlineEnabled)
        XCTAssertEqual(settings.openAIModelID, "gateway-model")
    }

    func testOnlineSendRejectsImagesWithoutLosingTheDraft() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: makeOnlineSettings(),
            activeModel: nil
        )
        chat.draft = "what is this?"
        XCTAssertTrue(chat.attach(imageData: makeTestImageData()), "test image must stage")
        XCTAssertTrue(chat.canSend)

        chat.send()

        XCTAssertEqual(chat.draft, "what is this?", "the draft must survive an online vision rejection")
        XCTAssertEqual(chat.pendingImages.count, 1, "staged images must survive the rejection")
        XCTAssertNotNil(chat.banner, "the rejection must surface a toast")
    }

    /// With multiple services, the ACTIVE one (not the first) decides what a send uses.
    func testActiveServiceSwitchingChangesOnlineModelID() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "online-multi-\(UUID().uuidString)")!)
        settings.upsertOnlineService(OnlineService(
            id: "svc-a",
            name: "A",
            baseURL: "https://api.a.example",
            modelID: "model-a"
        ))
        settings.upsertOnlineService(OnlineService(
            id: "svc-b",
            name: "B",
            baseURL: "https://api.b.example",
            modelID: "model-b",
            isEnabled: true
        ))
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: settings,
            activeModel: nil
        )

        XCTAssertEqual(chat.onlineServiceID, "svc-b")
        XCTAssertEqual(chat.onlineModelID, "model-b")
        XCTAssertEqual(chat.activeModelLabel, "Online · B")

        settings.setOnlineServiceEnabled(id: "svc-a", enabled: true)
        XCTAssertEqual(chat.onlineServiceID, "svc-a")
        XCTAssertEqual(chat.onlineModelID, "model-a")
        XCTAssertEqual(chat.activeModelLabel, "Online · A")
    }

    /// The context meter for online runs uses the setting up to the service window, not a local
    /// checkpoint's native context (device RAM is not the online constraint).
    func testOnlineContextMeterUsesSettingUpToServiceWindow() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeOnlineSettings()
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: settings,
            activeModel: nil
        )

        settings.contextLength = 32_768
        XCTAssertEqual(chat.contextUsage().cap, 32_768)

        settings.contextLength = 400_000
        XCTAssertEqual(chat.contextUsage().cap, OnlineModelIdentity.maximumContextTokens)
    }
}
