// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore

/// Engine-aware memory governor (DESIGN §1 / §6): the llama.cpp GGUF path discounts mmap'd (clean-page)
/// weights so the fit is honestly better than MLX. Green requires the RAW weights to fit without banking
/// on the discount, so a model that only fits via clean pages reads honest `.tight` — purely size-driven.
final class LlamaCppGovernorTests: XCTestCase {

    private let phone8  = DeviceTier(physicalMemoryBytes: 8_000_000_000,  isPhone: true)
    private let phone12 = DeviceTier(physicalMemoryBytes: 12_000_000_000, isPhone: true)
    private let mac16   = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func gguf(_ model: LLMModel) -> LLMVariant {
        model.variant(engine: .llamaCpp, quant: .binary1bit)!
    }

    private func plan(_ model: LLMModel, _ device: DeviceTier, context: Int = 4096) -> LLMFit {
        LLMMemoryGovernor.plan(model: model, variant: gguf(model), device: device, context: context)
    }

    /// The 8B GGUF is comfortably green on EVERY device — the dense, mmap-friendly iPhone hero.
    func test8BGGUFComfortableEverywhere() {
        XCTAssertEqual(plan(LLMCatalog.bonsai8b, phone8),  .comfortable)
        XCTAssertEqual(plan(LLMCatalog.bonsai8b, phone12), .comfortable)
        XCTAssertEqual(plan(LLMCatalog.bonsai8b, mac16),   .comfortable)
        // Small models likewise.
        XCTAssertEqual(plan(LLMCatalog.bonsai4b,  phone8), .comfortable)
        XCTAssertEqual(plan(LLMCatalog.bonsai1_7b, phone8), .comfortable)
    }

    /// The 3.8 GB 27B Q1_0 GGUF: size-driven — comfortable on roomy devices (12 GB phone, 16 GB Mac,
    /// where the raw weights fit the green line), but honest `.tight` on the 8 GB phone (only the
    /// clean-page discount gets it under the ceiling → never a falsely confident green there).
    func test27BGGUFSizeDrivenAndMoreFeasibleThanMLX() {
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, phone12), .comfortable)
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, mac16),   .comfortable)
        guard case .tight = plan(LLMCatalog.bonsai27b, phone8) else {
            return XCTFail("27B GGUF should be runnable-but-tight on the 8 GB phone")
        }
        // The MLX 27B is unsupported on the 8 GB phone; the GGUF (mmap discount) is tight → more feasible.
        let mlx = LLMMemoryGovernor.plan(model: LLMCatalog.bonsai27b,
                                         variant: LLMCatalog.bonsai27b.variant(for: .binary1bit)!,
                                         device: phone8, context: 4096)
        XCTAssertEqual(mlx, .unsupported)
    }

    /// The llama.cpp fit is at least as good as the MLX fit for the same model+device (the discount
    /// never makes GGUF look worse) — demonstrated on the 8B where both engines ship a 1-bit variant.
    func testGGUFFitNeverWorseThanMLX8B() {
        func rank(_ f: LLMFit) -> Int { f == .comfortable ? 2 : (f.isSupported ? 1 : 0) }
        for device in [phone8, phone12, mac16] {
            let g = plan(LLMCatalog.bonsai8b, device)
            let m = LLMMemoryGovernor.plan(model: LLMCatalog.bonsai8b,
                                           variant: LLMCatalog.bonsai8b.variant(for: .binary1bit)!,
                                           device: device, context: 4096)
            XCTAssertGreaterThanOrEqual(rank(g), rank(m))
        }
    }
}

/// Regression guard (DESIGN §3): adding the engine-aware branch must leave the MLX numbers UNCHANGED.
/// These are the exact expected verdicts the resident-weights planner produced before the change.
final class MLXGovernorRegressionTests: XCTestCase {

    private let phone8  = DeviceTier(physicalMemoryBytes: 8_000_000_000,  isPhone: true)
    private let phone12 = DeviceTier(physicalMemoryBytes: 12_000_000_000, isPhone: true)
    private let mac16   = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func mlx(_ model: LLMModel, _ quant: QuantSpec, _ device: DeviceTier, context: Int = 4096) -> LLMFit {
        // MLX variants are listed first, so the quant-keyed lookup resolves to the MLX one.
        let variant = model.variant(engine: .mlx, quant: quant)!
        return LLMMemoryGovernor.plan(model: model, variant: variant, device: device, context: context)
    }

    func testMLXNumbersUnchanged() {
        XCTAssertEqual(mlx(LLMCatalog.bonsai27b, .binary1bit,  phone8),  .unsupported)
        XCTAssertEqual(mlx(LLMCatalog.bonsai27b, .binary1bit,  phone12), .comfortable)
        XCTAssertEqual(mlx(LLMCatalog.bonsai27b, .binary1bit,  mac16),   .comfortable)
        XCTAssertEqual(mlx(LLMCatalog.bonsai8b,  .binary1bit,  phone8),  .comfortable)
        XCTAssertEqual(mlx(LLMCatalog.bonsai8b,  .ternary2bit, phone8),  .comfortable)
        XCTAssertEqual(mlx(LLMCatalog.bonsai27b, .ternary2bit, phone12), .unsupported)
        // 27B ternary on the 16 GB Mac stays supported-but-tight.
        guard case .tight = mlx(LLMCatalog.bonsai27b, .ternary2bit, mac16) else {
            return XCTFail("27B ternary on a 16 GB Mac must remain tight")
        }
    }

    /// The MLX runtime overhead is unchanged at ~0.5 GB; llama.cpp is the slimmer ~0.35 GB.
    func testRuntimeOverheadPerEngine() {
        XCTAssertEqual(Backend.mlxFork.runtimeOverheadBytes,   500_000_000)
        XCTAssertEqual(Backend.mlxStock.runtimeOverheadBytes,  500_000_000)
        XCTAssertEqual(Backend.awqUnsupported.runtimeOverheadBytes, 500_000_000)
        XCTAssertEqual(Backend.llamaCppGGUF.runtimeOverheadBytes, 350_000_000)
    }
}
