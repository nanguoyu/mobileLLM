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

private struct ExploreWaitTimeout: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
            if Date() > deadline {
                throw ExploreWaitTimeout(message: "timed out waiting for deterministic test state")
            }
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

    func testDeletingSiblingVariantPreservesSharedProjectorAndDoesNotCancelWriter() async throws {
        let base = tempBase()
        let repo = "community/Shared-Vision-GGUF"
        let projector = VisionProjector(fileName: "shared-mmproj.gguf", sizeBytes: 10)
        let first = LLMVariant(
            quant: .gguf4bit,
            backend: .llamaCppGGUF,
            onDiskBytes: 100,
            source: ModelSource(huggingFaceRepo: repo, revision: "commit-vision", fileName: "first.gguf"),
            visionProjector: projector,
            identityScheme: .sourceArtifactV2
        )
        let sibling = LLMVariant(
            quant: .other("Q5_K_M"),
            backend: .llamaCppGGUF,
            onDiskBytes: 120,
            source: ModelSource(huggingFaceRepo: repo, revision: "commit-vision", fileName: "sibling.gguf"),
            visionProjector: projector,
            identityScheme: .sourceArtifactV2
        )
        let gate = DelayedDownloadExit()
        let models = manager(
            base: base,
            downloader: { _, _, _, _ in try await gate.run() },
            installProbe: { _, _ in false }
        )
        models.adopt(LLMModel(
            id: repo,
            displayName: "Shared vision",
            family: .unknown,
            publisher: "community",
            summary: "fixture",
            license: .unknown,
            architecture: LLMCatalog.bonsai4b.architecture,
            variants: [first, sibling],
            defaultVariant: .gguf4bit
        ))
        let root = ModelDownloader(downloadBase: base).localURL(repoId: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sharedPart = root.appending(component: projector.fileName).appendingPathExtension("part")
        try Data("partial projector bytes".utf8).write(to: sharedPart)
        try Data("sibling weights".utf8).write(to: root.appending(component: "sibling.gguf"))

        models.download(first)
        try await waitUntil { await gate.startCount() == 1 }
        models.delete(sibling)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedPart.path),
                      "deleting a sibling must preserve the projector owned by the live writer")
        XCTAssertTrue(models.isDownloading(first),
                      "a sibling delete must not cancel an unrelated download that shares its projector")

        await gate.release()
        try await waitUntil {
            !models.isDownloading(first)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedPart.path),
                      "the surviving variant keeps its resumable projector partial")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(component: "sibling.gguf").path))
    }

    func testDeletingInstalledSiblingKeepsSharedProjectorAndOtherVariantInstalled() throws {
        let base = tempBase()
        let repo = "community/Installed-Shared-Vision-GGUF"
        let projector = VisionProjector(fileName: "shared-mmproj.gguf", sizeBytes: 10)
        let first = LLMVariant(
            quant: .gguf4bit,
            backend: .llamaCppGGUF,
            onDiskBytes: 100,
            source: ModelSource(huggingFaceRepo: repo, revision: "commit-vision", fileName: "first.gguf"),
            visionProjector: projector,
            identityScheme: .sourceArtifactV2
        )
        let sibling = LLMVariant(
            quant: .other("Q5_K_M"),
            backend: .llamaCppGGUF,
            onDiskBytes: 120,
            source: ModelSource(huggingFaceRepo: repo, revision: "commit-vision", fileName: "sibling.gguf"),
            visionProjector: projector,
            identityScheme: .sourceArtifactV2
        )
        let model = LLMModel(
            id: repo,
            displayName: "Installed shared vision",
            family: .unknown,
            publisher: "community",
            summary: "fixture",
            license: .unknown,
            architecture: LLMCatalog.bonsai4b.architecture,
            variants: [first, sibling],
            defaultVariant: .gguf4bit
        )
        let root = ModelDownloader(downloadBase: base).localURL(repoId: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["first.gguf", "sibling.gguf", projector.fileName] {
            try Data(name.utf8).write(to: root.appending(component: name))
        }
        let models = manager(base: base) { variant, _ in
            variant.requiredFileNames.allSatisfy {
                FileManager.default.fileExists(atPath: root.appending(component: $0).path)
            }
        }
        models.adopt(model)
        XCTAssertTrue(models.isInstalled(first))
        XCTAssertTrue(models.isInstalled(sibling))

        models.delete(sibling)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(component: projector.fileName).path))
        XCTAssertTrue(models.isInstalled(first),
                      "deleting one installed quant must not break a sibling that owns the same projector")
        XCTAssertFalse(models.isInstalled(sibling))
    }

    func testColdRestartPartialClaimsSharedProjectorWhenDeletingSibling() async throws {
        let base = tempBase()
        let repo = "community/Cold-Partial-Shared-Vision-GGUF"
        let projector = VisionProjector(fileName: "shared-mmproj.gguf", sizeBytes: 10)
        let survivor = LLMVariant(
            quant: .gguf4bit,
            backend: .llamaCppGGUF,
            onDiskBytes: 100,
            source: ModelSource(huggingFaceRepo: repo, revision: "commit-vision", fileName: "survivor.gguf"),
            visionProjector: projector,
            identityScheme: .sourceArtifactV2
        )
        let deleted = LLMVariant(
            quant: .other("Q5_K_M"),
            backend: .llamaCppGGUF,
            onDiskBytes: 120,
            source: ModelSource(huggingFaceRepo: repo, revision: "commit-vision", fileName: "deleted.gguf"),
            visionProjector: projector,
            identityScheme: .sourceArtifactV2
        )
        let model = LLMModel(
            id: repo,
            displayName: "Cold partial shared vision",
            family: .unknown,
            publisher: "community",
            summary: "fixture",
            license: .unknown,
            architecture: LLMCatalog.bonsai4b.architecture,
            variants: [survivor, deleted],
            defaultVariant: .gguf4bit
        )
        let root = ModelDownloader(downloadBase: base).localURL(repoId: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let survivorPart = root.appending(component: "survivor.gguf").appendingPathExtension("part")
        let sharedPart = root.appending(component: projector.fileName).appendingPathExtension("part")
        let deletedWeight = root.appending(component: "deleted.gguf")
        try Data("survivor partial".utf8).write(to: survivorPart)
        try Data("projector partial".utf8).write(to: sharedPart)
        try Data("deleted weights".utf8).write(to: deletedWeight)
        try await DurableStore<LLMModel>(
            fileURL: base.appending(component: "adopted-models.json")
        ).save([model])

        // A fresh manager has no in-memory download state. Its only evidence that the survivor owns the
        // shared projector is the resumable bytes restored from disk through the adopted registry.
        let restarted = manager(base: base, installProbe: { _, _ in false })
        await restarted.loadAdoptedRegistry()
        XCTAssertTrue(restarted.downloads.isEmpty)
        let restored = try XCTUnwrap(restarted.model(id: repo))
        let restoredDeleted = try XCTUnwrap(restored.variants.first { $0.id == deleted.id })

        restarted.delete(restoredDeleted)

        XCTAssertTrue(FileManager.default.fileExists(atPath: survivorPart.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedPart.path),
                      "deleting a sibling after relaunch must preserve the survivor's cold projector partial")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedWeight.path))
    }

    func testUntouchedSiblingDoesNotKeepLastSharedProjectorAlive() throws {
        let base = tempBase()
        let repo = "community/Last-Shared-Vision-GGUF"
        let projector = VisionProjector(fileName: "shared-mmproj.gguf", sizeBytes: 10)
        let installed = LLMVariant(
            quant: .gguf4bit,
            backend: .llamaCppGGUF,
            onDiskBytes: 100,
            source: ModelSource(huggingFaceRepo: repo, revision: "commit-vision", fileName: "installed.gguf"),
            visionProjector: projector,
            identityScheme: .sourceArtifactV2
        )
        let untouched = LLMVariant(
            quant: .other("Q5_K_M"),
            backend: .llamaCppGGUF,
            onDiskBytes: 120,
            source: ModelSource(huggingFaceRepo: repo, revision: "commit-vision", fileName: "untouched.gguf"),
            visionProjector: projector,
            identityScheme: .sourceArtifactV2
        )
        let model = LLMModel(
            id: repo,
            displayName: "Last shared vision",
            family: .unknown,
            publisher: "community",
            summary: "fixture",
            license: .unknown,
            architecture: LLMCatalog.bonsai4b.architecture,
            variants: [installed, untouched],
            defaultVariant: .gguf4bit
        )
        let root = ModelDownloader(downloadBase: base).localURL(repoId: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installedWeight = root.appending(component: "installed.gguf")
        let projectorFile = root.appending(component: projector.fileName)
        try Data("installed weights".utf8).write(to: installedWeight)
        try Data("projector".utf8).write(to: projectorFile)
        let models = manager(base: base) { variant, _ in
            variant.id == installed.id
                && variant.requiredFileNames.allSatisfy {
                    FileManager.default.fileExists(atPath: root.appending(component: $0).path)
                }
        }
        models.adopt(model)
        XCTAssertTrue(models.isInstalled(installed))
        XCTAssertFalse(models.isInstalled(untouched))

        models.delete(installed)

        XCTAssertFalse(FileManager.default.fileExists(atPath: installedWeight.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectorFile.path),
                       "a never-downloaded sibling must not orphan the last shared projector")
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
