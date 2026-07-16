// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime
import LLMCore
#if canImport(UIKit)
import UIKit   // isIdleTimerDisabled — keep the phone awake during active downloads only
#endif

/// Recoverable failures raised before/around a resident load (DESIGN §2.5). Never a silent crash —
/// each carries a forward action so the UI never dead-ends.
public enum ModelActivationError: Error, Equatable {
    /// OOM pre-flight refused: live headroom is below the estimated resident peak.
    case insufficientMemory(needed: Int64, available: Int64)
    /// The variant's weights aren't on disk yet.
    case notInstalled

    public var message: String {
        switch self {
        case let .insufficientMemory(needed, available):
            let f = ByteCountFormatter()
            return "Not enough free memory right now (needs ~\(f.string(fromByteCount: needed)), "
                 + "\(f.string(fromByteCount: available)) free). Close other apps, or try it anyway."
        case .notInstalled:
            return "Download this model before switching to it."
        }
    }

    public var forwardTitle: String? {
        switch self {
        case .insufficientMemory: "Switch to 8B"
        case .notInstalled: "Download"
        }
    }
}

/// Per-variant download progress surfaced to the UI (bytes/speed/ETA via `DownloadMeter`).
public struct VariantDownload {
    public var fraction: Double = 0
    public var meter: DownloadMeter = DownloadMeter()
    public var isPaused: Bool = false
    public var error: String?
}

/// Coordinates the model catalog: install state, memory fit, download (foreground, resumable), and
/// the single resident activation (DESIGN §2.5 / §4). MLX-free: it calls the injected `LLMEngine`
/// protocol to load, and an injected downloader closure so the real `AppRuntime.ModelDownloader`
/// wires in at app assembly.
@MainActor
@Observable
public final class ModelManager {

