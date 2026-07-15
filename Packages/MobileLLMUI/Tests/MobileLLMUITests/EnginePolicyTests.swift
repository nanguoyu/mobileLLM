// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// The pure Auto engine-selection policy (DESIGN §6): `AppSettings.preferredVariant` picks the greenest
/// fit, tie-breaking MLX on Mac and llama.cpp on iPhone; explicit preferences pin an engine.
final class EnginePolicyTests: XCTestCase {

    private let phone8 = DeviceTier(physicalMemoryBytes: 8_000_000_000,  isPhone: true)
    private let phone12 = DeviceTier(physicalMemoryBytes: 12_000_000_000, isPhone: true)
    private let mac16  = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func pick(_ model: LLMModel, _ device: DeviceTier, _ pref: EnginePreference,
                      context: Int = 4096) -> LLMVariant {
        AppSettings.preferredVariant(for: model, device: device, preference: pref, context: context)
    }

    /// Auto on a tie (8B is green on both engines): iPhone breaks to llama.cpp, Mac to MLX.
    func testAutoTieBreaksByDevice() {
        XCTAssertEqual(pick(LLMCatalog.bonsai8b, phone8, .auto).engine, .llamaCpp)
        XCTAssertEqual(pick(LLMCatalog.bonsai8b, phone12, .auto).engine, .llamaCpp)
        XCTAssertEqual(pick(LLMCatalog.bonsai8b, mac16, .auto).engine, .mlx)
    }

    /// Auto keeps the default quant on the tie (1-bit, not ternary) alongside the device engine.
    func testAutoPrefersDefaultQuant() {
        let v = pick(LLMCatalog.bonsai8b, mac16, .auto)
        XCTAssertEqual(v.quant, .binary1bit)
        XCTAssertEqual(v.engine, .mlx)
    }

    /// Auto on the 27B / 8 GB phone: the MLX 1-bit is unsupported (weights > ceiling) but the GGUF is
    /// runnable (mmap discount) → Auto picks the llama.cpp variant, the greener fit.
    func testAuto27BOn8GBPrefersLlamaCpp() {
        let v = pick(LLMCatalog.bonsai27b, phone8, .auto)
        XCTAssertEqual(v.engine, .llamaCpp, "the GGUF 27B is the only runnable option on the 8 GB phone")
    }

    /// An explicit MLX preference pins MLX even on a phone; llama.cpp preference pins llama.cpp on Mac.
    func testExplicitPreferencePinsEngine() {
        XCTAssertEqual(pick(LLMCatalog.bonsai8b, phone8, .mlx).engine, .mlx)
        XCTAssertEqual(pick(LLMCatalog.bonsai8b, mac16, .llamaCpp).engine, .llamaCpp)
    }

    /// The returned variant is always a real variant of the model.
    func testReturnsAModelVariant() {
        for model in LLMCatalog.all {
            for device in [phone8, phone12, mac16] {
                for pref in EnginePreference.allCases {
                    let v = pick(model, device, pref)
                    XCTAssertTrue(model.variants.contains(v), "\(model.id)/\(device)/\(pref) → not a variant")
                }
            }
        }
    }
}
