// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// OOM pre-flight math (B2.b / DESIGN §2.5). The estimate must be engine-aware and consistent with the
/// governor's mmap discount, so a llama.cpp GGUF the fit badge shows runnable isn't refused outright by an
/// over-counted raw-bytes check — and "Try anyway" (force) always skips the estimate.
@MainActor
final class ActivationPreflightTests: XCTestCase {

    private let phone8 = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)

    private func manager(available: Int64) -> ModelManager {
        let m = ModelManager(engine: MockLLMEngine(), device: phone8,
                             downloadBase: FileManager.default.temporaryDirectory.appending(component: "pf-\(UUID().uuidString)"),
                             downloader: { _, _, p in p(1) },
                             installProbe: { _, _ in true },
                             availableMemory: { available })
        m.refreshInstalled()
        return m
    }

    private func rawPeak(_ model: LLMModel, _ v: LLMVariant, context: Int) -> Int64 {
        v.onDiskBytes + v.backend.runtimeOverheadBytes + model.architecture.attention.kvBytes(tokens: context)
    }

    /// A GGUF's hard-resident estimate is discounted below its raw footprint; MLX counts weights in full.
    func testEngineAwarePeakDiscountsGGUF() {
        let model = LLMCatalog.bonsai8b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let mlx = model.variant(engine: .mlx, quant: .binary1bit)!
        let ggufPeak = ModelManager.estimatedResidentPeakBytes(model: model, variant: gguf, context: 4096)
        let mlxPeak = ModelManager.estimatedResidentPeakBytes(model: model, variant: mlx, context: 4096)
        XCTAssertLessThan(ggufPeak, rawPeak(model, gguf, context: 4096), "mmap discount lowers the GGUF estimate")
        XCTAssertEqual(mlxPeak, rawPeak(model, mlx, context: 4096), "MLX weights are all hard-resident")
    }

    /// A memory probe that can't answer (the simulator's os_proc_available_memory returns 0) must read as
    /// UNKNOWN and attempt the load — refusing on it produced a bogus "needs 1.4 GB, Zero KB free" banner.
    func testUnknownAvailableMemoryDoesNotRefuse() async throws {
        let model = LLMCatalog.bonsai8b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let m = manager(available: 0)
        _ = try await m.activate(model, variant: gguf, context: 4096)   // must not throw insufficientMemory
        XCTAssertEqual(m.active?.variant.id, gguf.id)
    }

    /// THE fix: a GGUF that fits only via the mmap discount must not be refused when raw bytes exceed free
    /// memory — the badge shows it runnable, so a non-forced Use loads it instead of dead-ending.
    func testGGUFFitsViaDiscountIsNotRefused() async throws {
        let model = LLMCatalog.bonsai27b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let discounted = ModelManager.estimatedResidentPeakBytes(model: model, variant: gguf, context: 2048)
        let raw = rawPeak(model, gguf, context: 2048)
        let available = (discounted + raw) / 2       // above discounted, below raw
        XCTAssertGreaterThan(available, discounted)
        XCTAssertLessThan(available, raw)
        let loaded = try await manager(available: available).activate(model, variant: gguf, context: 2048, force: false)
        XCTAssertEqual(loaded.variant.id, gguf.id)
    }

    /// When even the discounted peak exceeds free memory, a non-forced activate is refused (recoverably).
    func testRefusesWhenDiscountedPeakExceedsFree() async {
        let model = LLMCatalog.bonsai27b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let discounted = ModelManager.estimatedResidentPeakBytes(model: model, variant: gguf, context: 2048)
        do {
            _ = try await manager(available: discounted - 500_000_000).activate(model, variant: gguf, context: 2048, force: false)
            XCTFail("should have refused")
        } catch let error as ModelActivationError {
            guard case .insufficientMemory = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// "Try anyway" (force) skips the pre-flight entirely — the device is the authority.
    func testForceSkipsPreflight() async throws {
        let model = LLMCatalog.bonsai27b
        let gguf = model.variant(engine: .llamaCpp, quant: .binary1bit)!
        let loaded = try await manager(available: 100_000_000).activate(model, variant: gguf, context: 2048, force: true)
        XCTAssertEqual(loaded.variant.id, gguf.id)
    }

    /// The activating-variant + progress state is published while loading and cleared afterward.
    func testActivationStateClearsAfterLoad() async throws {
        let model = LLMCatalog.bonsai8b
        let mlx = model.variant(engine: .mlx, quant: .binary1bit)!
        let m = manager(available: .max)
        _ = try await m.activate(model, variant: mlx, context: 2048, force: false)
        XCTAssertNil(m.activatingVariantID, "cleared once the load finishes")
        XCTAssertNil(m.loadProgress)
        XCTAssertFalse(m.switching)
        XCTAssertEqual(m.active?.variant.id, mlx.id)
    }
}
