// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore

final class CatalogTests: XCTestCase {

    /// KV-cache math (DESIGN §1.2): dense counts every layer; hybrid counts only its full-attn layers.
    func testAttentionKVBytes() {
        // 8B dense: 36 · 8 · 128 · tokens · 2(fp16) · 2(K+V).
        let dense = AttentionShape.fullAttention(kvHeads: 8, headDim: 128, layers: 36)
        XCTAssertEqual(dense.kvBytes(tokens: 1), 147_456)              // ≈ 144 KB/token
        XCTAssertEqual(dense.kvBytes(tokens: 1024), 147_456 * 1024)

        // 27B hybrid: only the 16 full layers grow the cache (the 48 linear layers don't).
        let hybrid = AttentionShape.hybridLinear(fullLayers: 16, kvHeads: 4, headDim: 256, recurrent: 48)
        XCTAssertEqual(hybrid.kvBytes(tokens: 1), 65_536)             // ≈ 64 KB/token
        XCTAssertEqual(hybrid.kvBytes(tokens: 1024), 65_536 * 1024)

        // The hybrid's per-token cost is well below the dense 8B's — the whole point of the GDN design.
        XCTAssertLessThan(hybrid.kvBytes(tokens: 4096), dense.kvBytes(tokens: 4096))
    }

    /// Every model id is unique, and so is every variant repo id.
    func testIdsUnique() {
        let ids = LLMCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "model ids must be unique")

        let repos = LLMCatalog.all.flatMap { $0.variants.map(\.source.huggingFaceRepo) }
        XCTAssertEqual(Set(repos).count, repos.count, "variant repo ids must be unique")
    }

    /// Each model's declared default quant actually maps to a shipped variant.
    func testDefaultVariantExists() {
        for model in LLMCatalog.all {
            XCTAssertNotNil(model.variant(for: model.defaultVariant),
                            "\(model.id) default \(model.defaultVariant) has no matching variant")
            XCTAssertEqual(model.defaultVariantValue.quant, model.defaultVariant)
        }
    }

    /// The seed on-disk sizes match the HF-verified figures (DESIGN §1.1 / §3).
    func testSeedSizes() {
        func bytes(_ id: String, _ quant: QuantSpec) -> Int64? {
            LLMCatalog.model(id: id)?.variant(for: quant)?.onDiskBytes
        }
        XCTAssertEqual(bytes("bonsai-27b", .binary1bit),  5_129_000_000)
        XCTAssertEqual(bytes("bonsai-27b", .ternary2bit), 8_491_000_000)
        XCTAssertEqual(bytes("bonsai-8b",  .binary1bit),  1_280_000_000)
        XCTAssertEqual(bytes("bonsai-8b",  .ternary2bit), 2_304_000_000)
        XCTAssertEqual(bytes("bonsai-4b",  .binary1bit),    629_000_000)
        XCTAssertEqual(bytes("bonsai-4b",  .ternary2bit), 1_132_000_000)
        XCTAssertEqual(bytes("bonsai-1.7b", .binary1bit),   269_000_000)
        XCTAssertEqual(bytes("bonsai-1.7b", .ternary2bit),  484_000_000)
    }

    /// Architecture keys: only the 27B is the qwen3_5 hybrid; the rest are dense qwen3.
    func testArchitectureKeys() {
        XCTAssertEqual(LLMCatalog.bonsai27b.architecture.modelType, "qwen3_5_text")
        XCTAssertEqual(LLMCatalog.bonsai27b.architecture.swiftModelClass, "Qwen35Model")
        for m in [LLMCatalog.bonsai8b, LLMCatalog.bonsai4b, LLMCatalog.bonsai1_7b] {
            XCTAssertEqual(m.architecture.modelType, "qwen3")
            XCTAssertEqual(m.architecture.swiftModelClass, "Qwen3Model")
        }
        // The 4B / 1.7B tie their word embeddings; the 27B / 8B do not.
        XCTAssertTrue(LLMCatalog.bonsai4b.architecture.tieWordEmbeddings)
        XCTAssertTrue(LLMCatalog.bonsai1_7b.architecture.tieWordEmbeddings)
        XCTAssertFalse(LLMCatalog.bonsai27b.architecture.tieWordEmbeddings)
        XCTAssertFalse(LLMCatalog.bonsai8b.architecture.tieWordEmbeddings)
    }

    /// Device defaults (DESIGN §1.2): Mac → 27B; 12 GB phone → 27B; 8 GB phone → 8B.
    func testDefaultModelForDevice() {
        XCTAssertEqual(LLMCatalog.defaultModel(for: DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)).id, "bonsai-27b")
        XCTAssertEqual(LLMCatalog.defaultModel(for: DeviceTier(physicalMemoryBytes: 12_000_000_000, isPhone: true)).id,  "bonsai-27b")
        XCTAssertEqual(LLMCatalog.defaultModel(for: DeviceTier(physicalMemoryBytes: 8_000_000_000,  isPhone: true)).id,  "bonsai-8b")
    }
}
