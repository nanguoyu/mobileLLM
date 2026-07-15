// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import AppRuntime
import LLMCore

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
                 + "\(f.string(fromByteCount: available)) free). Try the 8B model or close other apps."
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
public struct VariantDownload: Equatable {
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

    public typealias Downloader = @Sendable (_ repoId: String,
                                             _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void

    public let catalog: [LLMModel] = LLMCatalog.all
    public let device: DeviceTier

    /// Repo ids of variants present on disk.
    public private(set) var installed: Set<String> = []
    /// The resident model, if any (one active model — decode is bandwidth-bound).
    public private(set) var active: LoadedModel?
    /// In-flight downloads keyed by variant repo id.
    public private(set) var downloads: [String: VariantDownload] = [:]
    /// True while a model swap is serializing (unload → drain → load), per DESIGN §2.3.
    public private(set) var switching = false

    private let engine: any LLMEngine
    private let downloadBase: URL
    private let downloader: Downloader
    private let installProbe: @Sendable (LLMVariant, URL) -> Bool
    private let availableMemory: @Sendable () -> Int64
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    public init(engine: any LLMEngine,
                device: DeviceTier = .current,
                downloadBase: URL,
                downloader: @escaping Downloader,
                installProbe: @escaping @Sendable (LLMVariant, URL) -> Bool = ModelManager.defaultInstallProbe,
                availableMemory: @escaping @Sendable () -> Int64 = { Int64(bitPattern: MemoryProbe.availableBytes()) }) {
        self.engine = engine
        self.device = device
        self.downloadBase = downloadBase
        self.downloader = downloader
        self.installProbe = installProbe
        self.availableMemory = availableMemory
    }

    /// Default probe: the reused `ModelDownloader` reports the flat repo as fully downloaded.
    public static let defaultInstallProbe: @Sendable (LLMVariant, URL) -> Bool = { variant, base in
        ModelDownloader(downloadBase: base).isDownloaded(repoId: variant.source.huggingFaceRepo)
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

    /// Refresh install state by re-scanning the weights directory (rebuildable registry, DESIGN §2.4).
    public func refreshInstalled() {
        var present: Set<String> = []
        for model in catalog {
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

    /// Total on-disk bytes of installed variants (Settings → storage total).
    public var installedBytes: Int64 {
        catalog.flatMap { $0.variants }.filter { installed.contains($0.id) }.reduce(0) { $0 + $1.onDiskBytes }
    }

    // MARK: - Activation

    /// Serialized swap: cancel/unload the current model, run the OOM pre-flight, load the new one, and
    /// publish `active` (DESIGN §2.3 / §2.5). Throws a recoverable `ModelActivationError` on refusal.
    @discardableResult
    public func activate(_ model: LLMModel, variant: LLMVariant, context: Int,
                         force: Bool = false) async throws -> LoadedModel {
        guard installed.contains(variant.id) else { throw ModelActivationError.notInstalled }

        // OOM pre-flight: refuse recoverably before jetsam can fire (bypassable via "Try anyway").
        let base = variant.onDiskBytes + variant.backend.runtimeOverheadBytes
        let peak = base + model.architecture.attention.kvBytes(tokens: context)
        let available = availableMemory()
        if !force, available != Int64.max, peak > available {
            throw ModelActivationError.insufficientMemory(needed: peak, available: available)
        }

        switching = true
        defer { switching = false }

        await engine.unload()   // serialize: drop the old weights before loading new ones
        let weightsDir = ModelDownloader(downloadBase: downloadBase)
            .localURL(repoId: variant.source.huggingFaceRepo)
        try await engine.load(model: model, variant: variant, weightsDir: weightsDir, progress: { _ in })
        let loaded = LoadedModel(model: model, variant: variant)
        active = loaded
        return loaded
    }

    public func deactivate() async {
        await engine.unload()
        active = nil
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
        downloadTasks[repoId] = Task { @MainActor [weak self] in
            do {
                try await downloader(repoId) { fraction in
                    Task { @MainActor [weak self] in self?.applyProgress(fraction, to: repoId) }
                }
                self?.finishDownload(repoId, error: nil)
            } catch is CancellationError {
                self?.downloadTasks[repoId] = nil   // paused: keep the partial, no error
            } catch {
                self?.finishDownload(repoId, error: error.localizedDescription)
            }
        }
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
            return
        }
        downloads[repoId] = nil
        refreshInstalled()
    }

    /// Pause: cancel the task; the `.part` stays on disk and a later `download` resumes via Range.
    public func pauseDownload(_ variant: LLMVariant) {
        let repoId = variant.source.huggingFaceRepo
        downloadTasks[repoId]?.cancel()
        downloadTasks[repoId] = nil
        downloads[repoId]?.isPaused = true
    }

    public func isDownloading(_ variant: LLMVariant) -> Bool {
        downloadTasks[variant.source.huggingFaceRepo] != nil
    }

    public func downloadState(_ variant: LLMVariant) -> VariantDownload? {
        downloads[variant.source.huggingFaceRepo]
    }

    /// Delete a variant's weights from disk (Models → delete with confirm).
    public func delete(_ variant: LLMVariant) {
        let repoId = variant.source.huggingFaceRepo
        pauseDownload(variant)
        downloads[repoId] = nil
        let dir = ModelDownloader(downloadBase: downloadBase).localURL(repoId: repoId)
        try? FileManager.default.removeItem(at: dir)
        if active?.variant.id == variant.id { Task { await deactivate() } }
        refreshInstalled()
    }
}
