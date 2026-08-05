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
            OnlineModelIdentity.conversationModelID("gateway-model"),
            "online.responses:gateway-model"
        )
        XCTAssertEqual(
            OnlineModelIdentity.serviceModel(fromConversationModelID: "online.responses:gateway-model"),
            "gateway-model"
        )
        XCTAssertNil(OnlineModelIdentity.serviceModel(fromConversationModelID: "bonsai-8b"))
        XCTAssertNil(OnlineModelIdentity.serviceModel(fromConversationModelID: "online.responses:"))
        XCTAssertEqual(OnlineModelIdentity.displayLabel("gateway-model"), "Online · gateway-model")
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
        XCTAssertEqual(chat.activeModelLabel, "Online · gateway-model")
        chat.draft = "hello"
        XCTAssertTrue(chat.canSend)

        let convo = chat.newConversation()
        XCTAssertEqual(convo?.modelID, "online.responses:gateway-model")
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
        XCTAssertEqual(convo?.modelID, "online.responses:gateway-model")

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
}
