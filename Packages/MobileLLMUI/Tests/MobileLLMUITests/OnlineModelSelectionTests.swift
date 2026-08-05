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

        settings.onlineContextLength = 32_768
        XCTAssertEqual(chat.contextUsage().cap, 32_768)

        settings.onlineContextLength = 400_000
        XCTAssertEqual(chat.contextUsage().cap, OnlineModelIdentity.maximumContextTokens)
    }

    /// "Allow reasoning" is a per-conversation override: the composer toggle writes the thread's own
    /// value (defaulting to the service setting) instead of mutating the global service config.
    func testOnlineReasoningIsPerConversation() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "online-reason-\(UUID().uuidString)")!)
        settings.thinkingDefault = true   // the global default new conversations inherit
        settings.upsertOnlineService(OnlineService(
            id: OnlineService.defaultID,
            name: "Gateway",
            baseURL: "https://gateway.example.com/v1",
            modelID: "gateway-model",
            isEnabled: true
        ))
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: settings,
            activeModel: nil
        )

        // Fresh online thread: no override yet, so it follows the global Thinking default.
        let convo = chat.newConversation()
        XCTAssertEqual(chat.composerThinkingEnabled, true)
        XCTAssertNil(convo?.onlineReasoningEnabled)

        // Toggle in the composer persists ONLY this thread's override.
        chat.composerThinkingEnabled = false
        XCTAssertEqual(chat.onlineReasoningEnabled, false)
        XCTAssertEqual(chat.activeConversation?.onlineReasoningEnabled, false)
        XCTAssertEqual(
            settings.thinkingDefault,
            true,
            "the per-conversation toggle must not change the global default"
        )

        // Make the first thread non-empty so the next New Chat creates a fresh thread, which must
        // start from the global default again (no override carried over).
        if let idx = chat.conversations.firstIndex(where: { $0.id == chat.activeID }) {
            chat.conversations[idx].messages.append(Message(role: .user, answer: "hi"))
        }
        chat.newConversation()
        XCTAssertEqual(chat.composerThinkingEnabled, true)
        XCTAssertNil(chat.activeConversation?.onlineReasoningEnabled)
    }

    /// Context length is a per-conversation override for BOTH online and local threads: the override
    /// persists on the conversation, new threads fall back to the global default, and local runs are
    /// still clamped by the checkpoint's native context.
    func testConversationContextOverridePersistsPerThread() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeOnlineSettings()
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: settings,
            activeModel: nil
        )
        chat.newConversation()

        XCTAssertEqual(chat.onlineContextRequest, 32_768, "online default is 32K, not the local 8K")
        chat.setConversationContextLength(65_536)
        XCTAssertEqual(chat.conversationContextOverride, 65_536)
        XCTAssertEqual(chat.onlineContextRequest, 65_536)
        XCTAssertEqual(chat.contextUsage().cap, 65_536)

        // A fresh thread starts from the global default again.
        if let idx = chat.conversations.firstIndex(where: { $0.id == chat.activeID }) {
            chat.conversations[idx].messages.append(Message(role: .user, answer: "hi"))
        }
        chat.newConversation()
        XCTAssertNil(chat.conversationContextOverride)
        XCTAssertEqual(chat.onlineContextRequest, 32_768)

        // Local thread: override is clamped by the model's native context.
        let localSettings = AppSettings(defaults: UserDefaults(suiteName: "local-ctx-\(UUID().uuidString)")!)
        localSettings.contextLength = 8_192
        let localChat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: localSettings,
            activeModel: LoadedModel(
                model: LLMCatalog.bonsai8b,
                variant: LLMCatalog.bonsai8b.defaultVariantValue
            )
        )
        localChat.newConversation()
        localChat.setConversationContextLength(4_096)
        XCTAssertEqual(localChat.localContextRequest, 4_096)
        XCTAssertEqual(localChat.contextUsage().cap, 4_096)
        localChat.setConversationContextLength(65_536)
        XCTAssertEqual(
            localChat.contextUsage().cap,
            ContextPolicy.effective(requested: 65_536, model: LLMCatalog.bonsai8b),
            "local context stays clamped by the checkpoint's native window"
        )
    }

    /// Sampling (temperature / top-p / max tokens) is a per-conversation override: each field can be
    /// pinned or reset to "follow the global setting" without touching the shared Settings.
    func testConversationSamplingOverridesPersistPerThread() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeOnlineSettings()
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: settings,
            activeModel: nil
        )
        chat.newConversation()

        XCTAssertEqual(chat.conversationTemperature, settings.temperature, accuracy: 0.0001)
        XCTAssertEqual(chat.conversationMaxTokens, settings.maxTokens)

        chat.setConversationTemperature(0.2)
        chat.setConversationMaxTokens(2_048)
        XCTAssertEqual(chat.conversationTemperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(chat.conversationMaxTokens, 2_048)
        XCTAssertEqual(chat.conversationTopP, settings.topP, accuracy: 0.0001)
        XCTAssertEqual(chat.conversationSamplingOverride?.temperature, 0.2)

        // Resetting one field returns it to the global default while the other override survives.
        chat.setConversationTemperature(nil)
        XCTAssertEqual(chat.conversationTemperature, settings.temperature, accuracy: 0.0001)
        XCTAssertEqual(chat.conversationMaxTokens, 2_048)
        XCTAssertEqual(chat.conversationSamplingOverride?.maxTokens, 2_048)
    }

    /// Approval mode is per-conversation (nil = ask) and persists on the thread record.
    func testConversationApprovalModePersistsPerThread() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init()),
            store: store,
            settings: makeOnlineSettings(),
            activeModel: nil
        )
        chat.newConversation()

        XCTAssertNil(chat.conversationApprovalMode, "new conversations default to ask")
        chat.conversationApprovalMode = .fullAccess
        XCTAssertEqual(chat.conversationApprovalMode, .fullAccess)
        XCTAssertEqual(chat.activeConversation?.approvalMode, .fullAccess)

        chat.conversationApprovalMode = .safePreset
        XCTAssertEqual(chat.activeConversation?.approvalMode, .safePreset)

        chat.conversationApprovalMode = nil
        XCTAssertNil(chat.conversationApprovalMode)
    }
}
