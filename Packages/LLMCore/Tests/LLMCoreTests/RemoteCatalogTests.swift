// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The Explore grouping heuristic (repo name → model identity + quant variants). Pure, so no network.
/// Inputs are real mlx-community repo leaf names.
final class RemoteCatalogTests: XCTestCase {

    private func repos(_ names: [String], dl: Int = 100) -> [(repo: String, dl: Int)] {
        names.map { (repo: "mlx-community/\($0)", dl: dl) }
    }

    func testSplitQuantPeelsTrailingDescriptors() {
        XCTAssertEqual(RemoteCatalog.splitQuant("Qwen3-8B-4bit").base, "Qwen3-8B")
        XCTAssertEqual(RemoteCatalog.splitQuant("Qwen3-8B-4bit").quant, "4-bit")
        XCTAssertEqual(RemoteCatalog.splitQuant("gpt-oss-20b-MXFP4-Q8").base, "gpt-oss-20b")
        XCTAssertEqual(RemoteCatalog.splitQuant("gemma-4-12B-it-OptiQ-4bit").base, "gemma-4-12B-it")
        XCTAssertEqual(RemoteCatalog.splitQuant("Llama-3.2-3B-Instruct-4bit").base, "Llama-3.2-3B-Instruct")
        XCTAssertEqual(RemoteCatalog.splitQuant("Qwen3-Embedding-0.6B-4bit-DWQ").base, "Qwen3-Embedding-0.6B")
        // No quant suffix → the whole leaf is the base.
        XCTAssertEqual(RemoteCatalog.splitQuant("Kimi-K2.5").base, "Kimi-K2.5")
        XCTAssertEqual(RemoteCatalog.splitQuant("Kimi-K2.5").quant, "default")
    }

    func testGroupsQuantsOfTheSameBase() {
        let g = RemoteCatalog.group(repos(["Qwen3-0.6B-8bit", "Qwen3-0.6B-4bit", "Qwen3-8B-4bit"]),
                                    publisher: "mlx-community", engine: .mlx)
        // Two distinct models; the 0.6B has two quants grouped.
        XCTAssertEqual(g.count, 2)
        let small = g.first { $0.name.contains("0.6B") }!
        XCTAssertEqual(small.variants.count, 2)
        // Sorted low-precision first → 4-bit before 8-bit.
        XCTAssertEqual(small.variants.map(\.quantLabel), ["4-bit", "8-bit"])
        XCTAssertEqual(small.engine, .mlx)
    }

    func testFiltersNonChatArtifacts() {
        let g = RemoteCatalog.group(repos(["Qwen3-Embedding-0.6B-4bit", "Qwen3-8B-4bit", "whisper-large-v3"]),
                                    publisher: "mlx-community", engine: .mlx)
        XCTAssertFalse(g.contains { $0.name.lowercased().contains("embedding") })
        XCTAssertFalse(g.contains { $0.name.lowercased().contains("whisper") })
        XCTAssertTrue(g.contains { $0.name.contains("Qwen3 8B") })
    }