    /// Fetch a repo's weights. `matching` restricts which files are pulled (empty = the whole flat
    /// repo — the MLX case; a one-entry glob = a single GGUF file — the llama.cpp case).
    public typealias Downloader = @Sendable (_ repoId: String, _ matching: [String],
                                             _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void

    public let catalog: [LLMModel] = LLMCatalog.all
    public let device: DeviceTier

    /// Community models adopted from the Explore tier (Hugging Face browse). Kept separate from the
    /// curated `catalog` but flow through the same download / fit / activate path once adopted. Persisted
    /// so a downloaded community model survives relaunch instead of vanishing from every list (§2.4).
    public private(set) var exploreModels: [LLMModel] = []
    /// Curated + adopted-explore models — the set install state is scanned over.
    public var allModels: [LLMModel] { catalog + exploreModels }

    /// Look a model up across BOTH curated + adopted models (the default-model menu / switcher / bootstrap
    /// resolve adopted ids too, not just the catalog).
    public func model(id: String) -> LLMModel? { allModels.first { $0.id == id } }

    /// Register a discovered model so it participates in install tracking + activation. Idempotent.
    /// Persists the adopted registry when the model has weights on disk (a merely-browsed model isn't
    /// worth keeping across launches — it can be re-browsed).
    public func adopt(_ model: LLMModel) {
        guard !allModels.contains(where: { $0.id == model.id }) else { return }
        exploreModels.append(model)
        refreshInstalled()
        persistAdoptedRegistry()
    }

    /// Load the persisted adopted-model registry and merge it into `exploreModels`, then rescan install
    /// state. Called once at bootstrap so downloaded community models reappear in the switcher / Settings /
    /// storage total. Idempotent — an id already present (curated or adopted) is skipped.
    public func loadAdoptedRegistry() async {
        let persisted = await registryStore.load()
        for model in persisted where !allModels.contains(where: { $0.id == model.id }) {
            exploreModels.append(model)
        }
        refreshInstalled()
    }

    /// Persist the adopted models that are actually worth keeping: those with at least one variant on disk
    /// (or downloading). Fire-and-forget — a failed write just means the registry rebuilds next adopt.
    private func persistAdoptedRegistry() {
        let keep = exploreModels.filter { model in
            model.variants.contains { installed.contains($0.id) || downloads[$0.source.huggingFaceRepo] != nil }
        }
        let store = registryStore
        Task { try? await store.save(keep) }
    }

    /// Repo ids of variants present on disk.
    public internal(set) var installed: Set<String> = []
    /// The resident model, if any (one active model — decode is bandwidth-bound).
    public internal(set) var active: LoadedModel?
    /// In-flight downloads keyed by variant repo id.
    public private(set) var downloads: [String: VariantDownload] = [:]
    /// True while a model swap is serializing (unload → drain → load), per DESIGN §2.3.
    public private(set) var switching = false
    /// The variant currently being activated (user tapped Use / Try anyway), so the UI can show a
    /// per-variant inline spinner and disable re-taps until it finishes. `nil` = no activation in flight.
    public private(set) var activatingVariantID: String?
    /// Determinate load progress (0…1) for the activating variant, or `nil` when the engine can't report
    /// it (the UI then shows an indeterminate spinner).
    public private(set) var loadProgress: Double?
    /// Whether the engine currently holds `active`'s weights in memory. Suspended (false) when we free
    /// the weights while idle (background / leaving a chat); reloaded on the next generation.
    public private(set) var engineResident = false

    private let engine: any LLMEngine
    private let downloadBase: URL
    private let downloader: Downloader
    private let installProbe: @Sendable (LLMVariant, URL) -> Bool
    private let availableMemory: @Sendable () -> Int64
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Durable JSON registry of adopted community models (Application Support, beside `models/`).
    private let registryStore: DurableStore<LLMModel>

    public init(engine: any LLMEngine,
                device: DeviceTier = .current,
                downloadBase: URL,
                downloader: @escaping Downloader,
                installProbe: @escaping @Sendable (LLMVariant, URL) -> Bool = ModelManager.defaultInstallProbe(),
                availableMemory: @escaping @Sendable () -> Int64 = { Int64(bitPattern: MemoryProbe.availableBytes()) }) {
        self.engine = engine
        self.device = device
        self.downloadBase = downloadBase
        self.downloader = downloader
        self.installProbe = installProbe
        self.availableMemory = availableMemory
        // Rooted at the download base so the registry sits beside the weights it tracks (and tests that
        // inject a temp base are automatically isolated).
        self.registryStore = DurableStore(fileURL: downloadBase.appending(component: "adopted-models.json"))
    }

    /// Default probe: the reused `ModelDownloader` reports the variant as fully downloaded. Single-file
    /// (GGUF) variants are checked file-scoped over ALL their `requiredFileNames` — a GGUF weight file
    /// plus, for a vision variant, its mmproj — so a half-fetched vision model (weights present, mmproj
    /// still downloading) never reads as installed; flat MLX repos are checked whole-repo. Identical to
    /// the old single-file check for a text-only variant (its `requiredFileNames` is just its one file).
    public nonisolated static func defaultInstallProbe() -> @Sendable (LLMVariant, URL) -> Bool {
        { variant, base in
            let downloader = ModelDownloader(downloadBase: base)
            let names = variant.requiredFileNames
            if names.isEmpty {
                return downloader.isDownloaded(repoId: variant.source.huggingFaceRepo)
            }
            return downloader.isDownloaded(repoId: variant.source.huggingFaceRepo, fileNames: names)
        }
    }

    // MARK: - Catalog helpers

    /// The device-recommended default (pinned first + "Recommended" in the UI).
    public var recommendedModel: LLMModel { LLMCatalog.defaultModel(for: device) }

    /// Catalog ordered with the recommended model first.
    public var orderedCatalog: [LLMModel] {
        let recommended = recommendedModel
        return [recommended] + catalog.filter { $0.id != recommended.id }
    }

    public func isInstalled(_ variant: LLMVariant) -> Bool { installed.contains(variant.id) }

    /// Whether a variant can accept image input RIGHT NOW: it ships a vision projector, runs on the
    /// llama.cpp engine (the only engine wired for mtmd image input — MLX stays text-only), and is
    /// installed (which, via `defaultInstallProbe` → `requiredFileNames`, means its mmproj file is on
    /// disk, not just the weights). Drives the composer's photo affordance (C2.1).
    public func supportsImageInput(_ variant: LLMVariant) -> Bool {
        variant.supportsVisionInput && variant.engine == .llamaCpp && isInstalled(variant)
    }

    /// Whether the RESIDENT model can accept image input — the composer shows its photo button only when
    /// this is true.
    public var activeSupportsImageInput: Bool {
        guard let active else { return false }
        return supportsImageInput(active.variant)
    }

    /// Refresh install state by re-scanning the weights directory (rebuildable registry, DESIGN §2.4).
    public func refreshInstalled() {
        var present: Set<String> = []
        for model in allModels {
            for variant in model.variants where installProbe(variant, downloadBase) {
                present.insert(variant.id)
            }
        }
        installed = present
    }

    /// Memory-fit verdict for a (model, variant) at a context (DESIGN §2.5).
    public func fit(_ model: LLMModel, _ variant: LLMVariant, context: Int) -> LLMFit {
        LLMMemoryGovernor.plan(model: model, variant: variant, device: device, context: context)
    }

    /// How a variant's fit is presented (DESIGN §1.2). The governor's `.unsupported` becomes an
    /// honest amber **experimental** — not a hidden/disabled row — when the weights are physically
    /// conceivable on this device (the 27B-1bit on an 8 GB iPhone: above the safe ceiling but under
    /// physical RAM, so "Try anyway" attempts the resident load and lets the device give the real
    /// answer). Truly-too-big-for-the-RAM stays gray/unsupported.
    public enum FitPresentation: Equatable {
        case comfortable
        case tight(maxContext: Int)
        case experimental
        case unsupported

        public var isExperimental: Bool { self == .experimental }
    }

    public func fitPresentation(_ model: LLMModel, _ variant: LLMVariant, context: Int) -> FitPresentation {
        // Purely size-driven now: the qwen3_5 hybrid arch is confirmed on mainline llama.cpp (Bonsai-27B
        // decodes on Metal), so a small hybrid (Qwen3.5-4B) reads genuinely comfortable. When the governor
        // says `.unsupported` but the raw weights are physically conceivable on this device, render an
        // honest amber **experimental** ("Try anyway", not a hidden row) — the 27B-1bit on an 8 GB phone.
        // Truly-too-big-for-RAM stays gray/unsupported.
        switch fit(model, variant, context: context) {
        case .comfortable: return .comfortable
        case let .tight(maxContext): return .tight(maxContext: maxContext)
        case .unsupported:
            let base = variant.onDiskBytes + variant.backend.runtimeOverheadBytes
            return base <= device.physicalMemoryBytes ? .experimental : .unsupported
        }
    }

    /// Total on-disk bytes of installed variants (Settings → storage total). Spans adopted community
    /// models too, so the storage figure counts every multi-GB download, not just the curated catalog.
    public var installedBytes: Int64 {
        allModels.flatMap { $0.variants }.filter { installed.contains($0.id) }.reduce(0) { $0 + $1.onDiskBytes }
    }

    // MARK: - Activation

    /// The estimated HARD-resident peak bytes for a variant at a context — the number the live OOM
    /// pre-flight compares against free memory. Engine-aware, and consistent with `LLMMemoryGovernor`'s
    /// mmap discount: MLX weights are all anonymous/dirty resident, but a llama.cpp GGUF's mmap'd weights
    /// are clean, reclaimable pages, so only a fraction counts as hard-resident. Without this discount the
    /// pre-flight refuses (raw bytes > free) a GGUF the fit badge says runs — the exact inconsistency the
    /// amber-but-refused bug came from.
    ///
    static func estimatedResidentPeakBytes(model: LLMModel, variant: LLMVariant, context: Int) -> Int64 {
        let overhead = variant.backend.runtimeOverheadBytes
        let weights = variant.engine == .llamaCpp
            ? Int64(Double(variant.onDiskBytes) * LLMMemoryGovernor.mmapResidentFraction)
            : variant.onDiskBytes
        return weights + overhead + model.architecture.attention.kvBytes(tokens: context)
    }

    /// Serialized swap: cancel/unload the current model, run the OOM pre-flight, load the new one, and
    /// publish `active` (DESIGN §2.3 / §2.5). Throws a recoverable `ModelActivationError` on refusal.
    /// Publishes `activatingVariantID` + `loadProgress` while loading so the UI shows per-variant feedback.
    @discardableResult
    public func activate(_ model: LLMModel, variant: LLMVariant, context: Int,
                         force: Bool = false) async throws -> LoadedModel {
        guard installed.contains(variant.id) else { throw ModelActivationError.notInstalled }

        // OOM pre-flight — for the NON-forced "Use" path only: refuse recoverably if the estimate says
        // it won't fit, so a casual tap doesn't hard-quit. But "Try anyway" (force) is the user's
        // explicit, informed attempt: DON'T second-guess it — attempt the resident load and let the
        // device give the real answer. The estimate is only an estimate; the phone is the authority.
        // (A mid-load jetsam can't be caught, so a forced attempt may hard-quit — that's the honest
        // outcome the user opted into, not something we pre-empt.) The estimate is engine-aware +
        // governor-consistent, so a model the fit badge shows amber is offered "Try anyway", not refused
        // outright by an over-counted raw-bytes check.
        let peak = Self.estimatedResidentPeakBytes(model: model, variant: variant, context: context)
        let available = availableMemory()
        if !force, available != Int64.max, peak > available {
            throw ModelActivationError.insufficientMemory(needed: peak, available: available)
        }

        activatingVariantID = variant.id
        loadProgress = nil
        switching = true
        defer { switching = false; activatingVariantID = nil; loadProgress = nil }

        await engine.unload()   // serialize: drop the old weights before loading new ones
        let weightsDir = ModelDownloader(downloadBase: downloadBase)
            .localURL(repoId: variant.source.huggingFaceRepo)
        try await engine.load(model: model, variant: variant, weightsDir: weightsDir) { [weak self] fraction in
            Task { @MainActor in self?.loadProgress = min(1, max(0, fraction)) }
        }
        let loaded = LoadedModel(model: model, variant: variant)
        active = loaded
        engineResident = true
        return loaded
    }

    public func deactivate() async {
        await engine.unload()
        active = nil
        engineResident = false
    }

    /// Free the resident weights but REMEMBER the active model, so we can reload it on the next turn.
    /// Called when idle (app backgrounded / left the chat) so a 5 GB model doesn't hog memory — and, on
    /// the 8 GB phone, so iOS doesn't jetsam-kill the app in the background against a 5 GB footprint.
    public func suspend() async {
        guard active != nil, engineResident, !switching else { return }
        await engine.unload()
        engineResident = false
    }

    /// Reload the active model if it was suspended (awaited right before generation).
    public func ensureResident(context: Int) async throws {
        // Wait out any in-flight swap/load first (e.g. the user just tapped a model and it's still
        // loading — the slow 27B especially). Skipping here let a send run on a half-loaded engine,
        // which threw "not loaded" on the first tap and only worked on the second.
        while switching { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let active, !engineResident else { return }
        switching = true
        defer { switching = false }
        let weightsDir = ModelDownloader(downloadBase: downloadBase).localURL(repoId: active.variant.source.huggingFaceRepo)
        try await engine.load(model: active.model, variant: active.variant, weightsDir: weightsDir, progress: { _ in })
        engineResident = true
    }

    // MARK: - Download (foreground, resumable)

    /// Start (or resume) a foreground download for a variant. Resumable via the reused downloader's
    /// `.part` streaming; a pause just cancels the task and keeps the partial (DESIGN §4 / critique D2).
    public func download(_ variant: LLMVariant) {
        let repoId = variant.source.huggingFaceRepo
        guard downloadTasks[repoId] == nil else { return }
        var progress = downloads[repoId] ?? VariantDownload()
        progress.isPaused = false
        progress.error = nil
        progress.meter.start(total: variant.onDiskBytes)
        downloads[repoId] = progress

        let downloader = self.downloader
        // Fetch every file the variant needs: a single-file GGUF pulls just its weight file; a vision
        // GGUF pulls its weight file AND its mmproj projector; a flat MLX repo passes an empty glob (whole
        // repo). `requiredFileNames` is the single source of truth (matches the install probe + delete).
        let globs = variant.requiredFileNames
        downloadTasks[repoId] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await downloader(repoId, globs) { [weak self] fraction in
                    Task { @MainActor in self?.applyProgress(fraction, to: repoId) }
                }
                self.finishDownload(repoId, error: nil)
            } catch is CancellationError {
                self.downloadTasks[repoId] = nil   // paused: keep the partial, no error
                self.updateIdleTimer()
            } catch {
                self.finishDownload(repoId, error: error.localizedDescription)
            }
        }
        updateIdleTimer()
    }

