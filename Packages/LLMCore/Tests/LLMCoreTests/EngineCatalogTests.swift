// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The engine additions to the schema + catalog (DESIGN §3 / §6): Bonsai models ship MLX variants plus a
/// llama.cpp GGUF (Q1_0), while the newer families (Qwen3.5/3.6, MiniCPM5, Hunyuan, DeepSeek) are
/// GGUF-only (Q4_K_M). Ids stay unique across engines; Bonsai's MLX-first default is unchanged.
final class EngineCatalogTests: XCTestCase {

    private let bonsaiIDs: Set<String> = ["bonsai-27b", "bonsai-8b", "bonsai-4b", "bonsai-1.7b"]

    /// Backend → engine mapping (AWQ maps to MLX; GGUF to llama.cpp; the system model to Apple).
    func testBackendEngineMapping() {
        XCTAssertEqual(Backend.mlxFork.engine, .mlx)
        XCTAssertEqual(Backend.mlxStock.engine, .mlx)
        XCTAssertEqual(Backend.awqUnsupported.engine, .mlx)
        XCTAssertEqual(Backend.llamaCppGGUF.engine, .llamaCpp)
        XCTAssertEqual(Backend.appleSystem.engine, .apple)
        // The OS runs the system model out of process: none of it lands in our footprint.
        XCTAssertEqual(Backend.appleSystem.runtimeOverheadBytes, 0)
        XCTAssertEqual(Backend.appleSystem.formatTag, "apple")
    }

    func testEngineLabels() {
        XCTAssertEqual(EngineKind.mlx.label, "MLX")
        XCTAssertEqual(EngineKind.llamaCpp.label, "llama.cpp")
        XCTAssertEqual(EngineKind.apple.label, "Apple Intelligence")
    }

