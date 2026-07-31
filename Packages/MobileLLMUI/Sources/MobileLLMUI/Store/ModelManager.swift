// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime
import LLMCore
#if canImport(UIKit)
import UIKit   // isIdleTimerDisabled — keep the phone awake during active downloads only
#endif

/// Recoverable failures raised before/around a resident load. Memory estimates are deliberately absent:
/// they are catalog guidance, not an activation gate. If weights are installed, the engine gets to make
/// the real attempt and iOS remains the final authority.
public enum ModelActivationError: Error, Equatable {
    /// The variant's weights aren't on disk yet.
    case notInstalled
    /// The variant's engine can't run in this environment (MLX in the simulator).
    case engineUnavailable(engine: String, reason: String)
    /// No model identity is selected (for example, its files were deleted before a retry).
    case noSelection

    public var message: String {
        switch self {
        case .notInstalled:
            "Download this model before switching to it."
        case let .engineUnavailable(engine, reason):
            "\(engine) can't run here — \(reason)."
        case .noSelection:
            "Choose a model before generating."
        }
    }

    public var forwardTitle: String? {
        switch self {
        case .notInstalled: nil
        case .engineUnavailable: nil
        case .noSelection: "Choose model"
        }
    }
}

/// Per-variant download progress surfaced to the UI (bytes/speed/ETA via `DownloadMeter`).
public struct VariantDownload {
    public var fraction: Double = 0
    public var meter: DownloadMeter = DownloadMeter()
    /// Cancellation was requested, but the downloader still owns its `.part` writer.
    public var isPausing: Bool = false
    public var isPaused: Bool = false
    public var error: String?
}

/// Every model-data scope that could not be removed, reported together: a partial erase must say what
/// is still on disk rather than stopping at the first failure and claiming success.
public struct ModelDataDeletionError: LocalizedError, Sendable {
    public let failures: [String]

    public var errorDescription: String? {
        "Some model data could not be removed:\n" + failures.joined(separator: "\n")
    }
}

/// Coordinates the model catalog: install state, memory fit, download (foreground, resumable), and
/// the single resident activation (DESIGN §2.5 / §4). MLX-free: it calls the injected `LLMEngine`
/// protocol to load, and an injected downloader closure so the real `AppRuntime.ModelDownloader`
/// wires in at app assembly.
@MainActor
@Observable
public final class ModelManager {

    /// Fetch a repo's weights at the variant's declared revision. `matching` restricts which files are
    /// pulled (empty = the whole flat repo — the MLX case; a one-entry glob = a single GGUF file — the
    /// llama.cpp case).
    public typealias Downloader = @Sendable (_ repoId: String, _ revision: String, _ matching: [String],
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
    public func adopt(_ discoveredModel: LLMModel) {
        guard !isErasingDownloadedData else { return }
        // Explore artifacts are identified by repo+revision+file, so two quants of one repository stay
        // distinct through install, download and activation.
        let model = Self.withSourceArtifactIdentities(discoveredModel)
        // A curated id always wins; a previously adopted one is REPLACED, so a fresh Hub result supersedes
        // the conservative placeholder an older registry migrated to.
        guard !catalog.contains(where: { $0.id == model.id }) else { return }
        if let existing = exploreModels.firstIndex(where: { $0.id == model.id }) {
            exploreModels[existing] = model
        } else {
            exploreModels.append(model)
        }
        refreshInstalled()
        persistAdoptedRegistry()
    }

    /// Load the persisted adopted-model registry and merge it into `exploreModels`, then rescan install
    /// state. Called once at bootstrap so downloaded community models reappear in the switcher / Settings /
    /// storage total. Idempotent — an id already present (curated or adopted) is skipped.
    public func loadAdoptedRegistry() async {
        guard !isErasingDownloadedData else { return }
        let persisted = await registryStore.load()
        guard !isErasingDownloadedData else { return }
        var migratedLegacyRecord = false
        for stored in persisted where !allModels.contains(where: { $0.id == stored.id }) {
            let model = Self.migrateLegacyExploreRecord(stored)
            if model != stored { migratedLegacyRecord = true }
            exploreModels.append(model)
        }
        // Downloads written by releases that recorded Hub digests without verifying them are upgraded
        // once, off the main actor, before install state is trusted.
        await auditLegacyManifests()
        guard !isErasingDownloadedData else { return }
        refreshInstalled()
        if migratedLegacyRecord { persistAdoptedRegistry() }
    }

    /// Repair a record written by a release that guessed a community model's family/license from its name.
    /// Those guesses are unverifiable, so they are dropped rather than shown as facts; a later Explore
    /// result carrying real Hub metadata replaces the placeholder through `adopt`.
    private static func migrateLegacyExploreRecord(_ model: LLMModel) -> LLMModel {
        let legacySummary = "Community model — loaded from its own template. Not hand-verified."
        let hasFabricatedMetadata = model.summary == legacySummary
        return LLMModel(
            id: model.id,
            displayName: model.displayName,
            family: hasFabricatedMetadata ? .unknown : model.family,
            publisher: model.publisher,
            summary: model.summary,
            license: hasFabricatedMetadata ? .unknown : model.license,
            architecture: model.architecture,
            variants: model.variants.map { $0.usingSourceArtifactIdentity() },
            defaultVariant: model.defaultVariant
        )
    }

    /// Upgrade a model's variants to artifact-level identity, leaving the artifacts themselves untouched.
    /// Returns the model unchanged when every variant is already on the current scheme.
    private static func withSourceArtifactIdentities(_ model: LLMModel) -> LLMModel {
        let variants = model.variants.map { $0.usingSourceArtifactIdentity() }
        guard variants != model.variants else { return model }
        return LLMModel(
            id: model.id,
            displayName: model.displayName,
            family: model.family,
            publisher: model.publisher,
            summary: model.summary,
            license: model.license,
            architecture: model.architecture,
            variants: variants,
            defaultVariant: model.defaultVariant
        )
    }

    /// Persist the adopted models that are actually worth keeping: those with at least one variant on disk
    /// (or downloading). Writes are chained rather than fired and forgotten, so two snapshots can never
    /// race each other onto disk — and so the erase path can drain them before removing the file.
    private func persistAdoptedRegistry() {
        guard !isErasingDownloadedData else { return }
        let keep = exploreModels.filter { model in
            model.variants.contains { installed.contains($0.id) || downloads[$0.id] != nil }
        }
        // Queue behind the write already in flight; a cancelled link (the erase snapshot arriving) simply
        // skips its own write instead of resurrecting records that are about to be deleted.
        let previous = registryWriteTask
        registryWriteTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            try? await saveAdoptedRegistry(keep)
        }
    }

