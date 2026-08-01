// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Adopted-model persistence (B2.a / DESIGN §2.4): a community model downloaded from Explore must survive
/// relaunch — it lives in a durable registry beside the weights, merges back into `allModels`, and its
/// bytes count toward the storage total. A merely-browsed (not downloaded) model isn't worth keeping.
@MainActor
final class ModelRegistryTests: XCTestCase {

    private let device = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "reg-\(UUID().uuidString)")
    }

    /// A community model with one installable variant on a known repo (built the real Explore way).
    private func adopted(repo: String = "someone/Cool-Model") -> LLMModel {
        let remote = RemoteModel(id: repo, name: "Cool Model 7B", publisher: "someone",
                                 engine: .mlx, downloads: 100,
                                 variants: [RemoteVariant(quantLabel: "4-bit", repo: repo,
                                                          fileName: nil, sizeBytes: 1_000_000_000)])
        return remote.asLLMModel(paramsBillions: 7)
    }

    private func manager(base: URL, installedRepos: Set<String>) -> ModelManager {
        let m = ModelManager(engine: MockLLMEngine(), device: device, downloadBase: base,
                             downloader: { _, _, _, p in p(1) },
                             installProbe: { v, _ in installedRepos.contains(v.source.huggingFaceRepo) },
                             availableMemory: { .max })
        m.refreshInstalled()
        return m
    }

    func testAdoptedModelMergesIntoAllModelsIdempotently() {
        let m = manager(base: tempBase(), installedRepos: [])
        let model = adopted()
        XCTAssertFalse(m.allModels.contains { $0.id == model.id })
        m.adopt(model)
        XCTAssertTrue(m.allModels.contains { $0.id == model.id })
        m.adopt(model)   // idempotent
        XCTAssertEqual(m.allModels.filter { $0.id == model.id }.count, 1)
        XCTAssertEqual(m.model(id: model.id)?.id, model.id, "model(id:) resolves adopted ids")
    }

    func testInstalledBytesIncludesAdopted() {
        let model = adopted()
        let repo = model.variants[0].source.huggingFaceRepo
        let m = manager(base: tempBase(), installedRepos: [repo])
        // Catalog is not installed in this manager, so the only installed bytes are the adopted model's.
        m.adopt(model)
        XCTAssertTrue(m.installed.contains(model.variants[0].id))
        XCTAssertEqual(m.installedBytes, model.variants[0].totalOnDiskBytes)
    }

    func testRegistryRoundTripAcrossManagers() async {
        let base = tempBase()
        let model = adopted()
        let repo = model.variants[0].source.huggingFaceRepo

        // Manager A adopts an installed community model → it persists the registry (fire-and-forget).
        let a = manager(base: base, installedRepos: [repo])
        a.adopt(model)

        // Manager B (fresh memory, same base) loads it back. Poll so the async save has landed.
        let b = manager(base: base, installedRepos: [repo])
        var found = false
        for _ in 0..<50 {
            await b.loadAdoptedRegistry()
            if b.allModels.contains(where: { $0.id == model.id }) { found = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(found, "an installed adopted model must survive relaunch")
        XCTAssertTrue(b.installed.contains(model.variants[0].id))
        XCTAssertEqual(b.installedBytes, model.variants[0].totalOnDiskBytes)
    }

    func testBrowsedButNotInstalledIsNotPersisted() async {
        let base = tempBase()
        let model = adopted()

        // Not installed (probe false) → adopt keeps it in memory this session but does NOT persist it.
        let a = manager(base: base, installedRepos: [])
        a.adopt(model)
        XCTAssertTrue(a.allModels.contains { $0.id == model.id }, "still usable this session")
        try? await Task.sleep(nanoseconds: 200_000_000)

        let b = manager(base: base, installedRepos: [])
        await b.loadAdoptedRegistry()
        XCTAssertFalse(b.allModels.contains { $0.id == model.id },
                       "a browsed-but-not-downloaded model isn't kept across launches")
    }

    func testLegacyFabricatedMetadataMigratesAndFreshHubMetadataReplacesIt() async throws {
        let base = tempBase()
        let current = adopted(repo: "someone/Legacy-Model")
        let legacy = LLMModel(
            id: current.id,
            displayName: current.displayName,
            family: .qwen,
            publisher: current.publisher,
            summary: "Community model — loaded from its own template. Not hand-verified.",
            license: .apache2,
            architecture: current.architecture,
            variants: current.variants,
            defaultVariant: current.defaultVariant
        )
        let registry = DurableStore<LLMModel>(
            fileURL: base.appending(component: "adopted-models.json")
        )
        try await registry.save([legacy])

        let models = manager(base: base, installedRepos: [legacy.variants[0].source.huggingFaceRepo])
        await models.loadAdoptedRegistry()
        XCTAssertEqual(models.model(id: legacy.id)?.family, .unknown)
        XCTAssertEqual(models.model(id: legacy.id)?.license, .unknown,
                       "legacy Explore guesses must not survive an upgrade")

        let refreshed = LLMModel(
            id: legacy.id,
            displayName: legacy.displayName,
            family: .gemma,
            publisher: legacy.publisher,
            summary: "Community model — Hub metadata when available; not hand-verified.",
            license: .gemma,
            architecture: legacy.architecture,
            variants: legacy.variants,
            defaultVariant: legacy.defaultVariant
        )
        models.adopt(refreshed)
        XCTAssertEqual(models.model(id: legacy.id)?.family, .gemma)
        XCTAssertEqual(models.model(id: legacy.id)?.license, .gemma,
                       "a fresh Hub result replaces the conservative migrated placeholder")
    }

    func testInterruptedExplorePartialSurvivesLaterUnrelatedRegistryWrite() async throws {
        let base = tempBase()
        let interruptedID = "community/Interrupted-GGUF"
        let interruptedVariant = LLMVariant(
            quant: .gguf4bit,
            backend: .llamaCppGGUF,
            onDiskBytes: 100,
            source: ModelSource(huggingFaceRepo: interruptedID,
                                revision: "commit-interrupted",
                                fileName: "weights.gguf"),
            identityScheme: .sourceArtifactV2
        )
        let interrupted = LLMModel(
            id: interruptedID,
            displayName: "Interrupted",
            family: .unknown,
            publisher: "community",
            summary: "Interrupted Explore download fixture",
            license: .unknown,
            architecture: LLMCatalog.bonsai4b.architecture,
            variants: [interruptedVariant],
            defaultVariant: .gguf4bit
        )
        let root = ModelDownloader(downloadBase: base).localURL(repoId: interruptedID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("partial".utf8).write(
            to: root.appending(component: "weights.gguf").appendingPathExtension("part")
        )
        let registryURL = base.appending(component: "adopted-models.json")
        try await DurableStore<LLMModel>(fileURL: registryURL).save([interrupted])

        let unrelatedID = "community/Installed-Unrelated-GGUF"
        let unrelatedVariant = LLMVariant(
            quant: .gguf4bit,
            backend: .llamaCppGGUF,
            onDiskBytes: 100,
            source: ModelSource(huggingFaceRepo: unrelatedID,
                                revision: "commit-unrelated",
                                fileName: "other.gguf"),
            identityScheme: .sourceArtifactV2
        )
        let unrelated = LLMModel(
            id: unrelatedID,
            displayName: "Unrelated",
            family: .unknown,
            publisher: "community",
            summary: "Unrelated registry write fixture",
            license: .unknown,
            architecture: LLMCatalog.bonsai4b.architecture,
            variants: [unrelatedVariant],
            defaultVariant: .gguf4bit
        )
        let second = ModelManager(
            engine: MockLLMEngine(),
            device: device,
            downloadBase: base,
            downloader: { _, _, _, progress in progress(1) },
            installProbe: { variant, _ in variant.id == unrelatedVariant.id },
            availableMemory: { .max }
        )
        await second.loadAdoptedRegistry()
        XCTAssertNotNil(second.model(id: interruptedID))

        second.adopt(unrelated)
        let persistedRegistry = DurableStore<LLMModel>(fileURL: registryURL)
        let deadline = Date().addingTimeInterval(3)
        var didPersistUnrelatedModel = false
        while Date() < deadline {
            if await persistedRegistry.load().contains(where: { $0.id == unrelatedID }) {
                didPersistUnrelatedModel = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(didPersistUnrelatedModel,
                      "the unrelated write must actually land before registry retention is evaluated")

        let third = manager(base: base, installedRepos: [])
        await third.loadAdoptedRegistry()
        XCTAssertNotNil(third.model(id: interruptedID),
                        "an unrelated write must not orphan resumable Explore partial bytes")
    }
}
