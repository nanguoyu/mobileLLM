// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore
import AppRuntime

/// The context ladder is bounded by two different ceilings — the checkpoint's training length and the
/// device's RAM — and the bug worth guarding is conflating them.
final class ContextPolicyTests: XCTestCase {

    /// A dense 8B-ish model with a settable native context.
    private func model(native: Int) -> LLMModel {
        LLMModel(id: "t", displayName: "T", family: .qwen, publisher: "p", summary: "s", license: .apache2,
                 architecture: LLMArchitecture(
                    modelType: "qwen3", swiftModelClass: "Qwen3Model", hidden: 4096, layers: 36,
                    vocab: 151_669, tieWordEmbeddings: false,
                    attention: .fullAttention(kvHeads: 8, headDim: 128, layers: 36),
                    nativeContext: native, thinkingCapable: false, eos: "<|im_end|>",
                    chatTemplate: .repoFile("chat_template.jinja")),
                 variants: [LLMVariant(quant: .ternary2bit, backend: .mlxStock, onDiskBytes: 4_500_000_000,
                                       source: ModelSource(huggingFaceRepo: "r"))],
                 defaultVariant: .ternary2bit)
    }

    func testOptionsStopAtTheModelsNativeContext() {
        XCTAssertEqual(ContextPolicy.options(for: model(native: 8192)), [2048, 4096, 8192])
        XCTAssertEqual(ContextPolicy.options(for: model(native: 262_144)), ContextPolicy.ladder)
    }

    func testOptionsIncludeANonPowerOfTwoNativeMax() {
        // A 40K model should still be able to ask for all 40K.
        let options = ContextPolicy.options(for: model(native: 40_000))
        XCTAssertEqual(options.last, 40_000)
        XCTAssertEqual(options.dropLast(), [2048, 4096, 8192, 16_384, 32_768])
    }

    func testEffectiveClampsToTheModelNotThroughIt() {
        // The live case: a global 32K setting aimed at a 4K community checkpoint.
        XCTAssertEqual(ContextPolicy.effective(requested: 32_768, model: model(native: 4096)), 4096)
        // Under the ceiling → the request stands.
        XCTAssertEqual(ContextPolicy.effective(requested: 8192, model: model(native: 262_144)), 8192)
        // Never below the floor.
        XCTAssertEqual(ContextPolicy.effective(requested: 0, model: model(native: 262_144)), 2048)
    }

    func testLargestFittingIsBoundedByRAMNotTheCheckpoint() {
        let m = model(native: 262_144)          // trained to 256K…
        let phone = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)
        let onPhone = ContextPolicy.largestFitting(model: m, variant: m.variants[0], device: phone)
        XCTAssertLessThan(onPhone, 262_144, "…but an 8 GB phone can't hold 256K of KV for a 4.5 GB model")
        // A Mac with room holds strictly more than the phone does.
        let mac = DeviceTier(physicalMemoryBytes: 64_000_000_000, isPhone: false)
        let onMac = ContextPolicy.largestFitting(model: m, variant: m.variants[0], device: mac)
        XCTAssertGreaterThan(onMac, onPhone)
        XCTAssertTrue(ContextPolicy.fits(model: m, variant: m.variants[0], device: mac, context: onMac))
    }

    /// `.tight(maxContext:)` is `isSupported == true` even when the requested context is far past
    /// `maxContext` — "the weights fit", not "this context fits". Reading it as the latter is what makes a
    /// 256K rung look fine on a phone, so `fits` must consult `maxContext`.
    func testFitsIsNotTheSameQuestionAsIsSupported() {
        let m = model(native: 262_144)
        let phone = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)
        let plan = LLMMemoryGovernor.plan(model: m, variant: m.variants[0], device: phone, context: 262_144)
        XCTAssertTrue(plan.isSupported, "the governor says the weights fit…")
        XCTAssertFalse(ContextPolicy.fits(model: m, variant: m.variants[0], device: phone, context: 262_144),
                       "…but 256K of KV does not, and that's the question the ladder asks")
    }
}