    /// The one place adopted records reach durable storage. `registryWriter` is injected by tests to make
    /// write ordering observable; production writes the JSON registry beside the weights.
    private func saveAdoptedRegistry(_ models: [LLMModel]) async throws {
        if let registryWriter {
            try await registryWriter(models)
        } else {
            try await registryStore.save(models)
        }
    }

    /// Repo ids of variants present on disk — plus any OS-provided model the system says is available
    /// (nothing of it is ever on disk; see `refreshInstalled`).
    public internal(set) var installed: Set<String> = []
    /// Whether the OS's own model (the `.apple` engine) can be used right now, and if not, why. Refreshed
    /// on every `refreshInstalled` — Apple Intelligence can be switched off while the app is running — and
    /// read by the Models card to say exactly what's wrong instead of offering a dead button.
    public private(set) var systemModelStatus: SystemModelStatus
    /// The selected model, if any. Its identity remains active while its weights are suspended or lazily
    /// restored; `engineResident` is the authoritative residency bit.
    public internal(set) var active: LoadedModel?
    /// Download UI state keyed by artifact-level variant id. Multiple GGUF quants can share a repository
    /// without borrowing one another's progress, pause, error or retry state.
    public private(set) var downloads: [String: VariantDownload] = [:]
    /// True while a model swap is serializing (unload → drain → load), per DESIGN §2.3.
    public private(set) var switching = false
    /// The variant currently being activated (user tapped Use), so the UI can show a
    /// per-variant inline spinner and disable re-taps until it finishes. `nil` = no activation in flight.
    public private(set) var activatingVariantID: String?
    /// Determinate load progress (0…1) for the activating variant, or `nil` when the engine can't report
    /// it (the UI then shows an indeterminate spinner).
    public private(set) var loadProgress: Double?
    /// Whether the engine currently holds `active`'s weights in memory. Suspended (false) when we free
    /// the weights while idle (background / leaving a chat); reloaded on the next generation.
    public private(set) var engineResident = false
    /// Destructive-operation gate. It flips before the first suspension point in `eraseDownloadedData`,
    /// so no download, selection or engine mutation can enter after the erasure snapshot is taken.
    public private(set) var isErasingDownloadedData = false

    private let engine: any LLMEngine
    private let downloadBase: URL
    private let downloader: Downloader
    private let installProbe: @Sendable (LLMVariant, URL) -> Bool
    /// Asks the OS whether its system model is usable. Injected because only the Apple engine package can
    /// talk to FoundationModels, and this package is deliberately engine-free.
    private let systemModelProbe: @Sendable () -> SystemModelStatus
    /// How long the destructive erase waits for in-flight readers/writers before refusing to delete.
    private let eraseDrainTimeout: Duration
    private let registryWriter: (@Sendable ([LLMModel]) async throws -> Void)?

