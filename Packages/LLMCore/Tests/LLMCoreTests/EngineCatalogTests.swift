// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The engine additions to the schema + catalog (DESIGN §3 / §6): every Bonsai model now ships one
/// llama.cpp GGUF variant alongside its MLX variants, ids stay unique across engines, and the MLX
/// variants remain first (so the quant-keyed default is unchanged).
final class EngineCatalogTests: XCTestCase {

    /// Backend → engine mapping (AWQ maps to MLX; GGUF to llama.cpp).
    func testBackendEngineMapping() {
        XCTAssertEqual(Backend.mlxFork.engine, .mlx)
        XCTAssertEqual(Backend.mlxStock.engine, .mlx)
        XCTAssertEqual(Backend.awqUnsupported.engine, .mlx)
        XCTAssertEqual(Backend.llamaCppGGUF.engine, .llamaCpp)
    }

    func testEngineLabels() {
        XCTAssertEqual(EngineKind.mlx.label, "MLX")
        XCTAssertEqual(EngineKind.llamaCpp.label, "llama.cpp")
    }

    /// Every model ships exactly one GGUF variant, with the expected repo + filename.
    func testEveryModelHasOneGGUFVariant() {
        let expected: [String: (repo: String, file: String)] = [
            "bonsai-27b":  ("prism-ml/Bonsai-27B-gguf",  "Bonsai-27B-Q1_0.gguf"),
            "bonsai-8b":   ("prism-ml/Bonsai-8B-gguf",   "Bonsai-8B-Q1_0.gguf"),
            "bonsai-4b":   ("prism-ml/Bonsai-4B-gguf",   "Bonsai-4B-Q1_0.gguf"),
            "bonsai-1.7b": ("prism-ml/Bonsai-1.7B-gguf", "Bonsai-1.7B-Q1_0.gguf"),
        ]
        for model in LLMCatalog.all {
            let ggufs = model.variants(for: .llamaCpp)
            XCTAssertEqual(ggufs.count, 1, "\(model.id) must ship exactly one GGUF variant")
            let v = ggufs[0]
            XCTAssertEqual(v.backend, .llamaCppGGUF)
            XCTAssertEqual(v.quant, .binary1bit, "GGUF Q1_0 is 1-bit")
            XCTAssertEqual(v.source.huggingFaceRepo, expected[model.id]?.repo)
            XCTAssertEqual(v.source.fileName, expected[model.id]?.file)
            XCTAssertGreaterThan(v.onDiskBytes, 0)
        }
    }

    /// The existing MLX variants are untouched — still first, still the quant-keyed default.
    func testMLXVariantsPreservedAndDefaultStable() {
        for model in LLMCatalog.all {
            XCTAssertEqual(model.variants.first?.engine, .mlx, "MLX variant must stay first")
            XCTAssertEqual(model.variant(for: model.defaultVariant)?.engine, .mlx,
                           "the quant-keyed default must still resolve to the MLX variant")
            XCTAssertEqual(model.defaultVariantValue.engine, .mlx)
        }
        // Both engines are present, MLX first.
        XCTAssertEqual(LLMCatalog.bonsai8b.engines, [.mlx, .llamaCpp])
    }

    /// Variant ids are unique across the whole catalog even though MLX + GGUF share the 1-bit quant.
    func testVariantIdsUniqueAcrossEngines() {
        let ids = LLMCatalog.all.flatMap { $0.variants.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count, "variant ids must be unique across engines")
        // The id encodes the format tag so a same-quant MLX vs GGUF pair never collides.
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

    /// Only the 27B is the hybrid arch (the experimental-on-llama flag).
    func testHybridFlag() {
        XCTAssertTrue(LLMCatalog.bonsai27b.architecture.isHybrid)
        for m in [LLMCatalog.bonsai8b, LLMCatalog.bonsai4b, LLMCatalog.bonsai1_7b] {
            XCTAssertFalse(m.architecture.isHybrid)
        }
    }
}
