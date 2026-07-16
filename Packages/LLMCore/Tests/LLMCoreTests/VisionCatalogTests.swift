// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore

/// Catalog vision consistency (C1.2) + the governor's projector weight math (C1.4). Pure — no model,
/// no network. The mmproj file names + byte sizes were verified against the HF tree API (`lfs.size`) for
/// the exact repos referenced in `Catalog.swift`.
final class VisionCatalogTests: XCTestCase {

    // MARK: - Catalog consistency

    /// Every projector-bearing variant is a llama.cpp GGUF whose model declares the vision modality, with a
    /// non-empty file name and a positive size. (One-directional: a vision-modality model need NOT ship a
    /// projector — Qwen3.6-27B is intentionally left text-only despite its vision checkpoint.)
    func testEveryProjectorVariantIsLlamaCppVisionWithSaneFields() {
        var found = 0
        for model in LLMCatalog.all {
            for variant in model.variants {
                guard let projector = variant.visionProjector else { continue }
                found += 1
                XCTAssertEqual(variant.engine, .llamaCpp, "\(model.id): a projector only makes sense on llama.cpp")
                XCTAssertTrue(model.architecture.modalities.contains(.vision),
                              "\(model.id): a projector requires the vision modality")
                XCTAssertFalse(projector.fileName.isEmpty, "\(model.id): projector needs a file name")
                XCTAssertTrue(projector.fileName.hasSuffix(".gguf"), "\(model.id): mmproj is a GGUF")
                XCTAssertGreaterThan(projector.sizeBytes, 0, "\(model.id): projector size must be > 0")
                XCTAssertTrue(variant.supportsVisionInput)
            }
        }
        XCTAssertEqual(found, 5, "exactly five catalog variants ship a vision projector")
    }

    /// The five verified (model → mmproj fileName, HF `lfs.size`) attachments, pinned exactly.
    func testVerifiedProjectorFilesAndSizes() {
        func projector(_ model: LLMModel) -> VisionProjector? {
            model.variant(engine: .llamaCpp, quant: .gguf4bit)?.visionProjector
        }
        XCTAssertEqual(projector(LLMCatalog.qwen35_4b), VisionProjector(fileName: "mmproj-F16.gguf", sizeBytes: 672_423_616))
        XCTAssertEqual(projector(LLMCatalog.qwen35_9b), VisionProjector(fileName: "mmproj-F16.gguf", sizeBytes: 918_166_080))
        XCTAssertEqual(projector(LLMCatalog.gemma4E2B), VisionProjector(fileName: "mmproj-F16.gguf", sizeBytes: 985_654_080))
        XCTAssertEqual(projector(LLMCatalog.gemma4E4B), VisionProjector(fileName: "mmproj-F16.gguf", sizeBytes: 990_372_672))
        XCTAssertEqual(projector(LLMCatalog.gemma4_12B),
                       VisionProjector(fileName: "mmproj-gemma-4-12B-it-Q8_0.gguf", sizeBytes: 158_987_584))
    }

    /// Text-only families ship no projector; the deliberately-excluded Qwen3.6-27B has none either.
    func testTextOnlyModelsHaveNoProjector() {
        for model in [LLMCatalog.hunyuan4b, LLMCatalog.deepseekR1Qwen8b, LLMCatalog.qwen36_27b,
                      LLMCatalog.bonsai8b, LLMCatalog.bonsai27b] {
            for variant in model.variants {
                XCTAssertNil(variant.visionProjector, "\(model.id) must not ship a projector")
                XCTAssertFalse(variant.supportsVisionInput)
            }
        }
    }

    /// A vision variant's download selection is exactly [weights, mmproj].
    func testVisionVariantRequiresBothFiles() {
        let v = LLMCatalog.qwen35_4b.variant(engine: .llamaCpp, quant: .gguf4bit)!
        XCTAssertEqual(v.requiredFileNames, ["Qwen3.5-4B-Q4_K_M.gguf", "mmproj-F16.gguf"])
    }

    // MARK: - Governor projector math

    private let phone8 = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)

    private func model(onDisk: Int64, projector: Int64?) -> LLMModel {
        let variant = LLMVariant(
            quant: .gguf4bit, backend: .llamaCppGGUF, onDiskBytes: onDisk,
            source: ModelSource(huggingFaceRepo: "org/vision", fileName: "m.gguf"),
            visionProjector: projector.map { VisionProjector(fileName: "mmproj.gguf", sizeBytes: $0) })
        return LLMModel(
            id: "syn", displayName: "Syn", family: .qwen, publisher: "T", summary: "",
            license: .apache2,
            architecture: LLMArchitecture(
                modelType: "qwen3", swiftModelClass: "Qwen3Model", hidden: 2048, layers: 24, vocab: 1000,
                tieWordEmbeddings: true, attention: .fullAttention(kvHeads: 2, headDim: 64, layers: 24),
                nativeContext: 32_768, thinkingCapable: false, eos: "<|im_end|>",
                chatTemplate: .builtin("x"), modalities: [.text, .vision]),
            variants: [variant], defaultVariant: .gguf4bit)
    }

    private func plan(_ m: LLMModel, context: Int = 256) -> LLMFit {
        LLMMemoryGovernor.plan(model: m, variant: m.variants[0], device: phone8, context: context)
    }

    /// The projector bytes count toward the weight footprint: the same weights read comfortable text-only
    /// but honest `.tight` once a ~0.7 GB projector is added (the raw footprint crosses the green line).
    func testProjectorBytesTightenTheFit() {
        // 3.0 GB weights + 0.35 GB overhead = 3.35 GB raw ≤ green(0.70·5.3 = 3.71 GB) → comfortable.
        XCTAssertEqual(plan(model(onDisk: 3_000_000_000, projector: nil)), .comfortable)
        // + 0.7 GB projector → 4.05 GB raw > green, but discounted (3.7·0.6 + 0.35 = 2.57 GB) ≤ 5.3 GB → tight.
        guard case .tight = plan(model(onDisk: 3_000_000_000, projector: 700_000_000)) else {
            return XCTFail("the projector's bytes should tip an otherwise-green weight set to tight")
        }
    }

    /// A large enough projector can make a variant unsupported where the weights alone fit — proof the
    /// projector is included in the discounted (clean-page) footprint, not ignored.
    func testLargeProjectorCanExceedCeiling() {
        // 5 GB weights alone: discounted 3.0 + 0.35 = 3.35 GB ≤ 5.3 GB → supported.
        XCTAssertNotEqual(plan(model(onDisk: 5_000_000_000, projector: nil)), .unsupported)
        // + 4 GB projector: discounted 9.0·0.6 + 0.35 = 5.75 GB > 5.3 GB ceiling → unsupported.
        XCTAssertEqual(plan(model(onDisk: 5_000_000_000, projector: 4_000_000_000)), .unsupported)
    }

    /// Regression: a projector-less GGUF plans EXACTLY as it did before the projector term (the `?? 0`
    /// path), demonstrated on the shipped Bonsai-8B GGUF staying comfortable on the 8 GB phone.
    func testNoProjectorLeavesLlamaCppMathUnchanged() {
        let v = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        XCTAssertNil(v.visionProjector)
        XCTAssertEqual(LLMMemoryGovernor.plan(model: LLMCatalog.bonsai8b, variant: v, device: phone8, context: 4096),
                       .comfortable)
    }
}
