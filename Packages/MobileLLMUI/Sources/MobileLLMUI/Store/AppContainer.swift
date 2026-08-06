// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime
import LLMCore
import AgentRuntime

/// Composition root (DESIGN §2). Owns the four stores, wires the shared engine into both the chat and
/// the model manager, and keeps `ChatStore.activeModel` in sync with the selected model. The real
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
    /// What the assistant remembers about the user — the durable memory store's main-actor mirror, shared
    /// by the memory screen (Settings → Behavior → Memory) and `ChatStore`'s prompt injector.
    public let memory: MemoryBook
    /// Multi-scene lifecycle aggregation + finite background drain (spec §19.1).
    public let lifecycle: LifecycleCoordinator
    /// Explicit, bounded continued background processing (spec §19.2).
    public let continuedProcessing: ContinuedProcessingCoordinator
    /// Durable workflow summaries + orchestrator recording seam (spec §23/§23.1).
    public let workflowStore: WorkflowStore
    /// The privacy-gated tool seams, also surfaced to the Tools settings screen so flipping a toggle can
    /// request the system permission right there (nil in tests/previews — the screen then skips prompting).
    public let toolEventStore: (any EventStoring)?
    public let toolLocationProvider: (any LocationProviding)?
    /// OpenAI Responses API key store (Keychain-backed in the app; injectable for tests/previews).
    public let openAICredentials: any OpenAICredentialStoring
    /// The durable agent runtime projection and command surface (spec §20). Nil keeps the legacy
    /// in-process loop (tests/previews and the rollout-off state).
    public private(set) var agentRuns: AgentRunStore?
    /// When the agent runtime failed to assemble, the reason (rollout-off state stays functional).
    public private(set) var agentRuntimeError: String?
    /// App-assembled hook that returns the bounded redacted agent-runtime log (diagnostics only).
    public var agentDiagnosticSnapshot: (@MainActor () async -> String)?
    /// Explicit MCP discovery cache shared by the settings UI (writer) and the agent catalog (reader).
    public let mcpDiscovery = MCPDiscoveryCache.shared

    /// A one-shot navigation intent the shell (RootView) honors and clears — e.g. a "not installed" error
    /// banner jumping to Models. The container can't push tabs itself (RootView owns the section state).
    public var navigationRequest: AppSection?
    /// Raised by the macOS/iPad "Switch Model" menu command; the split shell shows the quick switcher.
    public var switcherRequested = false
    /// Guards `bootstrap()` so the App scene + RootView both awaiting it decode sessions / restore the
    /// default selection exactly once (DESIGN §2 — the two `.task` sites used to race).
    private var bootstrapTask: Task<Void, Never>?
    /// The in-flight conversation-model restore, and the generation that owns it. Selecting another thread
    /// bumps the generation: a superseded restore must neither win the engine nor rewrite the newly
    /// selected thread's remembered identity when it completes late.
    private var conversationRestoreTask: Task<Void, Never>?
    private var conversationRestoreGeneration: UInt64 = 0
    private struct ConversationRestoreRequest: Equatable {
        let conversationID: UUID
        let modelID: String
        let variantID: String
    }
    private var conversationRestoreRequest: ConversationRestoreRequest?

    public init(engine: any LLMEngine,
                downloadBase: URL,
                downloader: @escaping ModelManager.Downloader,
                device: DeviceTier = .current,
                settings: AppSettings? = nil,
                conversationStore: ConversationStore? = nil,
                memoryStore: (any MemoryStoring)? = nil,
                installProbe: @escaping @Sendable (LLMVariant, URL) -> Bool = ModelManager.defaultInstallProbe(),
                systemModelProbe: @escaping @Sendable () -> SystemModelStatus = { .unavailable(.unsupportedOS) },
                availableMemory: @escaping @Sendable () -> Int64 = { Int64(bitPattern: MemoryProbe.availableBytes()) },
                eventStore: (any EventStoring)? = nil,
                locationProvider: (any LocationProviding)? = nil,
                openAICredentials: (any OpenAICredentialStoring)? = nil,
                agentRuns: AgentRunStore? = nil,
                lifecycle: LifecycleCoordinator? = nil,
                continuedProcessing: ContinuedProcessingCoordinator? = nil,
                workflowStore: WorkflowStore? = nil) {
        let settings = settings ?? AppSettings(fallbackDefaultModelID: LLMCatalog.defaultModel(for: device).id)
        let store = conversationStore ?? ConversationStore()
        self.settings = settings
        self.lifecycle = lifecycle ?? LifecycleCoordinator()
        self.continuedProcessing = continuedProcessing
            ?? ContinuedProcessingCoordinator()
        self.workflowStore = workflowStore ?? WorkflowStore(directory: store.directory)
        self.conversationStore = store
        self.models = ModelManager(engine: engine, device: device, downloadBase: downloadBase,
                                   downloader: downloader, installProbe: installProbe,
                                   systemModelProbe: systemModelProbe,
                                   availableMemory: availableMemory)
        // Tool seams for the agent loop. The memory store lives beside the conversation records (durable +
        // atomic — losing saved facts is annoying). The privacy-gated calendar / location adapters are
        // injected by the app-assembly layer (the App scene), NOT constructed here, so previews and unit
        // tests never touch EventKit / CoreLocation. They request TCC access only lazily, on first tool
        // invocation, and are only assembled into the registry when the user enables that tool (off by default).
        // Injectable like the conversation store, so previews + tests seed facts in memory instead of
        // writing a JSON file (and never race the app's real one).
        let memory = memoryStore ?? MemoryStore(fileURL: store.directory.appending(component: "memory.json"))
        // One book over that store: the tools write to the store, the memory screen and the prompt injector
        // read the book's mirror of it (see `MemoryBook`).
        let memoryBook = MemoryBook(store: memory)
        self.memory = memoryBook
        // Skills live beside memory.json (same durable, atomic store) so a thread's activated skill survives
        // relaunch and a corrupt file is backed up, not wiped.
        let skillStore = SkillStore(fileURL: store.directory.appending(component: "skills.json"))
        self.skills = skillStore
        self.toolEventStore = eventStore
        self.toolLocationProvider = locationProvider
        self.openAICredentials = openAICredentials ?? KeychainOpenAICredentialStore()
        self.agentRuns = agentRuns
        self.chat = ChatStore(engine: engine, store: store, settings: settings,
                              memoryBook: memoryBook, eventStore: eventStore,
                              locationProvider: locationProvider, skillStore: skillStore,
                              agentRuns: agentRuns,
                              workflowStore: self.workflowStore)
        // Cold launch restores identity only, so the first turn is where the weights are actually loaded.
        // A false answer stops the turn instead of generating against an empty engine.
        chat.ensureModelReady = { [weak self] in
            await self?.reloadIfSuspended() ?? false
        }
        // Opening a conversation brings back ITS model (when installed) instead of whatever is resident —
        // a thread's identity includes the model it was talked to with.
        chat.restoreModel = { [weak self] modelID, variantID in
            self?.restoreConversationModel(modelID: modelID, variantID: variantID)
        }
        chat.cancelModelRestore = { [weak self] in
            self?.cancelConversationModelRestore()
        }
        // Same resolver the restore itself uses, so "does this thread's variant differ?" cannot disagree
        // with what restoration would actually load.
        chat.resolvePersistedVariantID = { [weak self] modelID, variantID in
            self?.resolvedInstalledVariant(modelID: modelID, persistedID: variantID)?.id
        }
        // ModelsView owns ModelManager directly, so deletion does not pass through an AppContainer
        // wrapper. Mirror every selection mutation at its source; use the conservative no-reseed mode and
        // let explicit Use operations opt into reseeding only after their activation succeeds.
        models.activeModelDidChange = { [weak self] model in
            self?.chat.synchronizeActiveModel(model, reseedEmptyConversation: false)
        }
    }

    /// Attaches the durable agent runtime after the container exists (the runtime snapshots this
    /// container's stores at submission time, so wiring happens post-init at app assembly).
    public func attachAgentRuns(_ agentRuns: AgentRunStore) {
        self.agentRuns = agentRuns
        chat.attachAgentRuntime(agentRuns)
        // Lifecycle wiring (spec §19.1): the coordinator drives admission, quiescence, and weight
        // unloading through the same stores the UI uses, so tests exercise the real seam.
        lifecycle.quiesce = { [weak self] in
            await self?.chat.agentRuns?.quiesceForBackground()
        }
        lifecycle.stopAdmittingActions = { [weak self] in
            self?.chat.setAcceptingNewActions(false)
        }
        lifecycle.resumeAdmittingActions = { [weak self] in
            self?.chat.setAcceptingNewActions(true)
        }
        lifecycle.suspendModel = { [weak self] in
            self?.suspendModel()
        }
        // Continued-processing wiring (spec §19.2): submit eligible runs when they start, settle the
        // system task when they terminate, and keep progress truthful.
        continuedProcessing.quiesce = { [weak self] in
            await self?.chat.agentRuns?.quiesceForBackground()
        }
        continuedProcessing.cancelRun = { [weak self] conversationID in
            await self?.chat.agentRuns?.cancel(conversationID: conversationID)
        }
        continuedProcessing.progressFraction = { [weak self] conversationID in
            self?.chat.agentRuns?.presentation(for: conversationID)?.progressFraction
        }
        continuedProcessing.isRunEligible = { [weak self] conversationID in
            guard let run = self?.chat.agentRuns?.presentation(for: conversationID) else { return false }
            return run.isActive && !run.isWaiting
        }
        continuedProcessing.requiresGPUForRun = { [weak self] conversationID in
            guard let self else { return false }
            // Online runs have no local weights; only the resident local MLX engine needs GPU.
            if self.chat.isOnlineActive { return false }
            return self.chat.activeModel?.variant.engine == .mlx
        }
        continuedProcessing.isEnabled = { [weak self] in
            self?.settings.continuedProcessingEnabled ?? false
        }
        agentRuns.onProgressTick = { [weak self] conversationID in
            self?.continuedProcessing.refreshProgress(conversationID: conversationID)
        }
        chat.onAgentRunStarted = { [weak self] conversationID in
            self?.continuedProcessing.submitIfEligible(conversationID: conversationID)
        }
        chat.onAgentRunTerminal = { [weak self] conversationID, _ in
            self?.continuedProcessing.runFinished(conversationID: conversationID)
        }
    }

    /// Records why the agent runtime could not be assembled (diagnostics only; the legacy loop
    /// remains the fallback).
    public func recordAgentRuntimeFailure(_ error: Error) {
        agentRuntimeError = error.localizedDescription
    }

    /// Activate the (model, variant) a conversation remembers, if it's still installed. Falls back to any
    /// installed variant of the same model (the exact quant may have been deleted); silently keeps the
    /// resident model when nothing of it is on disk — the header + switcher make that visible.
    private func restoreConversationModel(modelID: String, variantID: String) {
        guard let conversationID = chat.activeID,
              let model = models.model(id: modelID),
              let variant = resolvedInstalledVariant(modelID: modelID, persistedID: variantID) else { return }
        let request = ConversationRestoreRequest(conversationID: conversationID,
                                                 modelID: model.id,
                                                 variantID: variant.id)
        // ConversationListView.select() and ChatDetailView.onAppear are two UI events for one navigation.
        // If the first event already owns this exact restore, the second joins it by doing nothing: in
        // particular it must not cancel a non-cooperative multi-GB load and enqueue the same load again.
        if conversationRestoreTask != nil, conversationRestoreRequest == request { return }

        cancelConversationModelRestore()
        // Already the selected artifact: mirror it (a legacy id may have resolved onto it) and stop.
        guard models.active?.variant.id != variant.id else {
            syncActive(reseedEmptyConversation: false)
            return
        }
        // Deliberately NOT guarded on `models.switching`: selecting B while A is still loading must still
        // restore B. ModelManager serializes the two loads; the newest request is the one that wins.
        conversationRestoreGeneration &+= 1
        let generation = conversationRestoreGeneration
        conversationRestoreRequest = request
        conversationRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == conversationRestoreGeneration {
                    conversationRestoreTask = nil
                    conversationRestoreRequest = nil
                }
            }
            do {
                try await models.activate(model, variant: variant, context: settings.contextLength)
                try Task.checkCancellation()
                // A superseded restore must not rewrite the thread the user has since selected.
                guard generation == conversationRestoreGeneration,
                      chat.activeID == conversationID,
                      chat.activeConversation?.modelID == modelID,
                      let current = resolvedInstalledVariant(
                        modelID: modelID,
                        persistedID: chat.activeConversation?.variantID ?? ""),
                      current.id == variant.id else { return }
                syncActive(reseedEmptyConversation: false)
                settings.defaultModelID = model.id
            } catch is CancellationError {
                // Superseded by a newer selection — the newer one owns the engine and the banner.
            } catch let error as ModelActivationError {
                guard generation == conversationRestoreGeneration else { return }
                presentActivationError(error)
            } catch {
                guard generation == conversationRestoreGeneration else { return }
                chat.showToast(Toast(error.localizedDescription, kind: .error, autoDismiss: 4))
            }
        }
    }

    /// Invalidate the in-flight restore (a newer selection arrived, or an erase is starting).
    private func cancelConversationModelRestore() {
        conversationRestoreGeneration &+= 1
        conversationRestoreTask?.cancel()
        conversationRestoreTask = nil
        conversationRestoreRequest = nil
    }

    /// The installed variant a persisted id names. An exact artifact id wins; otherwise the id is a legacy
    /// alias that can match several quants of one repository, so the choice is made deterministically (by
    /// sorted id) rather than from whatever happens to be resident. An empty id means "any installed
    /// variant of this model", and a variant that was deleted since falls back the same way.
    private func resolvedInstalledVariant(modelID: String, persistedID: String) -> LLMVariant? {
        guard let model = models.model(id: modelID) else { return nil }
        let installed = model.variants.filter { models.isInstalled($0) }
        if let exact = installed.first(where: { $0.id == persistedID }) { return exact }
        let stable = installed.sorted { $0.id < $1.id }
        guard !persistedID.isEmpty else { return stable.first }
        if let legacy = stable.first(where: { $0.matchesPersistedID(persistedID) }) { return legacy }
        return stable.first
    }

    /// Free the resident model's weights while idle (app backgrounded, or the user left the chat), but
    /// keep the active-model identity so the next turn reloads it. On the 8 GB phone this is what stops
    /// a 5 GB model from being jetsam-killed in the background — and stops it hogging memory when unused.
    public func suspendModel() {
        guard !chat.isStreaming else { return }   // never unload mid-generation
        Task { await models.suspend(); syncActive() }
    }

    /// Bring the selected model's weights back before a turn. Returns false when they could not become
    /// resident, so `ChatStore` stops the turn at that boundary instead of generating on an empty engine.
    private func reloadIfSuspended() async -> Bool {
        do {
            try await models.ensureResident(context: settings.contextLength)
            syncActive()
            return true
        } catch is CancellationError {
            // An erase or a newer switch took the engine; that path owns whatever the user sees next.
            return false
        } catch let error as ModelActivationError {
            let hadSelection = models.active != nil
            // A selection whose weights were deleted between turns must stop claiming the header, or
            // every later send fails against a model the user can't see is gone.
            if hadSelection, case .notInstalled = error { await models.deactivate() }
            syncActive()
            presentActivationError(error)
            return false
        } catch {
            chat.showToast(Toast(error.localizedDescription, kind: .error, autoDismiss: 4))
            return false
        }
    }

    /// Load the persisted chat LIST + install state, then restore only the default model identity without
    /// allocating its weights. No conversation is selected at launch; selecting history restores that
    /// thread's model later, and the first generation performs the real resident load.
    /// Idempotent: concurrent callers (the App scene and RootView both `.task`-await it at launch) share one
    /// run, so sessions never decode twice or repeat legacy-manifest audits.
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
        do {
            try await skills.load()   // seed the built-in skills on first launch, else read them back from disk
        } catch {
            chat.showToast(Toast("Skills couldn't be loaded: \(error.localizedDescription)",
                                 kind: .error, autoDismiss: 4))
        }
        await memory.refresh()   // the first send composes its memory block from this mirror
        await chat.load()
        // Selection only: allocating several GB before the first frame is what made a cold launch feel
        // frozen (and, on the phone, what got the process jetsammed for merely being opened).
        let (model, variant) = bootTarget()
        if let variant {
            models.restoreSelection(model, variant: variant)
        }
        // "No model" with weights on disk is a dead end — fall back to the smallest installed variant of
        // anything, which is the one most likely to load when the user finally sends.
        if models.active == nil, let fallback = smallestInstalledFallback(excluding: variant?.id) {
            models.restoreSelection(fallback.0, variant: fallback.1)
        }
        // Bootstrap is hydration, not a user model switch. If a new empty conversation was created while
        // the other stores were loading, restoring the launch identity must not rewrite that live thread.
        syncActive(reseedEmptyConversation: false)
    }

    /// The smallest installed (model, variant) on disk — the boot fallback that keeps the header from
    /// reading "No model" when weights exist. Excludes the variant that was already tried.
    private func smallestInstalledFallback(excluding failedID: String?) -> (LLMModel, LLMVariant)? {
        models.allModels
            .flatMap { model in model.variants.map { (model, $0) } }
            .filter { $0.1.id != failedID && models.isInstalled($0.1) }
            // Smallest first (most likely to load) — but a model the user actually DOWNLOADED outranks the
            // OS's own, which is 0 bytes and would otherwise always win on size and quietly displace their
            // choice. The system model stays the last resort, which is exactly its value here: when it's
            // available, it always loads.
            .min { a, b in
                if a.1.isSystemProvided != b.1.isSystemProvided { return !a.1.isSystemProvided }
                return a.1.totalOnDiskBytes < b.1.totalOnDiskBytes
            }
    }

    /// The launch selection target: the Settings default (which auto-tracks the last used model) via the
    /// engine-preference policy. A historical thread's model is restored when that thread is opened, not
    /// at launch — launch deliberately enters no conversation.
    private func bootTarget() -> (LLMModel, LLMVariant?) {
        let model = models.model(id: settings.defaultModelID) ?? models.recommendedModel
        return (model, bootVariant(for: model))
    }

    /// Which variant to select on launch. The user's engine preference (Settings → Inference engine) is
    /// honored — a persisted "llama.cpp" (or "MLX") choice is respected instead of always booting the MLX
    /// default — falling back to any installed variant so a prior download still boots. The engine is
    /// never silently overridden by a platform default.
    private func bootVariant(for model: LLMModel) -> LLMVariant? {
        let preferred = AppSettings.preferredVariant(for: model, device: models.device,
                                                     preference: settings.enginePreference,
                                                     context: settings.contextLength)
        if models.isInstalled(preferred) { return preferred }
        return model.variants.first { models.isInstalled($0) }
    }

    /// Activate a variant (Models → Use). Every installed model is actually attempted; fit estimates are
    /// informational and never produce a safety refusal.
    public func activate(_ model: LLMModel, variant: LLMVariant) {
        // An explicit choice supersedes a conversation restore that is still loading.
        cancelConversationModelRestore()
        Task { await activateAndSync(model, variant, announce: true, reseedEmptyConversation: true) }
    }

    /// Compatibility shim for embedders compiled against the former bypass API. `force` has no effect
    /// because there is no memory gate to bypass.
    public func activate(_ model: LLMModel, variant: LLMVariant, force: Bool) {
        activate(model, variant: variant)
    }

    private func activateAndSync(_ model: LLMModel, _ variant: LLMVariant, announce: Bool,
                                 reseedEmptyConversation: Bool) async {
        do {
            try await models.activate(model, variant: variant, context: settings.contextLength)
            syncActive(reseedEmptyConversation: reseedEmptyConversation)
            // "Default model" is not a setting anymore — it auto-tracks the last successfully used model,
            // so a fresh launch (or a brand-new thread) lands on what you were actually using.
            settings.defaultModelID = model.id
            if announce { chat.showToast(Toast("\(model.displayName) is ready", kind: .success)) }
        } catch is CancellationError {
            // Superseded by a newer switch, or the data-erase gate: neither is the user's problem.
        } catch let error as ModelActivationError {
            presentActivationError(error)
        } catch {
            chat.showToast(Toast(error.localizedDescription, kind: .error, autoDismiss: 4))
        }
    }

    /// Turn an activation refusal into an actionable banner — never a dead end (DESIGN §2.5). Each carries
    /// a forward action, so it's always dismissable by acting on it (and the banner host also renders a
    /// close control for sticky banners).
    private func presentActivationError(_ error: ModelActivationError) {
        switch error {
        case .notInstalled, .noSelection:
            // There is something to do about both: get the weights, or pick a model that has them.
            chat.showToast(Toast(error.message, kind: .error, actionTitle: "Open Models", autoDismiss: nil),
                           action: { [weak self] in self?.navigationRequest = .models })
        case .engineUnavailable:
            // Environment limit (MLX in the simulator) — nothing to retry; say it and stop.
            chat.showToast(Toast(error.message, kind: .error, autoDismiss: 5))
        }
    }

    /// Mirror the selected model into the chat store; residency is managed independently.
    public func syncActive(reseedEmptyConversation: Bool = true) {
        chat.synchronizeActiveModel(models.active, reseedEmptyConversation: reseedEmptyConversation)
    }
}