    /// Every DOWNLOADABLE model ships at least one GGUF variant, each with a real single-file `.gguf`
    /// name + size. The OS-provided system model is exempt by construction: it has no weights to fetch,
    /// so it can't have a GGUF (or any) file — `testAppleSystemModelShipsNoWeights` pins that instead.
    func testEveryModelHasAGGUFVariant() {
        for model in LLMCatalog.all where !model.isSystemProvided {
            let ggufs = model.variants(for: .llamaCpp)
            XCTAssertGreaterThanOrEqual(ggufs.count, 1, "\(model.id) must ship a GGUF variant")
            for v in ggufs {
                XCTAssertEqual(v.backend, .llamaCppGGUF)
                XCTAssertTrue(v.source.fileName?.hasSuffix(".gguf") ?? false,
                              "\(model.id) GGUF needs a single .gguf filename")
                XCTAssertGreaterThan(v.onDiskBytes, 0)
            }
        }
        // Bonsai ships the 1-bit Q1_0 quant; the new families ship Q4_K_M.
        XCTAssertEqual(LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)?.source.fileName,
                       "Bonsai-8B-Q1_0.gguf")
        XCTAssertEqual(LLMCatalog.qwen35_4b.variant(engine: .llamaCpp, quant: .gguf4bit)?.source.fileName,
                       "Qwen3.5-4B-Q4_K_M.gguf")
    }

    /// The Bonsai models keep their MLX-first ordering + MLX default; the new families are GGUF-only.
    func testBonsaiMLXPreservedAndNewFamiliesGGUFOnly() {
        for model in LLMCatalog.all where bonsaiIDs.contains(model.id) {
            XCTAssertEqual(model.variants.first?.engine, .mlx, "MLX must stay first for \(model.id)")
            XCTAssertEqual(model.variant(for: model.defaultVariant)?.engine, .mlx)
            XCTAssertEqual(model.defaultVariantValue.engine, .mlx)
        }
        XCTAssertEqual(LLMCatalog.bonsai8b.engines, [.mlx, .llamaCpp])
        // GGUF-only newcomers default to their llama.cpp variant. The system model is neither Bonsai nor
        // GGUF — it downloads nothing — so it's excluded here and pinned on its own below.
        for model in LLMCatalog.all where !bonsaiIDs.contains(model.id) && !model.isSystemProvided {
            XCTAssertEqual(model.engines, [.llamaCpp], "\(model.id) is GGUF-only")
            XCTAssertEqual(model.defaultVariantValue.engine, .llamaCpp)
        }
    }

    /// The Apple system model is in the catalog like any other model, but ships NO weights: zero bytes,
    /// no files to fetch, and no memory cost. This is what lets the Models card offer it with no download
    /// and the governor skip weight math entirely.
    func testAppleSystemModelShipsNoWeights() {
        let model = LLMCatalog.appleSystem
        XCTAssertTrue(LLMCatalog.all.contains { $0.id == model.id }, "it must appear in the catalog")
        XCTAssertTrue(model.isSystemProvided)
        XCTAssertEqual(model.engines, [.apple])
        let variant = model.defaultVariantValue
        XCTAssertEqual(variant.backend, .appleSystem)
        XCTAssertEqual(variant.onDiskBytes, 0)
        XCTAssertTrue(variant.requiredFileNames.isEmpty, "there is no file to download")
        XCTAssertNil(variant.source.fileName)
        XCTAssertFalse(variant.supportsVisionInput)
        XCTAssertTrue(variant.id.hasSuffix("#apple"))
        // No fabricated architecture: Apple publishes none, so the KV shape must cost nothing.
        XCTAssertEqual(model.architecture.attention.kvBytes(tokens: 4096), 0)
        XCTAssertFalse(model.architecture.thinkingCapable)
        XCTAssertEqual(model.architecture.reasoningStyle, .none)
    }

    /// Variant ids are unique across the whole catalog even though MLX + GGUF share the 1-bit quant.
    func testVariantIdsUniqueAcrossEngines() {
        let ids = LLMCatalog.all.flatMap { $0.variants.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count, "variant ids must be unique across engines")
        let mlx1 = LLMCatalog.bonsai8b.variant(engine: .mlx, quant: .binary1bit)!
        let gguf1 = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        XCTAssertNotEqual(mlx1.id, gguf1.id)
        XCTAssertTrue(mlx1.id.hasSuffix("#mlx"))
        XCTAssertTrue(gguf1.id.hasSuffix("#gguf"))
    }

    /// `variant(engine:quant:)` selects the right one; `variants(for:)` filters by engine.
    func testEngineScopedLookup() {
        let m = LLMCatalog.bonsai8b
        XCTAssertEqual(m.variants(for: .mlx).map(\.quant), [.binary1bit, .ternary2bit])
        XCTAssertEqual(m.variants(for: .llamaCpp).map(\.quant), [.binary1bit])
        XCTAssertEqual(m.variant(engine: .llamaCpp, quant: .binary1bit)?.source.fileName, "Bonsai-8B-Q1_0.gguf")
        XCTAssertNil(m.variant(engine: .llamaCpp, quant: .ternary2bit))
    }

    /// The qwen3_5 models are the hybrid Gated-DeltaNet arch; plain qwen3 / llama / hunyuan dense are not.
    func testHybridFlag() {
        for m in [LLMCatalog.bonsai27b, LLMCatalog.qwen35_4b, LLMCatalog.qwen35_9b, LLMCatalog.qwen36_27b] {
            XCTAssertTrue(m.architecture.isHybrid, "\(m.id) is qwen3_5 hybrid")
        }
        for m in [LLMCatalog.bonsai8b, LLMCatalog.bonsai4b, LLMCatalog.bonsai1_7b,
                  LLMCatalog.hunyuan4b, LLMCatalog.deepseekR1Qwen8b] {
            XCTAssertFalse(m.architecture.isHybrid, "\(m.id) is dense")
        }
    }

    /// The new models carry the right prompt/reasoning wiring for the llama.cpp engine.
    func testNewFamilyPromptWiring() {
        XCTAssertEqual(LLMCatalog.qwen35_4b.architecture.promptTemplate, .chatML)
        XCTAssertEqual(LLMCatalog.qwen35_4b.architecture.reasoningStyle, .thinkTagsImplicitOpen)
        XCTAssertEqual(LLMCatalog.deepseekR1Qwen8b.architecture.promptTemplate, .deepSeek)
        XCTAssertEqual(LLMCatalog.deepseekR1Qwen8b.architecture.reasoningStyle, .thinkTags)
        XCTAssertEqual(LLMCatalog.hunyuan4b.architecture.promptTemplate, .hunyuan)
        XCTAssertEqual(LLMCatalog.qwen36_27b.architecture.reasoningStyle, .thinkTagsImplicitOpen)
    }
}
