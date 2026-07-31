// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Memory-fit estimates are useful catalog guidance, but this open-source app must let an installed
/// model make a real engine-load attempt. These regressions ensure neither explicit activation nor the
/// lazy first-use path turns a low live-memory reading into a safety refusal.
@MainActor
final class ActivationPreflightTests: XCTestCase {

    private let phone8 = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)

    private func manager(available: Int64, device: DeviceTier? = nil) -> ModelManager {
        let m = ModelManager(
            engine: MockLLMEngine(),
            device: device ?? phone8,
            downloadBase: FileManager.default.temporaryDirectory.appending(component: "pf-\(UUID().uuidString)"),
            downloader: { _, _, _, progress in progress(1) },
            installProbe: { _, _ in true },
            availableMemory: { available }
        )
        m.refreshInstalled()
        return m
    }

    private func rawPeak(_ model: LLMModel, _ variant: LLMVariant, context: Int) -> Int64 {
        variant.totalOnDiskBytes
            + variant.backend.runtimeOverheadBytes
            + model.architecture.attention.kvBytes(tokens: context)
    }

    /// The informational estimate remains engine-aware: mmap-friendly GGUF discounts reclaimable clean
    /// pages while MLX counts its anonymous/dirty weights in full.
    func testAdvisoryEstimateDiscountsGGUF() {
        let model = LLMCatalog.bonsai8b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let mlx = model.variant(engine: .mlx, quant: .binary1bit)!
        let ggufPeak = ModelManager.estimatedResidentPeakBytes(model: model, variant: gguf, context: 4096)
        let mlxPeak = ModelManager.estimatedResidentPeakBytes(model: model, variant: mlx, context: 4096)
        XCTAssertLessThan(ggufPeak, rawPeak(model, gguf, context: 4096))
        XCTAssertEqual(mlxPeak, rawPeak(model, mlx, context: 4096))
    }

    func testLowReportedMemoryDoesNotBlockActivation() async throws {
        let model = LLMCatalog.bonsai27b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let models = manager(available: 1)

        let loaded = try await models.activate(model, variant: gguf, context: 8192)

        XCTAssertEqual(loaded.variant.id, gguf.id)
        XCTAssertEqual(models.active?.variant.id, gguf.id)
        XCTAssertTrue(models.engineResident)
    }

    func testLowReportedMemoryDoesNotBlockLazyEnsureResident() async throws {
        let model = LLMCatalog.bonsai27b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let models = manager(available: 1)
        XCTAssertNotNil(models.restoreSelection(model, variant: gguf))
        XCTAssertFalse(models.engineResident)

        try await models.ensureResident(context: 8192)

        XCTAssertTrue(models.engineResident)
        XCTAssertEqual(models.active?.variant.id, gguf.id)
    }

    /// Even the strongest advisory verdict cannot become an authorization check. This protects both the
    /// model-card Use button contract and non-UI callers.
    func testUnsupportedEstimateStillAttemptsInstalledModel() async throws {
        let tinyPhone = DeviceTier(physicalMemoryBytes: 1_000_000_000, isPhone: true)
        let model = LLMCatalog.qwen36_27b
        let gguf = model.variant(engine: .llamaCpp, quant: .gguf4bit)!
        let models = manager(available: 1, device: tinyPhone)
        XCTAssertEqual(models.fitPresentation(model, gguf, context: 8192), .unsupported)

        let loaded = try await models.activate(model, variant: gguf, context: 8192)

        XCTAssertEqual(loaded.variant.id, gguf.id)
        XCTAssertTrue(models.engineResident)
    }

    /// The activating-variant + progress state is published while loading and cleared afterward.
    func testActivationStateClearsAfterLoad() async throws {
        let model = LLMCatalog.bonsai8b
        let mlx = model.variant(engine: .mlx, quant: .binary1bit)!
        let models = manager(available: 1)
        _ = try await models.activate(model, variant: mlx, context: 2048, force: false)
        XCTAssertNil(models.activatingVariantID)
        XCTAssertNil(models.loadProgress)
        XCTAssertFalse(models.switching)
        XCTAssertEqual(models.active?.variant.id, mlx.id)
    }
}
