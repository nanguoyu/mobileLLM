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
    /// The per-conversation skill packs (Skills v1). Persisted beside the conversation records + tool
    /// memory; surfaced to the composer's Skill menu and the management screen.
    public let skills: SkillStore
    /// The privacy-gated tool seams, also surfaced to the Tools settings screen so flipping a toggle can
    /// request the system permission right there (nil in tests/previews — the screen then skips prompting).
    public let toolEventStore: (any EventStoring)?
    public let toolLocationProvider: (any LocationProviding)?

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
                availableMemory: @escaping @Sendable () -> Int64 = { Int64(bitPattern: MemoryProbe.availableBytes()) },
                eventStore: (any EventStoring)? = nil,
                locationProvider: (any LocationProviding)? = nil) {
        let settings = settings ?? AppSettings(fallbackDefaultModelID: LLMCatalog.defaultModel(for: device).id)
        let store = conversationStore ?? ConversationStore()
        self.settings = settings
        self.conversationStore = store
        self.models = ModelManager(engine: engine, device: device, downloadBase: downloadBase,
                                   downloader: downloader, installProbe: installProbe,
                                   availableMemory: availableMemory)
        // Tool seams for the agent loop. The memory store lives beside the conversation records (durable +
        // atomic — losing saved facts is annoying). The privacy-gated calendar / location adapters are
        // injected by the app-assembly layer (the App scene), NOT constructed here, so previews and unit
        // tests never touch EventKit / CoreLocation. They request TCC access only lazily, on first tool
        // invocation, and are only assembled into the registry when the user enables that tool (off by default).
        let memoryStore = MemoryStore(fileURL: store.directory.appending(component: "memory.json"))
        // Skills live beside memory.json (same durable, atomic store) so a thread's activated skill survives
        // relaunch and a corrupt file is backed up, not wiped.
        let skillStore = SkillStore(fileURL: store.directory.appending(component: "skills.json"))
        self.skills = skillStore
        self.toolEventStore = eventStore
        self.toolLocationProvider = locationProvider
        self.chat = ChatStore(engine: engine, store: store, settings: settings,
                              memoryStore: memoryStore, eventStore: eventStore,
                              locationProvider: locationProvider, skillStore: skillStore)
        // Reload a suspended model right before the next turn (its memory is freed while idle).
        chat.ensureModelReady = { [weak self] in await self?.reloadIfSuspended() }
        // Opening a conversation brings back ITS model (when installed) instead of whatever is resident —
        // a thread's identity includes the model it was talked to with.
        chat.restoreModel = { [weak self] modelID, variantID in
            self?.restoreConversationModel(modelID: modelID, variantID: variantID)
        }
    }

    /// Activate the (model, variant) a conversation remembers, if it's still installed. Falls back to any
    /// installed variant of the same model (the exact quant may have been deleted); silently keeps the
    /// resident model when nothing of it is on disk — the header + switcher make that visible.
    private func restoreConversationModel(modelID: String, variantID: String) {
        guard !models.switching, let model = models.model(id: modelID) else { return }
        let variant = model.variants.first { $0.id == variantID && models.isInstalled($0) }
                   ?? model.variants.first { models.isInstalled($0) }
        guard let variant, models.active?.variant.id != variant.id else { return }
        activate(model, variant: variant, force: false)
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
        await skills.load()   // seed the built-in skills on first launch, else read them back from disk
        await chat.load()
        // Boot into the model the ACTIVE conversation was using (when installed) — falling back to the
        // last-used default. One activation either way; a thread must not silently switch models just
        // because the app relaunched.
        let (model, variant) = bootTarget()
        if let variant {
            await activateAndSync(model, variant, force: false, announce: false)
        }
        // The boot pick can still fail (the OOM pre-flight refusing a big vision model on a cold start,
        // a half-deleted download…). "No model" with installed weights on disk is a dead end — fall back
        // to the smallest installed variant of anything, which always loads if anything can.
        if models.active == nil, let fallback = smallestInstalledFallback(excluding: variant?.id) {
            await activateAndSync(fallback.0, fallback.1, force: false, announce: false)
        }
        syncActive()
    }

    /// The smallest installed (model, variant) on disk — the boot fallback that keeps the header from
    /// reading "No model" when weights exist. Excludes the variant that just failed.
    private func smallestInstalledFallback(excluding failedID: String?) -> (LLMModel, LLMVariant)? {
        models.allModels
            .flatMap { model in model.variants.map { (model, $0) } }
            .filter { $0.1.id != failedID && models.isInstalled($0.1) }
            .min { $0.1.onDiskBytes < $1.1.onDiskBytes }
    }

    /// The launch activation target: the active conversation's remembered (model, variant) if that model
    /// still has an installed variant, else the Settings default via the engine-preference policy.
    private func bootTarget() -> (LLMModel, LLMVariant?) {
        if let convo = chat.activeConversation, !convo.modelID.isEmpty,
           let remembered = models.model(id: convo.modelID) {
            let variant = remembered.variants.first { $0.id == convo.variantID && models.isInstalled($0) }
                       ?? remembered.variants.first { models.isInstalled($0) }
            if let variant { return (remembered, variant) }
        }
        let model = models.model(id: settings.defaultModelID) ?? models.recommendedModel
        return (model, bootVariant(for: model))
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
            // "Default model" is not a setting anymore — it auto-tracks the last successfully used model,
            // so a fresh launch (or a brand-new thread) lands on what you were actually using.
            settings.defaultModelID = model.id
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
        case .engineUnavailable:
            // Environment limit (MLX in the simulator) — nothing to retry; say it and stop.
            chat.showToast(Toast(error.message, kind: .error, autoDismiss: 5))
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