    /// In-flight download writers keyed by variant id, each tagged with the token its completion must
    /// match: a late callback from a superseded writer must never rewrite the current one's state.
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadTaskTokens: [String: UUID] = [:]
    /// What each in-flight writer/deferred delete has reserved on disk, so a second request for the same
    /// files is refused instead of two writers fighting over one `.part`.
    private var downloadRequests: [String: DownloadRequest] = [:]
    /// Variants whose cancellation was requested but whose writer has not returned yet.
    private var downloadPauseRequests: Set<String> = []
    private var pendingDeletionTasks: [String: Task<Void, Never>] = [:]
    private var pendingDeletionRequests: [String: DownloadRequest] = [:]
    /// Durable JSON registry of adopted community models (Application Support, beside `models/`).
    private let registryStore: DurableStore<LLMModel>
    /// Tail of the serialized adopted-registry write chain.
    private var registryWriteTask: Task<Void, Never>?
    /// The one engine-mutation lane: activate / ensureResident / suspend / deactivate all run through it,
    /// so the engine is never asked to load and unload at the same time.
    private var modelOperationTask: Task<LoadedModel?, Error>?
    private var modelOperationToken: UUID?
    /// Reopens the erase gate after a drain timed out and the straggler finally exited.
    private var eraseRecoveryTask: Task<Void, Never>?

    /// What a download writer (or a deferred delete) has reserved on disk. Two requests may run at once
    /// only when they cannot touch the same bytes.
    private struct DownloadRequest {
        let repoID: String
        let revision: String
        /// Empty = the whole flat repository.
        let fileNames: Set<String>

        func conflicts(with other: DownloadRequest) -> Bool {
            guard repoID == other.repoID else { return false }
            // A different revision retires the other revision's files in the same directory.
            if revision != other.revision { return true }
            // A whole-repository fetch owns everything under the root.
            if fileNames.isEmpty || other.fileNames.isEmpty { return true }
            return !fileNames.isDisjoint(with: other.fileNames)
        }
    }