    private func applyProgress(_ fraction: Double, to repoId: String) {
        guard var progress = downloads[repoId] else { return }
        progress.fraction = min(1, max(0, fraction))
        progress.meter.update(fraction: fraction)
        downloads[repoId] = progress
    }

    private func finishDownload(_ repoId: String, error: String?) {
        downloadTasks[repoId] = nil
        if let error {
            downloads[repoId]?.error = error
            updateIdleTimer()
            return
        }
        downloads[repoId] = nil
        refreshInstalled()
        persistAdoptedRegistry()   // a just-downloaded community model is now worth keeping across launches
        updateIdleTimer()
    }

    /// Pause: cancel the task; the `.part` stays on disk and a later `download` resumes via Range.
    public func pauseDownload(_ variant: LLMVariant) {
        let repoId = variant.source.huggingFaceRepo
        downloadTasks[repoId]?.cancel()
        downloadTasks[repoId] = nil
        downloads[repoId]?.isPaused = true
        updateIdleTimer()
    }

    /// Keep the device awake only while a download is actually running (iOS): a multi-GB fetch shouldn't
    /// die to the auto-lock, but we must release the assertion the instant the last download ends.
    private func updateIdleTimer() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = !downloadTasks.isEmpty
        #endif
    }

    public func isDownloading(_ variant: LLMVariant) -> Bool {
        downloadTasks[variant.source.huggingFaceRepo] != nil
    }

    public func downloadState(_ variant: LLMVariant) -> VariantDownload? {
        downloads[variant.source.huggingFaceRepo]
    }

    /// Delete a variant's weights from disk (Models → delete with confirm). File-scoped for single-file
    /// (GGUF) variants — removes just that file (+ any `.part`), so a shared repo's other files survive
    /// — and whole-repo for flat MLX variants.
    public func delete(_ variant: LLMVariant) {
        let repoId = variant.source.huggingFaceRepo
        pauseDownload(variant)
        downloads[repoId] = nil
        let root = ModelDownloader(downloadBase: downloadBase).localURL(repoId: repoId)
        let names = variant.requiredFileNames
        if names.isEmpty {
            try? FileManager.default.removeItem(at: root)   // flat MLX repo — remove the whole directory
        } else {
            // File-scoped: remove each required file (GGUF weight + any mmproj) and its `.part`, so a
            // shared repo's other files survive.
            for name in names {
                let file = root.appending(component: name)
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: file.appendingPathExtension("part"))
            }
        }
        if active?.variant.id == variant.id { Task { await deactivate() } }
        refreshInstalled()
        // Deleting the last installed variant of an adopted model drops it from the persisted registry
        // (persist keeps only models with weights still on disk); it stays in memory for this session.
        persistAdoptedRegistry()
    }
}
