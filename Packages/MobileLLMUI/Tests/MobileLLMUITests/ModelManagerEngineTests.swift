// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Records the file globs the app-facing downloader closure is invoked with.
private actor GlobRecorder {
    private(set) var captured: [String]?
    private(set) var revision: String?
    func record(revision: String, globs: [String]) {
        self.revision = revision
        captured = globs
    }
    func get() -> [String]? { captured }
    func getRevision() -> String? { revision }
}

/// Minimal engine probe for the cold-selection → first-use residency boundary.
private actor ResidencyCountingEngine: LLMEngine {
    private var loadCount = 0

    func loads() -> Int { loadCount }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {
        loadCount += 1
        progress(1)
    }

    func unload() async {}

    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private enum ControlledEngineError: Error {
    case refused
}

/// Records the engine's actual resident identity so async swap ordering can be compared with
/// `ModelManager.active`.
private actor ControlledResidencyEngine: LLMEngine {
    private var resident: String?
    private var failingVariants: Set<String> = []
    private var loadStarts = 0
    private let delayNanos: UInt64

    init(delayNanos: UInt64 = 0) {
        self.delayNanos = delayNanos
    }

    func fail(_ variantID: String) {
        failingVariants.insert(variantID)
    }

    func startedLoads() -> Int { loadStarts }
    func residentID() -> String? { resident }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {
        loadStarts += 1
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        if failingVariants.contains(variant.id) { throw ControlledEngineError.refused }
        resident = variant.id
        progress(1)
    }

    func unload() async {
        resident = nil
    }

    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// A cancellation-cooperative operation whose exit is controlled by the test. It models engine loads and
/// download writers that observe cancellation but still need an asynchronous cleanup interval.
private actor DelayedCancellationExit {
    private var entries = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async throws {
        entries += 1
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }

    func entryCount() -> Int { entries }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ErasureControlledEngine: LLMEngine {
    let loadGate: DelayedCancellationExit
    private var unloads = 0

    init(loadGate: DelayedCancellationExit) {
        self.loadGate = loadGate
    }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {
        try await loadGate.wait()
        progress(1)
    }

    func unload() async { unloads += 1 }
    func unloadCount() -> Int { unloads }

    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor RegistryWriteGate {
    private var snapshots: [[String]] = []
    private var blocksFirstNonempty = true
    private var continuation: CheckedContinuation<Void, Never>?

    func write(_ models: [LLMModel]) async {
        snapshots.append(models.map(\.id))
        if blocksFirstNonempty, !models.isEmpty {
            blocksFirstNonempty = false
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func writeCount() -> Int { snapshots.count }
    func recordedSnapshots() -> [[String]] { snapshots }

    func releaseFirstWrite() {
        continuation?.resume()
        continuation = nil
    }
}

/// `ModelManager` engine wiring (DESIGN §6): single-file GGUF variants thread their filename through
/// as a one-entry glob; flat MLX variants pass an empty glob; and the 27B GGUF always presents as an
/// honest experimental (amber), never green.
@MainActor
final class ModelManagerEngineTests: XCTestCase {

    private let phone8 = DeviceTier(physicalMemoryBytes: 8_000_000_000,  isPhone: true)
    private let phone12 = DeviceTier(physicalMemoryBytes: 12_000_000_000, isPhone: true)
    private let mac16  = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "mm-engine-\(UUID().uuidString)")
    }

    private func manager(_ device: DeviceTier, recorder: GlobRecorder? = nil,
                         installed: Bool = false) -> ModelManager {
        ModelManager(engine: MockLLMEngine(), device: device, downloadBase: tempBase(),
                     downloader: { _, revision, globs, progress in
                         await recorder?.record(revision: revision, globs: globs)
                         progress(1)
                     },
                     installProbe: { _, _ in installed },
                     availableMemory: { .max })
    }

    private func waitUntilNotDownloading(_ models: ModelManager, _ variant: LLMVariant,
                                         timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while models.isDownloading(variant) {
            if Date() > deadline { throw XCTSkip("download did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool,
                           timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { throw XCTSkip("timed out waiting for deterministic test state") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// A GGUF variant downloads just its one file (its `fileName` becomes the glob).
    func testGGUFDownloadThreadsFileNameGlob() async throws {
        let recorder = GlobRecorder()
        let models = manager(phone8, recorder: recorder)
        let gguf = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        models.download(gguf)
        try await waitUntilNotDownloading(models, gguf)
        let captured = await recorder.get()
        XCTAssertEqual(captured, ["Bonsai-8B-Q1_0.gguf"])
    }

    /// A flat MLX variant downloads the whole repo (empty glob).
    func testMLXDownloadUsesEmptyGlob() async throws {
        let recorder = GlobRecorder()
        let models = manager(phone8, recorder: recorder)
        let mlx = LLMCatalog.bonsai8b.variant(engine: .mlx, quant: .binary1bit)!
        models.download(mlx)
        try await waitUntilNotDownloading(models, mlx)
        let captured = await recorder.get()
        XCTAssertEqual(captured, [])
    }

    func testDownloadThreadsPinnedRevision() async throws {
        let recorder = GlobRecorder()
        let models = manager(phone8, recorder: recorder)
        let base = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        let pinned = LLMVariant(
            quant: base.quant,
            backend: base.backend,
            onDiskBytes: base.onDiskBytes,
            source: ModelSource(
                huggingFaceRepo: base.source.huggingFaceRepo,
                revision: "refs/pr/42",
                fileName: base.source.fileName
            )
        )

        models.download(pinned)
        try await waitUntilNotDownloading(models, pinned)
        let recordedRevision = await recorder.getRevision()
        XCTAssertEqual(recordedRevision, "refs/pr/42")
    }

    func testVisionDownloadAndStorageTotalsIncludeProjector() {
        let vision = LLMCatalog.qwen35_4b.variant(engine: .llamaCpp, quant: .gguf4bit)!
        let models = ModelManager(
            engine: MockLLMEngine(),
            device: phone8,
            downloadBase: tempBase(),
            downloader: { _, _, _, _ in try await Task.sleep(nanoseconds: 5_000_000_000) },
            installProbe: { variant, _ in variant.id == vision.id },
            availableMemory: { .max }
        )
        models.refreshInstalled()
        XCTAssertGreaterThan(vision.totalOnDiskBytes, vision.onDiskBytes,
                             "a vision model's mmproj contributes real download/storage bytes")
        XCTAssertEqual(models.installedBytes, vision.totalOnDiskBytes)

        models.download(vision)
        XCTAssertEqual(models.downloadState(vision)?.meter.totalBytes, vision.totalOnDiskBytes,
                       "the progress denominator must match every required file")
        models.pauseDownload(vision)
    }

    /// The 3.8 GB 27B GGUF presents by SIZE now (hybrid arch confirmed on mainline): comfortable on
    /// roomy devices, honest `.tight` on the 8 GB phone (runs via the clean-page discount, not green).
    func testGGUF27BSizeDrivenPresentation() {
        let gguf = LLMCatalog.bonsai27b.variant(engine: .llamaCpp, quant: .binary1bit)!
        XCTAssertEqual(manager(phone12).fitPresentation(LLMCatalog.bonsai27b, gguf, context: 4096), .comfortable)
        XCTAssertEqual(manager(mac16).fitPresentation(LLMCatalog.bonsai27b, gguf, context: 4096), .comfortable)
        guard case .tight = manager(phone8).fitPresentation(LLMCatalog.bonsai27b, gguf, context: 4096) else {
            return XCTFail("27B GGUF should read tight (runnable via mmap discount) on the 8 GB phone")
        }
    }

    /// The 8B GGUF presents as comfortable on every device (the mmap-friendly hero).
    func testGGUF8BComfortable() {
        let gguf = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        for device in [phone8, phone12, mac16] {
            XCTAssertEqual(manager(device).fitPresentation(LLMCatalog.bonsai8b, gguf, context: 4096),
                           .comfortable)
        }
    }

    /// `refreshInstalled` records GGUF variants by their engine-tagged id when present on disk.
    func testRefreshInstalledTracksGGUFVariant() {
        let models = manager(phone8, installed: true)
        models.refreshInstalled()
        let gguf = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        XCTAssertTrue(models.isInstalled(gguf))
        XCTAssertTrue(gguf.id.hasSuffix("#gguf"))
    }

    func testRestoredSelectionLoadsExactlyOnceOnFirstEnsureResident() async throws {
        let engine = ResidencyCountingEngine()
        let model = LLMCatalog.bonsai8b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let models = ModelManager(
            engine: engine,
            device: phone8,
            downloadBase: tempBase(),
            downloader: { _, _, _, progress in progress(1) },
            installProbe: { variant, _ in variant.id == gguf.id },
            availableMemory: { .max }
        )
        models.refreshInstalled()

        XCTAssertNotNil(models.restoreSelection(model, variant: gguf))
        XCTAssertFalse(models.engineResident)
        let beforeFirstUse = await engine.loads()
        XCTAssertEqual(beforeFirstUse, 0, "restoring identity must leave the engine cold")

        try await models.ensureResident(context: 4096)
        let afterFirstUse = await engine.loads()
        XCTAssertEqual(afterFirstUse, 1, "the first use loads the selected model once")
        XCTAssertTrue(models.engineResident)

        try await models.ensureResident(context: 4096)
        let afterSecondCheck = await engine.loads()
        XCTAssertEqual(afterSecondCheck, 1, "an already-resident model must not be loaded again")
    }

    func testFailedHotSwapLeavesOldSelectionTruthfullyNonresidentAndReloadable() async throws {
        let engine = ControlledResidencyEngine()
        let firstModel = LLMCatalog.bonsai4b
        let first = firstModel.variant(engine: .llamaCpp, quant: .binary1bit)!
        let secondModel = LLMCatalog.bonsai8b
        let second = secondModel.variant(engine: .llamaCpp, quant: .binary1bit)!
        let models = ModelManager(
            engine: engine,
            device: mac16,
            downloadBase: tempBase(),
            downloader: { _, _, _, progress in progress(1) },
            installProbe: { _, _ in true },
            availableMemory: { .max }
        )
        models.refreshInstalled()
        _ = try await models.activate(firstModel, variant: first, context: 2048)
        await engine.fail(second.id)

        do {
            _ = try await models.activate(secondModel, variant: second, context: 2048)
            XCTFail("the controlled second load must fail")
        } catch ControlledEngineError.refused {
            // expected
        }

        XCTAssertEqual(models.active?.variant.id, first.id, "selection remains on the last good model")
        XCTAssertFalse(models.engineResident, "the old engine was unloaded before the failed swap")
        let afterFailureResident = await engine.residentID()
        XCTAssertNil(afterFailureResident)

        try await models.ensureResident(context: 2048)
        XCTAssertTrue(models.engineResident)
        let reloadedResident = await engine.residentID()
        XCTAssertEqual(reloadedResident, first.id)
    }

    func testConcurrentActivationsSerializeAndPublishTheEngineThatActuallyWon() async throws {
        let engine = ControlledResidencyEngine(delayNanos: 30_000_000)
        let firstModel = LLMCatalog.bonsai4b
        let first = firstModel.variant(engine: .llamaCpp, quant: .binary1bit)!
        let secondModel = LLMCatalog.bonsai8b
        let second = secondModel.variant(engine: .llamaCpp, quant: .binary1bit)!
        let models = ModelManager(
            engine: engine,
            device: mac16,
            downloadBase: tempBase(),
            downloader: { _, _, _, progress in progress(1) },
            installProbe: { _, _ in true },
            availableMemory: { .max }
        )
        models.refreshInstalled()

        let firstTask = Task { @MainActor in
            try await models.activate(firstModel, variant: first, context: 2048)
        }
        while await engine.startedLoads() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let secondTask = Task { @MainActor in
            try await models.activate(secondModel, variant: second, context: 2048)
        }
        _ = try await firstTask.value
        _ = try await secondTask.value

        XCTAssertEqual(models.active?.variant.id, second.id)
        XCTAssertTrue(models.engineResident)
        let actualResident = await engine.residentID()
        XCTAssertEqual(actualResident, second.id)
        XCTAssertFalse(models.switching)
    }

    func testEnsureResidentWithoutSelectionFailsBeforeTouchingEngine() async {
        let engine = ControlledResidencyEngine()
        let models = ModelManager(
            engine: engine,
            device: mac16,
            downloadBase: tempBase(),
            downloader: { _, _, _, progress in progress(1) },
            installProbe: { _, _ in true },
            availableMemory: { .max }
        )
        models.refreshInstalled()

        do {
            try await models.ensureResident(context: 2048)
            XCTFail("no selection must never be reported ready")
        } catch let error as ModelActivationError {
            XCTAssertEqual(error, .noSelection)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let loadStarts = await engine.startedLoads()
        XCTAssertEqual(loadStarts, 0)
    }

    func testEraseGatesNewModelWorkAndDrainsExistingWritersBeforeDeleting() async throws {
        let base = tempBase()
        let model = LLMCatalog.bonsai8b
        let activeVariant = try XCTUnwrap(model.variant(engine: .llamaCpp, quant: .binary1bit))
        let blockedVariant = try XCTUnwrap(
            LLMCatalog.bonsai4b.variant(engine: .llamaCpp, quant: .binary1bit)
        )
        let engineGate = DelayedCancellationExit()
        let downloadGate = DelayedCancellationExit()
        let engine = ErasureControlledEngine(loadGate: engineGate)
        let models = ModelManager(
            engine: engine,
            device: mac16,
            downloadBase: base,
            downloader: { _, _, _, _ in try await downloadGate.wait() },
            installProbe: { _, _ in true },
            availableMemory: { .max }
        )
        models.refreshInstalled()

        let sentinel = base.appending(component: "models/sentinel/weights.gguf")
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("weights".utf8).write(to: sentinel)

        let activation = Task { @MainActor in
            try await models.activate(model, variant: activeVariant, context: 2_048)
        }
        try await waitUntil { await engineGate.entryCount() == 1 }
        models.download(activeVariant)
        try await waitUntil { await downloadGate.entryCount() == 1 }

        let erasure = Task { @MainActor in
            try await models.eraseDownloadedData()
        }
        try await waitUntil { models.isErasingDownloadedData }

        models.download(blockedVariant)
        let startsDuringErase = await downloadGate.entryCount()
        XCTAssertEqual(startsDuringErase, 1,
                       "the erase gate must reject downloads created after its snapshot")
        XCTAssertNil(models.restoreSelection(model, variant: activeVariant),
                     "selection restoration is blocked for the whole destructive window")

        do {
            _ = try await models.activate(
                LLMCatalog.bonsai4b,
                variant: blockedVariant,
                context: 2_048
            )
            XCTFail("a new activation must not enter during erase")
        } catch is CancellationError {
            // The destructive gate cancels model operations instead of presenting a model failure.
        }
        do {
            try await models.ensureResident(context: 2_048)
            XCTFail("lazy residency must not enter during erase")
        } catch is CancellationError {
            // expected
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "erasure must wait until every pre-existing writer/load has really exited")
        await downloadGate.release()
        try await waitUntil { !models.isDownloading(activeVariant) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "draining downloads alone is insufficient while an engine load is still unwinding")

        await engineGate.release()
        try await erasure.value
        do {
            _ = try await activation.value
            XCTFail("the pre-existing activation should receive cancellation")
        } catch is CancellationError {
            // expected
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appending(component: "models").path))
        XCTAssertNil(models.active)
        XCTAssertFalse(models.engineResident)
        XCTAssertFalse(models.isErasingDownloadedData)
        XCTAssertFalse(models.switching)
        let unloads = await engine.unloadCount()
        XCTAssertGreaterThanOrEqual(unloads, 2,
                                    "the cancelled load cleans up, then erase drains the engine once more")
    }

    func testEraseTimeoutKeepsFilesAndGateUntilNonCooperativeLoadExits() async throws {
        let base = tempBase()
        let model = LLMCatalog.bonsai8b
        let variant = try XCTUnwrap(model.variant(engine: .llamaCpp, quant: .binary1bit))
        let engineGate = DelayedCancellationExit()
        let engine = ErasureControlledEngine(loadGate: engineGate)
        let models = ModelManager(
            engine: engine,
            device: mac16,
            downloadBase: base,
            downloader: { _, _, _, progress in progress(1) },
            installProbe: { _, _ in true },
            availableMemory: { .max },
            eraseDrainTimeout: .milliseconds(30)
        )
        models.refreshInstalled()

        let sentinel = base.appending(component: "models/sentinel/weights.gguf")
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("weights".utf8).write(to: sentinel)

        let activation = Task { @MainActor in
            try await models.activate(model, variant: variant, context: 2_048)
        }
        try await waitUntil { await engineGate.entryCount() == 1 }

        do {
            try await models.eraseDownloadedData()
            XCTFail("a non-cooperative load must hit the bounded drain")
        } catch let error as ModelDataDeletionError {
            XCTAssertTrue(error.failures.contains { $0.contains("timed out") })
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "timeout must never force-delete files under a live engine reader")
        XCTAssertTrue(models.isErasingDownloadedData,
                      "the safety gate stays closed until the abnormal reader really exits")
        models.download(variant)
        XCTAssertFalse(models.isDownloading(variant))
        XCTAssertNil(models.restoreSelection(model, variant: variant))

        await engineGate.release()
        do {
            _ = try await activation.value
            XCTFail("the load was cancelled by erase")
        } catch is CancellationError {
            // expected
        }
        try await waitUntil { !models.isErasingDownloadedData }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "gate recovery only unlocks; destructive work requires an explicit retry")

        try await models.eraseDownloadedData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appending(component: "models").path))
    }

    func testEraseDrainsEntireRegistryWriteChainBeforeSavingEmptySnapshot() async throws {
        let base = tempBase()
        let gate = RegistryWriteGate()
        let source = LLMCatalog.bonsai8b
        let variant = try XCTUnwrap(source.variant(engine: .llamaCpp, quant: .binary1bit))
        let explore = LLMModel(
            id: "registry-race",
            displayName: "Registry Race",
            family: .unknown,
            publisher: "Tests",
            summary: "Deterministic registry write ordering fixture.",
            license: .unknown,
            architecture: source.architecture,
            variants: [variant],
            defaultVariant: variant.quant
        )
        let models = ModelManager(
            engine: MockLLMEngine(),
            device: mac16,
            downloadBase: base,
            downloader: { _, _, _, progress in progress(1) },
            installProbe: { _, _ in true },
            availableMemory: { .max },
            registryWriter: { records in await gate.write(records) }
        )

        models.adopt(explore)
        try await waitUntil { await gate.writeCount() == 1 }
        models.adopt(explore) // queues a second snapshot behind the blocked first write

        let erasure = Task { @MainActor in try await models.eraseDownloadedData() }
        try await waitUntil { models.isErasingDownloadedData }
        let beforeRelease = await gate.recordedSnapshots()
        XCTAssertEqual(beforeRelease, [["registry-race"]])

        await gate.releaseFirstWrite()
        try await erasure.value
        let afterErase = await gate.recordedSnapshots()
        XCTAssertEqual(afterErase, [["registry-race"], []],
                       "the cancelled tail drains all older writes, then the empty snapshot is last")
    }
}