    public init(engine: any LLMEngine,
                device: DeviceTier = .current,
                downloadBase: URL,
                downloader: @escaping Downloader,
                installProbe: @escaping @Sendable (LLMVariant, URL) -> Bool = ModelManager.defaultInstallProbe(),
                systemModelProbe: @escaping @Sendable () -> SystemModelStatus = { .unavailable(.unsupportedOS) },
                availableMemory: @escaping @Sendable () -> Int64 = { Int64(bitPattern: MemoryProbe.availableBytes()) },
                eraseDrainTimeout: Duration = .seconds(5),
                registryWriter: (@Sendable ([LLMModel]) async throws -> Void)? = nil) {
        self.engine = engine
        self.device = device
        self.downloadBase = downloadBase
        self.downloader = downloader
        self.installProbe = installProbe
        // Defaults to "this OS has no system model", so previews and unit tests never pretend one is
        // ready: only app assembly, which links the Apple engine, can answer this for real.
        self.systemModelProbe = systemModelProbe
        self.systemModelStatus = systemModelProbe()
        self.eraseDrainTimeout = eraseDrainTimeout
        self.registryWriter = registryWriter
        // `availableMemory` is accepted for source compatibility with existing call sites and is
        // deliberately neither stored nor read: a live memory reading must never decide whether an
        // installed model is allowed to load.
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
                return downloader.isDownloaded(repoId: variant.source.huggingFaceRepo,
                                               revision: variant.source.revision)
            }
            return downloader.isDownloaded(repoId: variant.source.huggingFaceRepo, fileNames: names,
                                           revision: variant.source.revision)
        }
    }

    /// One-time upgrade of version-1 download manifests (digests recorded but never verified). Hashing
    /// runs off this actor inside the downloader; each repository at a pinned revision is audited at most
    /// once per launch, and the result is advisory — a failed audit shows up as "not installed".
    private func auditLegacyManifests() async {
        let downloader = ModelDownloader(downloadBase: downloadBase)
        var seen: Set<String> = []
        for variant in allModels.flatMap(\.variants) where !variant.isSystemProvided {
            let repo = variant.source.huggingFaceRepo
            let revision = variant.source.revision
            let key = repo + "@" + revision
            guard seen.insert(key).inserted else { continue }
            if Task.isCancelled { return }
            _ = await downloader.auditAndUpgradeLegacyManifest(repoId: repo, revision: revision)
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

    /// Refresh install state by re-scanning the weights directory (rebuildable registry, DESIGN §2.4), and
    /// re-ask the OS about its own model.
    ///
    /// An OS-provided variant is never probed on disk — nothing of it is ever there. It counts as
    /// installed exactly when the system says the model is AVAILABLE, so switching Apple Intelligence off
    /// takes it out of the installed set (and the switcher, and the "Installed" filter) on the next scan,
    /// exactly as deleting weights would for any other model.
    public func refreshInstalled() {
        systemModelStatus = systemModelProbe()
        var present: Set<String> = []
        for model in allModels {
            for variant in model.variants {
                let isPresent = variant.isSystemProvided
                    ? systemModelStatus.isAvailable
                    : installProbe(variant, downloadBase)
                if isPresent { present.insert(variant.id) }
            }
        }
        installed = present
    }

    /// Memory-fit verdict for a (model, variant) at a context (DESIGN §2.5).
    public func fit(_ model: LLMModel, _ variant: LLMVariant, context: Int) -> LLMFit {
        LLMMemoryGovernor.plan(model: model, variant: variant, device: device, context: context)
    }

    /// How a variant's estimated fit is presented (DESIGN §1.2). This is advisory catalog information
    /// only: neither `.experimental` nor `.unsupported` prevents an installed variant from being loaded.
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
            let base = variant.totalOnDiskBytes + variant.backend.runtimeOverheadBytes
            return base <= device.physicalMemoryBytes ? .experimental : .unsupported
        }
    }

    /// Total on-disk bytes of installed variants (Settings → storage total). Spans adopted community
    /// models too, and includes a vision variant's required mmproj rather than reporting only its text
    /// weights, so the storage figure matches what was actually downloaded.
    public var installedBytes: Int64 {
        allModels
            .flatMap { $0.variants }
            .filter { installed.contains($0.id) }
            .reduce(0) { $0 + $1.totalOnDiskBytes }
    }

    // MARK: - Selection + activation

    /// Restore the user's selected model identity without touching the engine. Cold launch uses this so
    /// SwiftUI is interactive immediately and iOS never jetsams the process merely for opening the app;
    /// the first generation passes through `ensureResident`.
    @discardableResult
    public func restoreSelection(_ model: LLMModel, variant: LLMVariant) -> LoadedModel? {
        guard !isErasingDownloadedData, installed.contains(variant.id) else { return nil }
        // Repointing the selection while the engine really holds another model's weights would make
        // `engineResident` a lie; changing a live selection is `activate`'s job, not this one's.
        guard !engineResident else { return nil }
        let selected = LoadedModel(model: model, variant: variant)
        active = selected
        engineResident = false
        return selected
    }

    /// An informational HARD-resident estimate for a variant at a context. It is never compared against
    /// live free memory and never blocks a load. Engine-aware, and consistent with `LLMMemoryGovernor`'s
    /// mmap discount: MLX weights are all anonymous/dirty resident, but a llama.cpp GGUF's mmap'd weights
    /// are clean, reclaimable pages, so only a fraction counts as hard-resident. This keeps informational
    /// estimates internally consistent without turning either estimate into an authorization check.
    static func estimatedResidentPeakBytes(model: LLMModel, variant: LLMVariant, context: Int) -> Int64 {
        // The OS-provided model costs this process nothing — no weights, no KV cache, no runtime — so
        // there is nothing to weigh. Short-circuited for the same reason `LLMMemoryGovernor.plan` is: its
        // catalog entry's architecture is honest zeros (Apple publishes none), so running the KV math over
        // it would be arithmetic on placeholders.
        if variant.isSystemProvided { return 0 }
        let overhead = variant.backend.runtimeOverheadBytes
        // Same weight base as the governor: model file + vision projector (the mmproj is mmap'd GGUF too,
        // so the discount applies to the sum). Diverging from the governor here is what produced the
        // amber-but-refused inconsistency — keep the two maths identical.
        let weightBytes = variant.totalOnDiskBytes
        let weights = variant.engine == .llamaCpp
            ? Int64(Double(weightBytes) * LLMMemoryGovernor.mmapResidentFraction)
            : weightBytes
        return weights + overhead + model.architecture.attention.kvBytes(tokens: context)
    }

    /// MLX does not run in the simulator (no MLX-capable Metal device) — an attempted load fails late or
    /// hangs Metal init, which deadlocks bootstrap/UI tests behind `switching`. Refuse up-front with a
    /// clear error; GGUF variants run fine (llama.cpp drops to CPU in the sim).
    private func validateEngineAvailability(_ variant: LLMVariant) throws {
        #if targetEnvironment(simulator)
        guard variant.engine != .mlx else {
            throw ModelActivationError.engineUnavailable(engine: EngineKind.mlx.label,
                                                         reason: "the simulator can't run MLX — use the GGUF variant")
        }
        #endif
    }

    /// Take the engine-mutation lane. Concurrent callers queue instead of racing, and the destructive gate
    /// is re-checked around every suspension so nothing new enters an erase window.
    private func beginModelOperation() async throws {
        if isErasingDownloadedData {
            throw CancellationError()
        }
        while switching {
            try await Task.sleep(nanoseconds: 10_000_000)
            if isErasingDownloadedData {
                throw CancellationError()
            }
        }
        try Task.checkCancellation()
        if isErasingDownloadedData {
            throw CancellationError()
        }
        // No suspension point between the last check and the claim, so main-actor exclusivity makes this
        // an actual mutex rather than a hopeful flag.
        switching = true
    }

    /// Run one engine mutation on the lane. The work runs in a tracked child task so `eraseDownloadedData`
    /// can cancel a load that is already inside the engine, and so a cancelled CALLER cancels it too.
    private func performModelOperation(
        _ operation: @escaping @MainActor @Sendable () async throws -> LoadedModel?
    ) async throws -> LoadedModel? {
        try await beginModelOperation()
        if isErasingDownloadedData {
            switching = false
            throw CancellationError()
        }
        let token = UUID()
        let task = Task { @MainActor in try await operation() }
        modelOperationToken = token
        modelOperationTask = task
        defer {
            // A later operation may already own the lane; only the owner clears it.
            if modelOperationToken == token {
                modelOperationTask = nil
                modelOperationToken = nil
                switching = false
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Serialized swap: cancel/unload the current model, attempt to load the new one, and publish `active`
    /// (DESIGN §2.3). Installed weights are always attempted; memory-fit estimates never refuse a load.
    /// Publishes `activatingVariantID` + `loadProgress` while loading so the UI shows per-variant feedback.
    @discardableResult
    public func activate(_ model: LLMModel, variant: LLMVariant, context: Int,
                         force: Bool = false) async throws -> LoadedModel {
        guard installed.contains(variant.id) else { throw ModelActivationError.notInstalled }
        try validateEngineAvailability(variant)
        // Published before the lane is taken: a queued activation must still show its spinner.
        activatingVariantID = variant.id
        loadProgress = nil
        defer { activatingVariantID = nil; loadProgress = nil }

        let loaded = try await performModelOperation { [weak self] in
            guard let self, installed.contains(variant.id) else { return nil }
            if let active, active.variant.id == variant.id, engineResident { return active }
            // Re-published inside the lane: a queued activation's spinner was cleared when the operation
            // ahead of it finished.
            activatingVariantID = variant.id
            loadProgress = nil

            // Serialize: drop the old weights before loading new ones, and stop claiming residency the
            // moment they are gone — a failed swap must leave the old selection honestly non-resident.
            await engine.unload()
            engineResident = false
            try Task.checkCancellation()
            let weightsDir = ModelDownloader(downloadBase: downloadBase)
                .localURL(repoId: variant.source.huggingFaceRepo)
            do {
                try await engine.load(model: model, variant: variant, weightsDir: weightsDir) { [weak self] fraction in
                    Task { @MainActor in self?.loadProgress = min(1, max(0, fraction)) }
                }
            } catch {
                // A failed load can leave a half-built context behind; drop it so the next attempt starts
                // from a clean engine.
                await engine.unload()
                throw error
            }
            // An engine that ignores cancellation can still return normally after the swap was abandoned;
            // publishing it here would resurrect a model the user already moved off.
            if Task.isCancelled { throw CancellationError() }
            let loaded = LoadedModel(model: model, variant: variant)
            active = loaded
            engineResident = true
            return loaded
        }
        guard let loaded else { throw CancellationError() }
        return loaded
    }

    public func deactivate() async {
        _ = try? await performModelOperation { [weak self] in
            guard let self else { return nil }
            await engine.unload()
            active = nil
            engineResident = false
            return nil
        }
    }

    /// Free the resident weights but REMEMBER the active model, so we can reload it on the next turn.
    /// Called when idle (app backgrounded / left the chat) so a 5 GB model doesn't hog memory — and, on
    /// the 8 GB phone, so iOS doesn't jetsam-kill the app in the background against a 5 GB footprint.
    public func suspend() async {
        guard active != nil, engineResident, !switching, !isErasingDownloadedData else { return }
        _ = try? await performModelOperation { [weak self] in
            guard let self, active != nil, engineResident else { return nil }
            await engine.unload()
            engineResident = false
            return nil
        }
    }

    /// Reload the active model if it was suspended (awaited right before generation).
    public func ensureResident(context: Int) async throws {
        _ = try await performModelOperation { [weak self] in
            guard let self else { return nil }
            guard let active else { throw ModelActivationError.noSelection }
            guard !engineResident else { return active }
            guard installed.contains(active.variant.id) else { throw ModelActivationError.notInstalled }
            try validateEngineAvailability(active.variant)
            try Task.checkCancellation()
            let weightsDir = ModelDownloader(downloadBase: downloadBase)
                .localURL(repoId: active.variant.source.huggingFaceRepo)
            do {
                try await engine.load(model: active.model, variant: active.variant,
                                      weightsDir: weightsDir, progress: { _ in })
            } catch {
                await engine.unload()
                throw error
            }
            if Task.isCancelled { throw CancellationError() }
            engineResident = true
            return active
        }
    }

    // MARK: - Download (foreground, resumable)

    /// Start (or resume) a foreground download for a variant. Resumable via the reused downloader's
    /// `.part` streaming; a pause just cancels the task and keeps the partial (DESIGN §4 / critique D2).
    public func download(_ variant: LLMVariant) {
        // An OS-provided model has no repo to fetch — its source id is synthetic. The card never offers a
        // download for one; this guard makes sure no other path can start a doomed 404 against it either.
        guard !variant.isSystemProvided, !isErasingDownloadedData else { return }
        let variantID = variant.id
        let repoId = variant.source.huggingFaceRepo
        // A writer that was asked to pause still owns its `.part` until it returns, and a deferred delete
        // keeps the same reservation — either way, resuming now would start a second writer for one file.
        guard downloadTasks[variantID] == nil, pendingDeletionTasks[variantID] == nil else { return }
        let request = DownloadRequest(repoID: repoId,
                                      revision: variant.source.revision,
                                      fileNames: Set(variant.requiredFileNames))
        let blocked = downloadRequests.values.contains { $0.conflicts(with: request) }
            || pendingDeletionRequests.values.contains { $0.conflicts(with: request) }
        if blocked {
            // Surfaced as this variant's error row (not a silent no-op), so the card explains why its
            // button did nothing and stays retryable.
            var progress = downloads[variantID] ?? VariantDownload()
            progress.isPaused = false
            progress.isPausing = false
            progress.error = "Another download is already writing these model files. Try again when it finishes."
            downloads[variantID] = progress
            return
        }

        var progress = downloads[variantID] ?? VariantDownload()
        progress.isPaused = false
        progress.isPausing = false
        progress.error = nil
        // The denominator must count every required file, or a vision model's progress bar finishes at
        // the weights and then keeps running for the mmproj.
        progress.meter.start(total: variant.totalOnDiskBytes)
        downloads[variantID] = progress

        let downloader = self.downloader
        // Fetch every file the variant needs: a single-file GGUF pulls just its weight file; a vision
        // GGUF pulls its weight file AND its mmproj projector; a flat MLX repo passes an empty glob (whole
        // repo). `requiredFileNames` is the single source of truth (matches the install probe + delete).
        let globs = variant.requiredFileNames
        let revision = variant.source.revision
        let token = UUID()
        downloadPauseRequests.remove(variantID)
        downloadTaskTokens[variantID] = token
        downloadRequests[variantID] = request
        downloadTasks[variantID] = Task { @MainActor [weak self] in
            guard let self else { return }
            if Task.isCancelled {
                finishPausedDownload(variantID, token: token)
                return
            }
            do {
                try await downloader(repoId, revision, globs) { [weak self] fraction in
                    Task { @MainActor in self?.applyProgress(fraction, to: variantID, token: token) }
                }
                if Task.isCancelled || downloadPauseRequests.contains(variantID) {
                    finishPausedDownload(variantID, token: token)
                } else {
                    finishDownload(variantID, token: token, error: nil)
                }
            } catch {
                if Task.isCancelled || downloadPauseRequests.contains(variantID) {
                    finishPausedDownload(variantID, token: token)
                } else {
                    finishDownload(variantID, token: token, error: error.localizedDescription)
                }
            }
        }
        // A community model being fetched is already worth remembering: an interrupted download must
        // reappear in the list after a relaunch instead of stranding its partial file.
        persistAdoptedRegistry()
        updateIdleTimer()
    }

    private func applyProgress(_ fraction: Double, to variantID: String, token: UUID) {
        guard downloadTaskTokens[variantID] == token, var progress = downloads[variantID] else { return }
        progress.fraction = min(1, max(0, fraction))
        progress.meter.update(fraction: fraction)
        downloads[variantID] = progress
    }

    private func finishDownload(_ variantID: String, token: UUID, error: String?) {
        guard downloadTaskTokens[variantID] == token else { return }
        downloadTasks[variantID] = nil
        downloadTaskTokens[variantID] = nil
        downloadRequests[variantID] = nil
        downloadPauseRequests.remove(variantID)
        if let error {
            downloads[variantID]?.error = error
            downloads[variantID]?.isPausing = false
            updateIdleTimer()
            return
        }
        downloads[variantID] = nil
        refreshInstalled()
        persistAdoptedRegistry()   // a just-downloaded community model is now worth keeping across launches
        updateIdleTimer()
    }

    /// The writer really exited after a pause: only now is the reservation released and Resume offered.
    private func finishPausedDownload(_ variantID: String, token: UUID) {
        guard downloadTaskTokens[variantID] == token else { return }
        downloadTasks[variantID] = nil
        downloadTaskTokens[variantID] = nil
        downloadRequests[variantID] = nil
        downloadPauseRequests.remove(variantID)
        downloads[variantID]?.isPausing = false
        downloads[variantID]?.isPaused = true
        updateIdleTimer()
    }

    /// Pause requests cancellation but deliberately keeps the task + request reservation until the
    /// downloader returns. Cancellation is cooperative; removing either early lets an immediate Resume
    /// create a second writer for the same `.part` file.
    public func pauseDownload(_ variant: LLMVariant) {
        guard !isErasingDownloadedData else { return }
        let variantID = variant.id
        guard let task = downloadTasks[variantID] else { return }
        downloadPauseRequests.insert(variantID)
        downloads[variantID]?.isPausing = true
        downloads[variantID]?.error = nil
        task.cancel()
    }

    /// Keep the device awake only while a download is actually running (iOS): a multi-GB fetch shouldn't
    /// die to the auto-lock, but we must release the assertion the instant the last download ends.
    private func updateIdleTimer() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = !downloadTasks.isEmpty
        #endif
    }

    public func isDownloading(_ variant: LLMVariant) -> Bool {
        downloadTasks[variant.id] != nil
    }

    public func downloadState(_ variant: LLMVariant) -> VariantDownload? {
        downloads[variant.id]
    }

    /// Delete a variant's weights from disk (Models → delete with confirm). File-scoped for single-file
    /// (GGUF) variants — removes just that file (+ any `.part`), so a shared repo's other files survive
    /// — and whole-repo for flat MLX variants.
    public func delete(_ variant: LLMVariant) {
        // Nothing of an OS-provided model is ours to delete: no weights, no directory. (The card offers no
        // delete for one — this keeps any other caller from removing a directory that isn't there, or
        // worse, deactivating the model as a side effect.)
        guard !variant.isSystemProvided, !isErasingDownloadedData else { return }
        let variantID = variant.id
        guard pendingDeletionTasks[variantID] == nil else { return }
        let runningDownload = downloadTasks[variantID]
        let request = downloadRequests[variantID]
            ?? DownloadRequest(repoID: variant.source.huggingFaceRepo,
                               revision: variant.source.revision,
                               fileNames: Set(variant.requiredFileNames))
        if let runningDownload {
            // Unlinking a `.part` under its live writer loses the file but not the writer: it keeps
            // streaming into a deleted inode. Reserve the artifact, ask the writer to stop, and delete
            // once it has really exited.
            pendingDeletionRequests[variantID] = request
            pauseDownload(variant)
            pendingDeletionTasks[variantID] = Task { @MainActor [weak self] in
                _ = await runningDownload.value
                guard let self else { return }
                defer {
                    pendingDeletionTasks[variantID] = nil
                    pendingDeletionRequests[variantID] = nil
                }
                guard !Task.isCancelled, !isErasingDownloadedData else { return }
                deleteDownloadedFiles(variant)
            }
            return
        }
        deleteDownloadedFiles(variant)
    }

    private func deleteDownloadedFiles(_ variant: LLMVariant) {
        let variantID = variant.id
        let repoId = variant.source.huggingFaceRepo
        downloads[variantID] = nil
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

    // MARK: - Destructive erase

    /// Anything that is reading or writing model bytes right now. The registry write chain is drained
    /// separately — it touches only the small JSON manifest.
    private var hasOutstandingModelIO: Bool {
        !downloadTasks.isEmpty
            || !pendingDeletionTasks.isEmpty
            || modelOperationTask != nil
            || switching
    }

    /// Wait — bounded — for every in-flight reader/writer to really exit. Cancellation is cooperative, so
    /// "cancelled" is not "finished": deleting files under a live reader is what this prevents.
    private func waitForModelIODrain() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: eraseDrainTimeout)
        while hasOutstandingModelIO {
            // A swallowed sleep (deadline reached, or this erase itself cancelled) must end the wait, not
            // spin the main actor at full speed until the drain happens to finish.
            if clock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// After a drain timeout the gate stays CLOSED — the app must not start new model work around a
    /// straggler. This reopens it once that straggler finally exits, without deleting anything: a
    /// destructive retry has to be requested explicitly.
    private func retainEraseGateUntilDrain(registryTail: Task<Void, Never>?) {
        eraseRecoveryTask?.cancel()
        eraseRecoveryTask = Task { @MainActor [weak self] in
            await registryTail?.value
            while let self, hasOutstandingModelIO, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            // Cancelled means a newer observer (or a retried erase) owns the gate now; reopening it here
            // would unlock a window somebody else is holding closed on purpose.
            guard let self, !Task.isCancelled else { return }
            isErasingDownloadedData = false
            eraseRecoveryTask = nil
        }
    }

    /// Stop every model operation, drain the resident engine, then remove only the app-owned model root
    /// and adopted registry. `downloadBase` is injected by app assembly/tests; the resolved target is
    /// required to be its exact `models` child before deletion.
    public func eraseDownloadedData() async throws {
        guard !isErasingDownloadedData else {
            throw ModelDataDeletionError(failures: ["Downloaded models: deletion is already in progress"])
        }
        // Closed BEFORE the first suspension point, so everything that arrives after this instant is
        // refused rather than racing the deletion it cannot see.
        isErasingDownloadedData = true
        var releasesGateOnReturn = true
        defer {
            if releasesGateOnReturn {
                switching = false
                isErasingDownloadedData = false
            }
        }

        // Snapshot first: work created after this point is already refused by the gate.
        let runningDownloads = Array(downloadTasks.values)
        let runningDeletions = Array(pendingDeletionTasks.values)
        let priorRegistryWrite = registryWriteTask
        runningDownloads.forEach { $0.cancel() }
        runningDeletions.forEach { $0.cancel() }
        modelOperationTask?.cancel()
        priorRegistryWrite?.cancel()

        guard await waitForModelIODrain() else {
            retainEraseGateUntilDrain(registryTail: priorRegistryWrite)
            releasesGateOnReturn = false
            throw ModelDataDeletionError(failures: [
                "Downloaded models: timed out waiting for an active model operation to stop; no files were deleted"
            ])
        }

        switching = false
        downloadTasks.removeAll()
        downloadTaskTokens.removeAll()
        downloadRequests.removeAll()
        downloadPauseRequests.removeAll()
        pendingDeletionTasks.removeAll()
        pendingDeletionRequests.removeAll()
        downloads.removeAll()
        updateIdleTimer()

        await engine.unload()
        active = nil
        engineResident = false
        activatingVariantID = nil
        loadProgress = nil

        // The cancelled tail still waits out the write ahead of it, so the empty snapshot below is
        // genuinely last and cannot be overwritten by an older one.
        await priorRegistryWrite?.value
        registryWriteTask = nil

        var failures: [String] = []
        let base = downloadBase.standardizedFileURL
        let modelsRoot = base.appending(component: "models").standardizedFileURL
        if modelsRoot.lastPathComponent == "models", modelsRoot.deletingLastPathComponent().path == base.path {
            if FileManager.default.fileExists(atPath: modelsRoot.path) {
                do {
                    try FileManager.default.removeItem(at: modelsRoot)
                } catch {
                    failures.append("Downloaded models: \(error.localizedDescription)")
                }
            }
        } else {
            // Erasure is confined to the directory we materialize repositories into; anything else under
            // the injected base belongs to somebody who is not us.
            failures.append("Downloaded models: refused an unexpected storage path")
        }

        do {
            try await saveAdoptedRegistry([])
        } catch {
            failures.append("Adopted model registry: \(error.localizedDescription)")
        }
        // An injected writer may not be file-backed, so the registry files are removed explicitly too —
        // including `DurableStore`'s atomic-write sibling, which a crash could have left behind.
        let registryURL = downloadBase.appending(component: "adopted-models.json")
        let registryTempSibling = registryURL.appendingPathExtension("tmp")
        for url in [registryURL, registryTempSibling] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        exploreModels = []
        refreshInstalled()
        if !failures.isEmpty { throw ModelDataDeletionError(failures: failures) }
    }
}
