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
        ],
        defaultVariant: .binary1bit)

    /// All catalog models, in device-recommended order (largest first).
    public static let all: [LLMModel] = [bonsai27b, bonsai8b, bonsai4b, bonsai1_7b]

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
