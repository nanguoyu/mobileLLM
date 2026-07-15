// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// The built-in "qwen-family v1" catalog: Prism ML's Bonsai models. Every size/layer/vocab figure is
/// from a Hugging Face primary source (config.json / safetensors index), per DESIGN §1.1 / §3.
///
/// Architecture notes:
///   • Only the 27B is `qwen3_5_text` (Gated-DeltaNet hybrid → `Qwen35Model` + `MambaCache`). Its 16
///     full-attention layers are the only ones that grow a KV cache (~64 KB/token); the 48 linear
///     layers hold fixed state → near-constant memory as context grows.
///   • 8B / 4B / 1.7B are plain dense `qwen3` (`Qwen3Model`, upstream) — architecturally simpler
///     (~144 KB/token for the 8B).
public enum LLMCatalog {

    // MARK: - Bonsai-27B (qwen3_5, hybrid GDN)

    public static let bonsai27b = LLMModel(
        id: "bonsai-27b",
        displayName: "Bonsai 27B",
        family: .bonsai,
        publisher: "Prism ML",
        summary: "Hybrid Gated-DeltaNet 27B. Near-constant memory as context grows — 16 full-attention "
               + "layers grow the KV cache, 48 linear layers hold fixed state.",
        license: .apache2,
        architecture: LLMArchitecture(
            modelType: "qwen3_5_text",
            swiftModelClass: "Qwen35Model",
            hidden: 5120,
            layers: 64,                 // 48 linear + 16 full
            vocab: 248_320,
            tieWordEmbeddings: false,
            attention: .hybridLinear(fullLayers: 16, kvHeads: 4, headDim: 256, recurrent: 48),
            nativeContext: 262_144,
            thinkingCapable: true,
            eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja")),
        variants: [
            LLMVariant(quant: .binary1bit, backend: .mlxFork, onDiskBytes: 5_129_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Bonsai-27B-mlx-1bit")),
            LLMVariant(quant: .ternary2bit, backend: .mlxStock, onDiskBytes: 8_491_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Ternary-Bonsai-27B-mlx-2bit")),
            // llama.cpp GGUF (Q1_0, 3.8 GB — verified x-linked-size). The hybrid GDN arch is CONFIRMED on
            // mainline llama.cpp (kernel_gated_delta_net + kernel_mul_mv_q1_0 both run on Metal), so the
            // ARCH risk is gone; the governor/UX still hold this variant EXPERIMENTAL (amber, never green)
            // for MEMORY — 3.8 GB mmap + KV on an 8 GB phone is close to the jetsam ceiling — pending an
            // on-device footprint measurement. mmap'd weights make it far more feasible than the MLX 27B.
            LLMVariant(quant: .binary1bit, backend: .llamaCppGGUF, onDiskBytes: 3_803_452_480,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Bonsai-27B-gguf",
                                           fileName: "Bonsai-27B-Q1_0.gguf")),
        ],
        defaultVariant: .binary1bit)

    // MARK: - Bonsai-8B (qwen3 dense) — the iPhone hero

    public static let bonsai8b = LLMModel(
        id: "bonsai-8b",
        displayName: "Bonsai 8B",
        family: .bonsai,
        publisher: "Prism ML",
        summary: "Dense 8B — the on-device hero: green on every device, the safe iPhone default.",
        license: .apache2,
        architecture: LLMArchitecture(
            modelType: "qwen3",
            swiftModelClass: "Qwen3Model",
            hidden: 4096,
            layers: 36,
            vocab: 151_669,
            tieWordEmbeddings: false,
            attention: .fullAttention(kvHeads: 8, headDim: 128, layers: 36),
            nativeContext: 65_536,
            thinkingCapable: true,
            eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja")),
        variants: [
            LLMVariant(quant: .binary1bit, backend: .mlxFork, onDiskBytes: 1_280_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Bonsai-8B-mlx-1bit")),
            LLMVariant(quant: .ternary2bit, backend: .mlxStock, onDiskBytes: 2_304_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Ternary-Bonsai-8B-mlx-2bit")),
            // llama.cpp GGUF (Q1_0, ~1.16 GB). Dense qwen3 → confirmed to load+decode on mainline
            // llama.cpp; mmap'd weights keep this comfortably green on every device.
            LLMVariant(quant: .binary1bit, backend: .llamaCppGGUF, onDiskBytes: 1_160_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Bonsai-8B-gguf",
                                           fileName: "Bonsai-8B-Q1_0.gguf")),
        ],
        defaultVariant: .binary1bit)

    // MARK: - Bonsai-4B (qwen3 dense, tied embeddings)

    public static let bonsai4b = LLMModel(
        id: "bonsai-4b",
        displayName: "Bonsai 4B",
        family: .bonsai,
        publisher: "Prism ML",
        summary: "Dense 4B with tied word embeddings — small, fast, green everywhere.",
        license: .apache2,
        architecture: LLMArchitecture(
            modelType: "qwen3",
            swiftModelClass: "Qwen3Model",
            hidden: 2560,
            layers: 36,
            vocab: 151_669,
            tieWordEmbeddings: true,
            attention: .fullAttention(kvHeads: 8, headDim: 128, layers: 36),
            nativeContext: 32_768,
            thinkingCapable: true,
            eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja")),
        variants: [
            LLMVariant(quant: .binary1bit, backend: .mlxFork, onDiskBytes: 629_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Bonsai-4B-mlx-1bit")),
            LLMVariant(quant: .ternary2bit, backend: .mlxStock, onDiskBytes: 1_132_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Ternary-Bonsai-4B-mlx-2bit")),
            // llama.cpp GGUF (Q1_0). Dense qwen3; size is an approximation (~0.57 GB) pending a
            // published figure — GGUF Q1_0 tracks the MLX 1-bit size a little smaller.
            LLMVariant(quant: .binary1bit, backend: .llamaCppGGUF, onDiskBytes: 570_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Bonsai-4B-gguf",
                                           fileName: "Bonsai-4B-Q1_0.gguf")),
        ],
        defaultVariant: .binary1bit)

    // MARK: - Bonsai-1.7B (qwen3 dense, tied embeddings)

    public static let bonsai1_7b = LLMModel(
        id: "bonsai-1.7b",
        displayName: "Bonsai 1.7B",
        family: .bonsai,
        publisher: "Prism ML",
        summary: "Dense 1.7B with tied word embeddings — the lightest, snappiest option.",
        license: .apache2,
        architecture: LLMArchitecture(
            modelType: "qwen3",
            swiftModelClass: "Qwen3Model",
            hidden: 2048,
            layers: 28,
            vocab: 151_669,
            tieWordEmbeddings: true,
            attention: .fullAttention(kvHeads: 8, headDim: 128, layers: 28),
            nativeContext: 32_768,
            thinkingCapable: true,
            eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja")),
        variants: [
            LLMVariant(quant: .binary1bit, backend: .mlxFork, onDiskBytes: 269_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Bonsai-1.7B-mlx-1bit")),
            LLMVariant(quant: .ternary2bit, backend: .mlxStock, onDiskBytes: 484_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Ternary-Bonsai-1.7B-mlx-2bit")),
            // llama.cpp GGUF (Q1_0). Dense qwen3; size is an approximation (~0.24 GB) pending a
            // published figure.
            LLMVariant(quant: .binary1bit, backend: .llamaCppGGUF, onDiskBytes: 244_000_000,
                       source: ModelSource(huggingFaceRepo: "prism-ml/Bonsai-1.7B-gguf",
                                           fileName: "Bonsai-1.7B-Q1_0.gguf")),
        ],
        defaultVariant: .binary1bit)

    // MARK: - Qwen3.5 / Qwen3.6 (Alibaba, qwen3_5 hybrid GDN — same family as Bonsai-27B, confirmed on
    // mainline llama.cpp). GGUF-only (llama.cpp). Text backbone of a VL model — the text quant loads
    // standalone; the vision mmproj is ignored. ChatML; the template pre-fills the opening <think> tag
    // (implicit-open) so the stream begins inside the reasoning block. Facts verified from HF config.json,
    // chat_template.jinja, and the GGUF tree API (exact Q4_K_M byte sizes). head_dim is EXPLICIT (256),
    // not hidden/heads. 32-layer models: 8 full-attention + 24 linear (full_attention_interval 4).

    public static let qwen35_4b = LLMModel(
        id: "qwen3.5-4b",
        displayName: "Qwen3.5 4B",
        family: .qwen,
        publisher: "Alibaba (Qwen)",
        summary: "Newest small Qwen, strong Chinese + reasoning. Same hybrid arch as Bonsai — the "
               + "seamless iPhone upgrade. ChatML, thinking on by default.",
        license: .apache2,
        architecture: LLMArchitecture(
            modelType: "qwen3_5_text", swiftModelClass: "Qwen35Model",
            hidden: 2560, layers: 32, vocab: 248_320, tieWordEmbeddings: true,
            attention: .hybridLinear(fullLayers: 8, kvHeads: 4, headDim: 256, recurrent: 24),
            nativeContext: 262_144, thinkingCapable: true, eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja"),
            promptTemplate: .chatML, reasoningStyle: .thinkTagsImplicitOpen),
        variants: [
            LLMVariant(quant: .gguf4bit, backend: .llamaCppGGUF, onDiskBytes: 2_740_937_888,
                       source: ModelSource(huggingFaceRepo: "unsloth/Qwen3.5-4B-GGUF",
                                           fileName: "Qwen3.5-4B-Q4_K_M.gguf")),
        ],
        defaultVariant: .gguf4bit)

    public static let qwen35_9b = LLMModel(
        id: "qwen3.5-9b",
        displayName: "Qwen3.5 9B",
        family: .qwen,
        publisher: "Alibaba (Qwen)",
        summary: "The Mac-comfortable Qwen3.5: top-tier Chinese + reasoning, hybrid arch keeps KV small.",
        license: .apache2,
        architecture: LLMArchitecture(
            modelType: "qwen3_5_text", swiftModelClass: "Qwen35Model",
            hidden: 4096, layers: 32, vocab: 248_320, tieWordEmbeddings: false,
            attention: .hybridLinear(fullLayers: 8, kvHeads: 4, headDim: 256, recurrent: 24),
            nativeContext: 262_144, thinkingCapable: true, eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja"),
            promptTemplate: .chatML, reasoningStyle: .thinkTagsImplicitOpen),
        variants: [
            LLMVariant(quant: .gguf4bit, backend: .llamaCppGGUF, onDiskBytes: 5_680_522_464,
                       source: ModelSource(huggingFaceRepo: "unsloth/Qwen3.5-9B-GGUF",
                                           fileName: "Qwen3.5-9B-Q4_K_M.gguf")),
        ],
        defaultVariant: .gguf4bit)

    public static let qwen36_27b = LLMModel(
        id: "qwen3.6-27b",
        displayName: "Qwen3.6 27B",
        family: .qwen,
        publisher: "Alibaba (Qwen)",
        summary: "Newest open Qwen (2026). Flagship-class Chinese; a big-Mac model — 16 GB at Q4_K_M.",
        license: .apache2,
        architecture: LLMArchitecture(
            modelType: "qwen3_5_text", swiftModelClass: "Qwen35Model",
            hidden: 5120, layers: 64, vocab: 248_320, tieWordEmbeddings: false,
            // 64-layer qwen3_5 (like Bonsai-27B): 16 full-attention grow the KV, 48 linear hold state.
            attention: .hybridLinear(fullLayers: 16, kvHeads: 4, headDim: 256, recurrent: 48),
            nativeContext: 262_144, thinkingCapable: true, eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja"),
            promptTemplate: .chatML, reasoningStyle: .thinkTagsImplicitOpen),
        variants: [
            // Official ggml-org repo ships only Q8_0; Q4_K_M lives in the unsloth repo (verified size).
            LLMVariant(quant: .gguf4bit, backend: .llamaCppGGUF, onDiskBytes: 16_817_244_384,
                       source: ModelSource(huggingFaceRepo: "unsloth/Qwen3.6-27B-GGUF",
                                           fileName: "Qwen3.6-27B-Q4_K_M.gguf")),
        ],
        defaultVariant: .gguf4bit)

    // MARK: - MiniCPM5-1B (OpenBMB) — llama arch, ChatML, implicit-open <think>. Strong Chinese in 688 MB;
    // the "always fits" ultralight. head_dim is EXPLICIT (128, ≠ hidden/heads). eos <|im_end|> (id 130073).

    public static let minicpm5_1b = LLMModel(
        id: "minicpm5-1b",
        displayName: "MiniCPM5 1B",
        family: .minicpm,
        publisher: "OpenBMB",
        summary: "688 MB of strong on-device Chinese — the always-fits ultralight. ChatML.",
        license: .apache2,
        architecture: LLMArchitecture(
            modelType: "llama", swiftModelClass: "LlamaModel",
            hidden: 1536, layers: 24, vocab: 130_560, tieWordEmbeddings: false,
            attention: .fullAttention(kvHeads: 2, headDim: 128, layers: 24),
            nativeContext: 131_072, thinkingCapable: true, eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja"),
            promptTemplate: .chatML, reasoningStyle: .thinkTagsImplicitOpen),
        variants: [
            LLMVariant(quant: .gguf4bit, backend: .llamaCppGGUF, onDiskBytes: 688_065_920,
                       source: ModelSource(huggingFaceRepo: "openbmb/MiniCPM5-1B-GGUF",
                                           fileName: "MiniCPM5-1B-Q4_K_M.gguf")),
        ],
        defaultVariant: .gguf4bit)

    // MARK: - Hunyuan 4B Instruct (Tencent) — hunyuan_v1_dense. NOT ChatML: Tencent's own fullwidth-bar
    // format (<｜hy_User｜>/<｜hy_Assistant｜>). Explicit <think>. Strong Chinese, native iPhone size.

    public static let hunyuan4b = LLMModel(
        id: "hunyuan-4b",
        displayName: "Hunyuan 4B",
        family: .hunyuan,
        publisher: "Tencent",
        summary: "Tencent's small dense chat model — strong Chinese, native iPhone size. Own chat format.",
        license: .tencentHunyuan,
        architecture: LLMArchitecture(
            modelType: "hunyuan_v1_dense", swiftModelClass: "HunyuanModel",
            hidden: 3072, layers: 36, vocab: 120_818, tieWordEmbeddings: true,
            attention: .fullAttention(kvHeads: 8, headDim: 128, layers: 36),
            nativeContext: 262_144, thinkingCapable: true, eos: "<｜hy_place▁holder▁no▁2｜>",
            chatTemplate: .repoFile("chat_template.jinja"),
            promptTemplate: .hunyuan, reasoningStyle: .thinkTags),
        variants: [
            LLMVariant(quant: .gguf4bit, backend: .llamaCppGGUF, onDiskBytes: 2_607_709_664,
                       source: ModelSource(huggingFaceRepo: "gabriellarson/Hunyuan-4B-Instruct-GGUF",
                                           fileName: "Hunyuan-4B-Instruct-Q4_K_M.gguf")),
        ],
        defaultVariant: .gguf4bit)

    // MARK: - DeepSeek-R1-0528-Qwen3-8B (DeepSeek, MIT) — R1 reasoning distilled onto a Qwen3-8B dense
    // base. DeepSeek chat format (<｜User｜>/<｜Assistant｜>); the model emits its own <think> (explicit).
    // The strongest small reasoner; a Mac model.

    public static let deepseekR1Qwen8b = LLMModel(
        id: "deepseek-r1-qwen3-8b",
        displayName: "DeepSeek-R1 Qwen3 8B",
        family: .deepseek,
        publisher: "DeepSeek",
        summary: "R1 reasoning distilled onto Qwen3-8B — the strongest small reasoner. Mac model.",
        license: .mit,
        architecture: LLMArchitecture(
            modelType: "qwen3", swiftModelClass: "Qwen3Model",
            hidden: 4096, layers: 36, vocab: 151_936, tieWordEmbeddings: false,
            attention: .fullAttention(kvHeads: 8, headDim: 128, layers: 36),
            nativeContext: 131_072, thinkingCapable: true, eos: "<｜end▁of▁sentence｜>",
            chatTemplate: .repoFile("chat_template.jinja"),
            promptTemplate: .deepSeek, reasoningStyle: .thinkTags),
        variants: [
            LLMVariant(quant: .gguf4bit, backend: .llamaCppGGUF, onDiskBytes: 5_027_785_216,
                       source: ModelSource(huggingFaceRepo: "unsloth/DeepSeek-R1-0528-Qwen3-8B-GGUF",
                                           fileName: "DeepSeek-R1-0528-Qwen3-8B-Q4_K_M.gguf")),
        ],
        defaultVariant: .gguf4bit)

    /// All catalog models, in device-recommended order (largest first for Bonsai, then the new families).
    public static let all: [LLMModel] = [
        bonsai27b, bonsai8b, bonsai4b, bonsai1_7b,
        qwen35_4b, qwen35_9b, qwen36_27b, minicpm5_1b, hunyuan4b, deepseekR1Qwen8b,
    ]

    /// Look a model up by id.
    public static func model(id: String) -> LLMModel? {
        all.first { $0.id == id }
    }

    /// The device-recommended default (DESIGN §1.2 defaults): Mac → 27B; 12 GB iPhone → 27B; 8 GB
    /// iPhone → 8B (the safe green hero). The 27B remains selectable as Experimental on the 8 GB phone.
    public static func defaultModel(for tier: DeviceTier) -> LLMModel {
        guard tier.isPhone else { return bonsai27b }
        let gb = Double(tier.physicalMemoryBytes) / 1_000_000_000
        return gb >= 10 ? bonsai27b : bonsai8b
    }
}
