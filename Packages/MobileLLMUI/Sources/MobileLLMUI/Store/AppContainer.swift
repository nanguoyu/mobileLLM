// SPDX-License-Identifier: MIT

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

    /// A one-shot navigation intent the shell (RootView) honors and clears — e.g. a "not installed" error
    /// banner jumping to Models. The container can't push tabs itself (RootView owns the section state).
    public var navigationRequest: AppSection?
    /// Raised by the macOS/iPad "Switch Model" menu command; the split shell shows the quick switcher.
    public var switcherRequested = false
    /// Guards `bootstrap()` so the App scene + RootView both awaiting it decode sessions / load the default
    /// model exactly once (DESIGN §2 — the two `.task` sites used to race).
    private var bootstrapTask: Task<Void, Never>?

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
        // Reload a suspended model right before the next turn (its memory is freed while idle).
        chat.ensureModelReady = { [weak self] in await self?.reloadIfSuspended() }
    }

    /// Free the resident model's weights while idle (app backgrounded, or the user left the chat), but
    /// keep the active-model identity so the next turn reloads it. On the 8 GB phone this is what stops
    /// a 5 GB model from being jetsam-killed in the background — and stops it hogging memory when unused.
    public func suspendModel() {
        guard !chat.isStreaming else { return }   // never unload mid-generation
        Task { await models.suspend(); syncActive() }
    }

    private func reloadIfSuspended() async {
        try? await models.ensureResident(context: settings.contextLength)
        syncActive()
    }

    /// Load persisted chats + install state, then auto-activate the default model if it's on disk.
    /// Idempotent: concurrent callers (the App scene and RootView both `.task`-await it at launch) share one
    /// run, so sessions never decode twice and the default model never loads back-to-back.
    public func bootstrap() async {
        if let bootstrapTask { return await bootstrapTask.value }
        let task = Task { await performBootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        // Merge persisted community (Explore) models before resolving the default, so an adopted default
        // and the storage/switcher lists see them (DESIGN §2.4). This also rescans install state.
        await models.loadAdoptedRegistry()
        await chat.load()
        let model = models.model(id: settings.defaultModelID) ?? models.recommendedModel
        if let variant = bootVariant(for: model) {
            await activateAndSync(model, variant, force: false, announce: false)
        }
        syncActive()
    }

    /// Which variant to auto-activate on launch. The user's engine preference (Settings → Inference
    /// engine) is honored — a persisted "llama.cpp" (or "MLX") choice is respected instead of always
    /// booting the MLX default — falling back to any installed variant so a prior download still boots.
    /// The engine is never silently overridden by a platform default.
    private func bootVariant(for model: LLMModel) -> LLMVariant? {
        let preferred = AppSettings.preferredVariant(for: model, device: models.device,
                                                     preference: settings.enginePreference,
                                                     context: settings.contextLength)
        if models.isInstalled(preferred) { return preferred }
        return model.variants.first { models.isInstalled($0) }
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
            presentActivationError(error, model: model, variant: variant, force: force)
        } catch {
            chat.showToast(Toast(error.localizedDescription, kind: .error, autoDismiss: 4))
        }
    }

    /// Turn an activation refusal into an actionable banner — never a dead end (DESIGN §2.5). Each carries
    /// a forward action, so it's always dismissable by acting on it (and the banner host also renders a
    /// close control for sticky banners).
    private func presentActivationError(_ error: ModelActivationError, model: LLMModel,
                                        variant: LLMVariant, force: Bool) {
        switch error {
        case .insufficientMemory:
            // Physically conceivable — the raw weights fit RAM, they're just over the LIVE free headroom
            // right now? Offer "Try anyway" (forced): the estimate is only an estimate and the device is
            // the authority. Only when the model can't fit RAM at all do we steer to the safe 8B instead.
            let conceivable = variant.onDiskBytes + variant.backend.runtimeOverheadBytes
                <= models.device.physicalMemoryBytes
            if conceivable, !force {
                chat.showToast(Toast(error.message, kind: .error, actionTitle: "Try anyway", autoDismiss: nil),
                               action: { [weak self] in self?.activate(model, variant: variant, force: true) })
            } else if let safe = safe8BVariant {
                chat.showToast(Toast(error.message, kind: .error, actionTitle: "Switch to 8B", autoDismiss: nil),
                               action: { [weak self] in self?.activate(LLMCatalog.bonsai8b, variant: safe, force: false) })
            } else {
                chat.showToast(Toast(error.message, kind: .error, autoDismiss: nil))
            }
        case .notInstalled:
            // The old "Download" forward did nothing. Jump to Models so the user can actually get it.
            chat.showToast(Toast(error.message, kind: .error, actionTitle: "Open Models", autoDismiss: nil),
                           action: { [weak self] in self?.navigationRequest = .models })
        }
    }

    /// The safe iPhone hero's installed variant (for the "Switch to 8B" fallback), or nil if it isn't down.
    private var safe8BVariant: LLMVariant? {
        let safe = LLMCatalog.bonsai8b
        guard let variant = safe.variant(for: .binary1bit) ?? safe.variants.first,
              models.isInstalled(variant) else { return nil }
        return variant
    }

    /// Mirror the resident model into the chat store so the composer + thread reflect it.
    public func syncActive() { chat.activeModel = models.active }
}
