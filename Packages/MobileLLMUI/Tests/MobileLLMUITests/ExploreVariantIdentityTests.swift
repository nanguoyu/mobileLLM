// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore
@testable import MobileLLMUI

private actor ArtifactRecordingEngine: LLMEngine {
    private var loadedIDs: [String] = []

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {
        loadedIDs.append(variant.id)
        progress(1)
    }

    func unload() async {}

    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func loads() -> [String] { loadedIDs }
}

/// Deliberately ignores cancellation until the test releases it, reproducing a URL/file writer that
/// needs time to unwind after Pause.
private actor DelayedDownloadExit {
    private var starts = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async throws {
        starts += 1
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }

    func startCount() -> Int { starts }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// One Explore GGUF repository commonly exposes Q4/Q5/Q8 as separate files. These regressions pin the
/// artifact-level identity through install, download, activation, deletion and legacy-registry migration.
@MainActor
final class ExploreVariantIdentityTests: XCTestCase {
    private let device = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "explore-identity-\(UUID().uuidString)")
    }

    private func model(revision: String = "commit-abc") -> LLMModel {
        RemoteModel(
            id: "community/Shared-7B-GGUF",
            name: "Shared 7B",
            publisher: "community",
            engine: .llamaCpp,
            downloads: 1,
            revision: revision,
            variants: [
                RemoteVariant(
                    quantLabel: "Q4_K_M",
                    repo: "community/Shared-7B-GGUF",
                    revision: revision,
                    fileName: "shared-Q4_K_M.gguf",
                    sizeBytes: 4_000),
                RemoteVariant(
                    quantLabel: "Q8_0",
                    repo: "community/Shared-7B-GGUF",
                    revision: revision,
                    fileName: "shared-Q8_0.gguf",
                    sizeBytes: 8_000)
            ]
        ).asLLMModel(paramsBillions: 7)
    }

    private func manager(
        base: URL,
        engine: any LLMEngine = MockLLMEngine(),
        downloader: @escaping ModelManager.Downloader = { _, _, _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
        },
        installProbe: @escaping @Sendable (LLMVariant, URL) -> Bool
    ) -> ModelManager {
        ModelManager(
            engine: engine,
            device: device,
            downloadBase: base,
            downloader: downloader,
            installProbe: installProbe,
            availableMemory: { .max }
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool,
                           timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { throw XCTSkip("timed out waiting for deterministic test state") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testInstallStateIsScopedToTheSelectedGGUFFile() throws {
        let model = model()
        let q4 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q4") == true })
        let q8 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q8") == true })
        let models = manager(base: tempBase()) { variant, _ in
            variant.source.fileName == q4.source.fileName
        }

        models.adopt(model)

        XCTAssertTrue(models.isInstalled(q4))
        XCTAssertFalse(models.isInstalled(q8),
                       "one installed file must not mark every quant in its repository installed")
        XCTAssertNotEqual(q4.id, q8.id)
    }

    func testDisjointQuantsHaveIndependentConcurrentDownloadState() async throws {
        let model = model()
        let q4 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q4") == true })
        let q8 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q8") == true })
        let models = manager(base: tempBase(), installProbe: { _, _ in false })
        models.adopt(model)

        models.download(q4)
        models.download(q8)

        XCTAssertTrue(models.isDownloading(q4))
        XCTAssertTrue(models.isDownloading(q8),
                      "disjoint files at the same revision may download without blocking one another")
        XCTAssertEqual(models.downloadState(q4)?.meter.totalBytes, q4.totalOnDiskBytes)
        XCTAssertEqual(models.downloadState(q8)?.meter.totalBytes, q8.totalOnDiskBytes)
        XCTAssertTrue(models.downloads.keys.contains(q4.id))
        XCTAssertTrue(models.downloads.keys.contains(q8.id))

        models.pauseDownload(q4)
        XCTAssertEqual(models.downloadState(q4)?.isPausing, true)
        XCTAssertEqual(models.downloadState(q4)?.isPaused, false)
        XCTAssertTrue(models.isDownloading(q8), "pausing Q4 must not pause Q8 from the same repo")
        try await waitUntil { !models.isDownloading(q4) }
        XCTAssertEqual(models.downloadState(q4)?.isPaused, true)
        models.pauseDownload(q8)
        try await waitUntil { !models.isDownloading(q8) }
    }

    func testPauseRetainsWriterReservationUntilExitAndDeleteWaitsForDrain() async throws {
        let base = tempBase()
        let model = model()
        let q4 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q4") == true })
        let gate = DelayedDownloadExit()
        let models = manager(
            base: base,
            downloader: { _, _, _, _ in try await gate.run() },
            installProbe: { _, _ in false }
        )
        models.adopt(model)

        let root = ModelDownloader(downloadBase: base)
            .localURL(repoId: q4.source.huggingFaceRepo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let part = root
            .appending(component: try XCTUnwrap(q4.source.fileName))
            .appendingPathExtension("part")
        try Data("partial".utf8).write(to: part)

        models.download(q4)
        try await waitUntil { await gate.startCount() == 1 }
        models.pauseDownload(q4)

        XCTAssertTrue(models.isDownloading(q4),
                      "Pause is a request; the old writer remains in-flight until it really exits")
        XCTAssertEqual(models.downloadState(q4)?.isPausing, true)
        XCTAssertEqual(models.downloadState(q4)?.isPaused, false,
                       "Resume is not offered until the old writer exits")
        models.download(q4)
        let startsAfterImmediateResume = await gate.startCount()
        XCTAssertEqual(startsAfterImmediateResume, 1,
                       "an immediate Resume must not create a second writer")

        models.delete(q4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path),
                      "Delete must not unlink a .part file while its writer still owns it")
        models.download(q4)
        let startsWhileDeletePending = await gate.startCount()
        XCTAssertEqual(startsWhileDeletePending, 1,
                       "a pending delete keeps the artifact reserved too")

        await gate.release()
        try await waitUntil {
            !models.isDownloading(q4) && !FileManager.default.fileExists(atPath: part.path)
        }
        XCTAssertNil(models.downloadState(q4))
    }

    func testActivationDoesNotShortCircuitAcrossQuantsInOneRepo() async throws {
        let model = model()
        let q4 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q4") == true })
        let q8 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q8") == true })
        let engine = ArtifactRecordingEngine()
        let models = manager(base: tempBase(), engine: engine, installProbe: { _, _ in true })
        models.adopt(model)

        _ = try await models.activate(model, variant: q4, context: 2_048)
        _ = try await models.activate(model, variant: q8, context: 2_048)

        let loadedIDs = await engine.loads()
        XCTAssertEqual(loadedIDs, [q4.id, q8.id],
                       "switching files must perform a second engine load")
        XCTAssertEqual(models.active?.variant.id, q8.id)
    }

    func testDeletingSiblingQuantPreservesActiveVariantAndItsFile() async throws {
        let base = tempBase()
        let model = model(revision: "main")
        let q4 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q4") == true })
        let q8 = try XCTUnwrap(model.variants.first { $0.source.fileName?.contains("Q8") == true })
        let root = ModelDownloader(downloadBase: base)
            .localURL(repoId: q4.source.huggingFaceRepo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let q4URL = root.appending(component: try XCTUnwrap(q4.source.fileName))
        let q8URL = root.appending(component: try XCTUnwrap(q8.source.fileName))
        try Data([4]).write(to: q4URL)
        try Data([8]).write(to: q8URL)

        let models = manager(
            base: base,
            engine: ArtifactRecordingEngine(),
            installProbe: ModelManager.defaultInstallProbe()
        )
        models.adopt(model)
        _ = try await models.activate(model, variant: q4, context: 2_048)

        models.delete(q8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: q4URL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: q8URL.path))
        XCTAssertEqual(models.active?.variant.id, q4.id,
                       "deleting Q8 must not deactivate active Q4 from the same repository")
        XCTAssertTrue(models.engineResident)
    }

    func testLegacyAdoptedRegistryUpgradesIdentityAndKeepsLegacyAlias() async throws {
        let base = tempBase()
        let current = model()
        let legacyVariants = current.variants.map {
            LLMVariant(
                quant: $0.quant,
                backend: $0.backend,
                onDiskBytes: $0.onDiskBytes,
                source: $0.source,
                visionProjector: $0.visionProjector
            )
        }
        XCTAssertEqual(Set(legacyVariants.map(\.id)).count, 1,
                       "the fixture reproduces the old repository-level collision")
        let legacy = LLMModel(
            id: current.id,
            displayName: current.displayName,
            family: current.family,
            publisher: current.publisher,
            summary: current.summary,
            license: current.license,
            architecture: current.architecture,
            variants: legacyVariants,
            defaultVariant: current.defaultVariant
        )
        try await DurableStore<LLMModel>(
            fileURL: base.appending(component: "adopted-models.json")
        ).save([legacy])

        let models = manager(base: base, installProbe: { _, _ in true })
        await models.loadAdoptedRegistry()
        let migrated = try XCTUnwrap(models.model(id: legacy.id))

        XCTAssertEqual(Set(migrated.variants.map(\.id)).count, 2)
        XCTAssertTrue(migrated.variants.allSatisfy { $0.identityScheme == .sourceArtifactV2 })
        XCTAssertTrue(migrated.variants.allSatisfy {
            $0.matchesPersistedID(legacyVariants[0].id)
        }, "old ids remain aliases; their lost quant distinction is inherently ambiguous")
    }
}
