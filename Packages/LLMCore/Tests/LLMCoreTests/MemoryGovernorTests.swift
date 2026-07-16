// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore

final class MemoryGovernorTests: XCTestCase {

    private let phone8  = DeviceTier(physicalMemoryBytes: 8_000_000_000,  isPhone: true)
    private let phone12 = DeviceTier(physicalMemoryBytes: 12_000_000_000, isPhone: true)
    private let mac16   = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func plan(_ model: LLMModel, _ quant: QuantSpec, _ device: DeviceTier, context: Int = 4096) -> LLMFit {
        LLMMemoryGovernor.plan(model: model, variant: model.variant(for: quant)!,
                               device: device, context: context)
    }

    /// The fit truth table at 4K context (DESIGN §1.2). §1.2 only encodes 🔴 (unsupported) vs 🟢
    /// (runnable = comfortable or tight); the green-vs-amber split follows §2.5's 0.70·ceiling rule.
    func testFitTruthTable() {
        // --- 8 GB iPhone 16 Pro (ceiling 5.3 GB) ---
        // 27B is the weights, not the KV: even 1-bit's weights+runtime exceed the ceiling → 🔴.
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, .binary1bit,  phone8), .unsupported)
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, .ternary2bit, phone8), .unsupported)
        // 8B is the iPhone hero → 🟢 comfortable.
        XCTAssertEqual(plan(LLMCatalog.bonsai8b,  .binary1bit,  phone8), .comfortable)
        XCTAssertEqual(plan(LLMCatalog.bonsai8b,  .ternary2bit, phone8), .comfortable)

        // --- 12 GB iPhone (ceiling ≈ 8.64 GB) ---
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, .binary1bit,  phone12), .comfortable)   // 🟢
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, .ternary2bit, phone12), .unsupported)   // 🔴 (weights > ceiling)
        XCTAssertEqual(plan(LLMCatalog.bonsai8b,  .binary1bit,  phone12), .comfortable)
        XCTAssertEqual(plan(LLMCatalog.bonsai8b,  .ternary2bit, phone12), .comfortable)

        // --- 16 GB Mac (ceiling 12 GB) ---
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, .binary1bit,  mac16), .comfortable)     // 🟢
        XCTAssertTrue(plan(LLMCatalog.bonsai27b, .ternary2bit, mac16).isSupported)        // 🟢 (runnable)
        if case .tight = plan(LLMCatalog.bonsai27b, .ternary2bit, mac16) {} else {
            XCTFail("27B ternary on a 16 GB Mac is supported but tight (>70% of the budget at 4K)")
        }
        XCTAssertEqual(plan(LLMCatalog.bonsai8b,  .binary1bit,  mac16), .comfortable)
        XCTAssertEqual(plan(LLMCatalog.bonsai8b,  .ternary2bit, mac16), .comfortable)
    }

    /// The unsupported verdict is about the weights, not the KV: dropping context can't rescue 27B on
    /// the 8 GB phone.
    func testShortContextCannotRescueWeights() {
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, .binary1bit, phone8, context: 256), .unsupported)
        XCTAssertEqual(plan(LLMCatalog.bonsai27b, .binary1bit, phone8, context: 0),   .unsupported)
    }

    /// A tight plan reports a max context above the requested one when there is still ceiling headroom.
    func testTightReportsMaxContext() {
        let fit = plan(LLMCatalog.bonsai27b, .ternary2bit, mac16, context: 4096)
        guard case let .tight(maxContext) = fit else { return XCTFail("expected tight") }
        XCTAssertGreaterThan(maxContext, 4096)   // still runnable at 4K, ceiling-limited higher up
    }

    /// Resident ceilings match DESIGN §1.2.
    func testResidentCeilings() {
        XCTAssertEqual(LLMMemoryGovernor.residentCeilingBytes(for: phone8), 5_300_000_000)
        XCTAssertEqual(LLMMemoryGovernor.residentCeilingBytes(for: phone12), 8_640_000_000)   // 0.72 · 12e9
        XCTAssertEqual(LLMMemoryGovernor.residentCeilingBytes(for: mac16), 12_000_000_000)     // min(12e9, 12.8e9)
    }

    // MARK: - The OS-provided system model (the `.apple` engine)

    /// The system model is free: the OS holds the weights AND the KV cache out of process, so it reads
    /// `.comfortable` on every device at every context — including the smallest phone at the longest
    /// context, where every resident model is unsupported. None of this is weight math.
    func testSystemModelIsAlwaysComfortable() {
        let model = LLMCatalog.appleSystem
        let variant = model.defaultVariantValue
        for device in [phone8, phone12, mac16] {
            for context in [0, 4096, 262_144] {
                XCTAssertEqual(LLMMemoryGovernor.plan(model: model, variant: variant,
                                                      device: device, context: context),
                               .comfortable,
                               "the system model costs us nothing (\(device.physicalMemoryBytes) B, \(context) ctx)")
            }
        }
    }

    /// The verdict must not depend on the device at all — not even one far too small to hold any model.
    /// This pins that `plan` SHORT-CIRCUITS for `.apple`, rather than happening to pass the resident
    /// weight math because the catalog entry's inputs are zeros.
    func testSystemModelIgnoresDeviceSize() {
        let tiny = DeviceTier(physicalMemoryBytes: 1_000_000, isPhone: true)
        XCTAssertEqual(LLMMemoryGovernor.plan(model: LLMCatalog.appleSystem,
                                              variant: LLMCatalog.appleSystem.defaultVariantValue,
                                              device: tiny, context: 262_144),
                       .comfortable)
    }
}