    func testPreservesDownloadOrder() {
        let input = [("mlx-community/A-4bit", 500), ("mlx-community/B-4bit", 300), ("mlx-community/C-4bit", 100)]
            .map { (repo: $0.0, dl: $0.1) }
        let g = RemoteCatalog.group(input, publisher: "mlx-community", engine: .mlx)
        XCTAssertEqual(g.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(g.first?.downloads, 500)
    }

    func testPrettifyDropsInstructNoise() {
        XCTAssertEqual(RemoteCatalog.prettify("Llama-3.2-3B-Instruct"), "Llama 3.2 3B")
        XCTAssertEqual(RemoteCatalog.prettify("gemma-4-12B-it"), "gemma 4 12B")
    }

    func testQuantTokenRecognition() {
        for t in ["4bit", "8bit", "bf16", "mxfp4", "Q8", "q4_k_m", "DWQ", "OptiQ"] {
            XCTAssertTrue(RemoteCatalog.isQuantToken(t), "\(t) should be a quant token")
        }
        for t in ["Qwen3", "8B", "0.6B", "Instruct", "Coder"] {
            XCTAssertFalse(RemoteCatalog.isQuantToken(t), "\(t) should NOT be a quant token")
        }
    }

    func testParamCountParsesSizeFromName() {
        XCTAssertEqual(RemoteModel.paramCount(from: "Qwen3 9B"), 9)
        XCTAssertEqual(RemoteModel.paramCount(from: "Qwen3-0.6B"), 0.6)
        XCTAssertEqual(RemoteModel.paramCount(from: "gpt-oss 20b"), 20)
        XCTAssertEqual(RemoteModel.paramCount(from: "SmolLM 350M"), 0.35)   // M → billions
        XCTAssertEqual(RemoteModel.paramCount(from: "30B A3B"), 30)         // MoE → the larger (total) count
        XCTAssertNil(RemoteModel.paramCount(from: "Kimi K2.5"))             // no size token
    }

    // MARK: GGUF source (one repo = one model; quants are files)

    func testGGUFModelNameStripsSuffixAndOrgPrefix() {
        XCTAssertEqual(RemoteCatalog.ggufModelName("Qwen_Qwen3.5-9B-GGUF"), "Qwen3.5 9B")
        XCTAssertEqual(RemoteCatalog.ggufModelName("Llama-3.2-1B-Instruct-GGUF"), "Llama 3.2 1B")
        XCTAssertEqual(RemoteCatalog.ggufModelName("google_gemma-4-E2B-it-GGUF"), "gemma 4 E2B")
    }

    func testGGUFQuantLabelFromFilename() {
        XCTAssertEqual(RemoteCatalog.ggufQuantLabel("Llama-3.2-1B-Instruct-Q4_K_M.gguf"), "Q4_K_M")
        XCTAssertEqual(RemoteCatalog.ggufQuantLabel("x-IQ4_XS.gguf"), "IQ4_XS")
        XCTAssertEqual(RemoteCatalog.ggufQuantLabel("x-f16.gguf"), "F16")
        // Not quant files: the vision projector, a shard part, a non-gguf, a name with no quant tail.
        XCTAssertNil(RemoteCatalog.ggufQuantLabel("mmproj-F16.gguf"))
        XCTAssertNil(RemoteCatalog.ggufQuantLabel("model-00001-of-00002.gguf"))
        XCTAssertNil(RemoteCatalog.ggufQuantLabel("README.md"))
        XCTAssertNil(RemoteCatalog.ggufQuantLabel("model-instruct.gguf"))
    }

    func testParseGGUFTreeBuildsSortedVariants() {
        // Shape mirrors the live HF tree API (path + top-level size).
        let json = """
        [{"path":"a-Q8_0.gguf","size":900},{"path":"a-Q4_K_M.gguf","size":500},
         {"path":"mmproj-F16.gguf","size":100},{"path":"README.md","size":10}]
        """
        let vs = RemoteCatalog.parseGGUFTree(Data(json.utf8), repo: "org/a-GGUF")
        XCTAssertEqual(vs.map(\.quantLabel), ["Q4_K_M", "Q8_0"], "sorted low→high precision; mmproj skipped")
        XCTAssertEqual(vs.first?.fileName, "a-Q4_K_M.gguf")
        XCTAssertEqual(vs.first?.sizeBytes, 500)
        XCTAssertEqual(vs.first?.repo, "org/a-GGUF")
    }

    func testGGUFExploreModelUsesEmbeddedTemplate() {
        let remote = RemoteModel(id: "org/x-GGUF", name: "X 7B", publisher: "org", engine: .llamaCpp,
                                 downloads: 1, variants: [RemoteVariant(quantLabel: "Q4_K_M", repo: "org/x-GGUF",
                                                                        fileName: "x-Q4_K_M.gguf", sizeBytes: 4_000_000_000)])
        let model = remote.asLLMModel(paramsBillions: 7)
        XCTAssertEqual(model.architecture.promptTemplate, .auto,
                       "an arbitrary community GGUF must render with its own embedded template")
        XCTAssertEqual(model.variants.first?.backend, .llamaCppGGUF)
        XCTAssertEqual(model.variants.first?.source.fileName, "x-Q4_K_M.gguf")
    }

    func testEstimateBytesScalesWithParamsAndQuant() {
        // 9B at 4-bit ≈ 9e9 * 0.55 ≈ 5 GB; 8-bit is ~2x the 4-bit size.
        let q4 = RemoteModel.estimateBytes(paramsBillions: 9, quant: "4-bit")
        let q8 = RemoteModel.estimateBytes(paramsBillions: 9, quant: "8-bit")
        XCTAssertEqual(Double(q4) / 1e9, 4.95, accuracy: 0.6)
        XCTAssertGreaterThan(q8, q4)
        // Unknown param count falls back to a ~4B assumption (non-zero, bounded).
        let fallback = RemoteModel.estimateBytes(paramsBillions: nil, quant: "4-bit")
        XCTAssertGreaterThan(fallback, 1_000_000_000)
    }

    // MARK: Real architecture resolution (A2.5) — pure parsing, canned JSON, no network

    private var mlxFallback: LLMArchitecture { RemoteCatalog.genericArchitecture(engine: .mlx) }
    private var ggufFallback: LLMArchitecture { RemoteCatalog.genericArchitecture(engine: .llamaCpp) }

    /// The generic fallback is the fabricated 32K/`fullAttention(8,128,32)` shape the fix exists to avoid
    /// presenting as fact — pinned here so a regression toward inventing context is caught.
    func testGenericArchitectureIsTheHonestPlaceholder() {
        XCTAssertEqual(mlxFallback.nativeContext, 32_768)
        XCTAssertEqual(mlxFallback.modelType, "generic")
        XCTAssertEqual(mlxFallback.promptTemplate, .chatML)
        XCTAssertEqual(ggufFallback.promptTemplate, .auto)
    }

    /// A real MLX `config.json` (Qwen3 8B shape) parses into the true context + KV shape.
    func testParseMLXConfigReadsRealShape() throws {
        let json = """
        {"model_type":"qwen3","hidden_size":4096,"num_hidden_layers":36,"num_attention_heads":32,
         "num_key_value_heads":8,"head_dim":128,"vocab_size":151936,"max_position_embeddings":40960,
         "tie_word_embeddings":false,"eos_token_id":151645}
        """
        let arch = try XCTUnwrap(RemoteCatalog.parseMLXConfig(Data(json.utf8), fallback: mlxFallback))
        XCTAssertEqual(arch.nativeContext, 40960)   // NOT the fabricated 32768
        XCTAssertEqual(arch.modelType, "qwen3")
        XCTAssertEqual(arch.hidden, 4096)
        XCTAssertEqual(arch.layers, 36)
        XCTAssertEqual(arch.vocab, 151936)
        XCTAssertFalse(arch.tieWordEmbeddings)
        guard case let .fullAttention(kvHeads, headDim, layers) = arch.attention else {
            return XCTFail("expected fullAttention, got \(arch.attention)")
        }
        XCTAssertEqual(kvHeads, 8)
        XCTAssertEqual(headDim, 128)
        XCTAssertEqual(layers, 36)
    }

    /// When `head_dim` is absent it is derived from `hidden_size / num_attention_heads`, and
    /// `num_key_value_heads` defaults to `num_attention_heads` (no GQA).
    func testParseMLXConfigDerivesHeadDimAndKVHeads() throws {
        let json = """
        {"model_type":"llama","hidden_size":2048,"num_hidden_layers":16,"num_attention_heads":16,
         "vocab_size":32000,"max_position_embeddings":8192,"tie_word_embeddings":true}
        """
        let arch = try XCTUnwrap(RemoteCatalog.parseMLXConfig(Data(json.utf8), fallback: mlxFallback))
        XCTAssertEqual(arch.nativeContext, 8192)
        XCTAssertTrue(arch.tieWordEmbeddings)
        guard case let .fullAttention(kvHeads, headDim, _) = arch.attention else {
            return XCTFail("expected fullAttention")
        }
        XCTAssertEqual(headDim, 128)   // 2048 / 16
        XCTAssertEqual(kvHeads, 16)    // defaults to num_attention_heads
    }

    /// A VLM config nests the language model under `text_config` — we read that, not the top-level vision.
    func testParseMLXConfigReadsNestedTextConfig() throws {
        let json = """
        {"model_type":"qwen3_vl","text_config":{"model_type":"qwen3","hidden_size":3584,
         "num_hidden_layers":28,"num_attention_heads":28,"num_key_value_heads":4,"head_dim":128,
         "vocab_size":152064,"max_position_embeddings":128000,"tie_word_embeddings":false}}
        """
        let arch = try XCTUnwrap(RemoteCatalog.parseMLXConfig(Data(json.utf8), fallback: mlxFallback))
        XCTAssertEqual(arch.nativeContext, 128000)
        XCTAssertEqual(arch.modelType, "qwen3")
        guard case let .fullAttention(kvHeads, _, layers) = arch.attention else {
            return XCTFail("expected fullAttention")
        }
        XCTAssertEqual(kvHeads, 4)
        XCTAssertEqual(layers, 28)
    }

    /// Garbage / incomplete config → nil, so the caller keeps the honest fallback (never invents).
    func testParseMLXConfigRejectsIncomplete() {
        XCTAssertNil(RemoteCatalog.parseMLXConfig(Data("not json".utf8), fallback: mlxFallback))
        XCTAssertNil(RemoteCatalog.parseMLXConfig(Data(#"{"hidden_size":4096}"#.utf8), fallback: mlxFallback))
        // Present but non-positive context is not trustworthy either.
        let zeroCtx = #"{"hidden_size":4096,"num_hidden_layers":1,"num_attention_heads":8,"max_position_embeddings":0}"#
        XCTAssertNil(RemoteCatalog.parseMLXConfig(Data(zeroCtx.utf8), fallback: mlxFallback))
    }

    /// GGUF metadata gives the true context_length (+ arch/eos); the KV shape stays the fallback.
    func testParseGGUFMetadataReadsContext() throws {
        let json = #"{"gguf":{"architecture":"qwen3","context_length":131072,"eos_token":"<|end|>"}}"#
        let arch = try XCTUnwrap(RemoteCatalog.parseGGUFMetadata(Data(json.utf8), fallback: ggufFallback))
        XCTAssertEqual(arch.nativeContext, 131072)   // NOT the fabricated 32768
        XCTAssertEqual(arch.modelType, "qwen3")
        XCTAssertEqual(arch.eos, "<|end|>")
        XCTAssertEqual(arch.promptTemplate, .auto)   // preserved from the GGUF fallback
    }

    func testParseGGUFMetadataRejectsMissingContext() {
        XCTAssertNil(RemoteCatalog.parseGGUFMetadata(Data(#"{"gguf":{}}"#.utf8), fallback: ggufFallback))
        XCTAssertNil(RemoteCatalog.parseGGUFMetadata(Data(#"{}"#.utf8), fallback: ggufFallback))
    }

    /// The `asLLMModel(paramsBillions:architecture:)` overload honors the supplied (real) architecture
    /// instead of the fabricated defaults, while preserving the variant / backend wiring.
    func testAsLLMModelConsumesResolvedArchitecture() {
        let remote = RemoteModel(id: "mlx-community/Tiny-4bit", name: "Tiny", publisher: "mlx-community",
                                 engine: .mlx, downloads: 1,
                                 variants: [RemoteVariant(quantLabel: "4-bit", repo: "mlx-community/Tiny-4bit",
                                                          fileName: nil, sizeBytes: 1_000_000_000)])
        let real = LLMArchitecture(
            modelType: "qwen3", swiftModelClass: "", hidden: 1024, layers: 8, vocab: 32000,
            tieWordEmbeddings: true, attention: .fullAttention(kvHeads: 2, headDim: 64, layers: 8),
            nativeContext: 4096, thinkingCapable: true, eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja"), promptTemplate: .chatML, reasoningStyle: .thinkTags)
        let model = remote.asLLMModel(paramsBillions: 1, architecture: real)
        XCTAssertEqual(model.architecture.nativeContext, 4096, "the clamp must see the real 4K ceiling, not 32K")
        XCTAssertEqual(model.architecture.modelType, "qwen3")
        XCTAssertEqual(model.variants.first?.backend, .mlxStock)
        XCTAssertEqual(model.variants.first?.source.huggingFaceRepo, "mlx-community/Tiny-4bit")
        // The generic default path still yields the fabricated 32K (documents the contrast the fix fixes).
        XCTAssertEqual(remote.asLLMModel(paramsBillions: 1).architecture.nativeContext, 32_768)
    }

    /// The honest-unknown wrapper: the fallback is marked unresolved so the UI won't present it as fact.
    func testResolvedArchitectureMarksUnknown() {
        let unresolved = ResolvedArchitecture(architecture: mlxFallback, isResolved: false)
        XCTAssertFalse(unresolved.isResolved)
        XCTAssertEqual(unresolved.architecture.nativeContext, 32_768)
    }
}
