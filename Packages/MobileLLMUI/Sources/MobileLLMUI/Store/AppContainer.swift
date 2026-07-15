// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import AppRuntime
import LLMCore

/// Composition root (DESIGN §2). Owns the four stores, wires the shared engine into both the chat and
/// the model manager, and keeps `ChatStore.activeModel` in sync with the resident model. The real
/// MLX-fork engine + `AppRuntime.ModelDownloader` are injected here at app assembly; previews + tests
/// inject `MockLLMEngine`.
@MainActor
@Observable
public final class AppContainer {
    public let settings: AppSettings
    public let conversationStore: ConversationStore
    public let models: ModelManager
    public let chat: ChatStore

    public init(engine: any LLMEngine,
                downloadBase: URL,
                downloader: @escaping ModelManager.Downloader,
                device: DeviceTier = .current,
                settings: AppSettings? = nil,
                conversationStore: ConversationStore? = nil,
                installProbe: @escaping @Sendable (LLMVariant, URL) -> Bool = ModelManager.defaultInstallProbe(),
                availableMemory: @escaping @Sendable () -> Int64 = { Int64(bitPattern: MemoryProbe.availableBytes()) }) {
        let settings = settings ?? AppSettings(fallbackDefaultModelID: LLMCatalog.defaultModel(for: device).id)
        let store = conversationStore ?? ConversationStore()
        self.settings = settings
        self.conversationStore = store
        self.models = ModelManager(engine: engine, device: device, downloadBase: downloadBase,
                                   downloader: downloader, installProbe: installProbe,
                                   availableMemory: availableMemory)
        self.chat = ChatStore(engine: engine, store: store, settings: settings)
    }

    /// Load persisted chats + install state, then auto-activate the default model if it's on disk.
    public func bootstrap() async {
        models.refreshInstalled()
        await chat.load()
        let model = LLMCatalog.model(id: settings.defaultModelID) ?? models.recommendedModel
        if let variant = model.variant(for: model.defaultVariant), models.isInstalled(variant) {
            await activateAndSync(model, variant, force: false, announce: false)
        }
        syncActive()
    }

    /// Activate a variant (Models → Use / Try anyway). Runs the OOM pre-flight; surfaces a recoverable
    /// banner on refusal (never a silent crash) and keeps the chat's active model in sync.
    public func activate(_ model: LLMModel, variant: LLMVariant, force: Bool) {
        Task { await activateAndSync(model, variant, force: force, announce: true) }
    }

    private func activateAndSync(_ model: LLMModel, _ variant: LLMVariant, force: Bool, announce: Bool) async {
        do {
            try await models.activate(model, variant: variant, context: settings.contextLength, force: force)
            syncActive()
            if announce { chat.showToast(Toast("\(model.displayName) is ready", kind: .success)) }
        } catch let error as ModelActivationError {
            chat.showToast(Toast(error.message, kind: .error, actionTitle: error.forwardTitle, autoDismiss: nil),
                           action: { [weak self] in self?.handleForwardAction(for: error) })
        } catch {
            chat.showToast(Toast(error.localizedDescription, kind: .error, autoDismiss: 4))
        }
    }

    private func handleForwardAction(for error: ModelActivationError) {
        switch error {
        case .insufficientMemory:
            // "Switch to 8B": activate the safe hero if it's installed.
            let safe = LLMCatalog.bonsai8b
            if let variant = safe.variant(for: .binary1bit), models.isInstalled(variant) {
                activate(safe, variant: variant, force: false)
            }
        case .notInstalled:
            break   // the Models screen's Download button handles this
        }
    }

    /// Mirror the resident model into the chat store so the composer + thread reflect it.
    public func syncActive() { chat.activeModel = models.active }
}
