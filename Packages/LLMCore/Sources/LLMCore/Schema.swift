// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// The extensible model catalog schema (DESIGN §3). The download + UI layer is family-agnostic; the
// governor's memory model is qwen-shaped ("qwen-family v1"). Adding a Qwen3/Llama/Mistral model later
// = append an `LLMModel` with the right `modelType` / `swiftModelClass`, no schema change.

/// Publisher/architecture family. Extensible; the seed catalog starts with one family.
public enum LLMFamily: String, Sendable, Hashable, CaseIterable, Codable {
    case bonsai
    public var displayName: String {
        switch self { case .bonsai: "Bonsai" }
    }
}

/// The permissive license the seed models ship under (kept local — LLMCore does not import DiffusionCore).
public enum ModelLicense: String, Sendable, Hashable, Codable {
    case apache2 = "Apache-2.0"
    public var displayName: String { rawValue }
}

/// Where a variant's weights come from (a Hugging Face repo at a pinned revision). Local to LLMCore.
public struct ModelSource: Sendable, Hashable, Codable {
    public let huggingFaceRepo: String
    public let revision: String
    public init(huggingFaceRepo: String, revision: String = "main") {
        self.huggingFaceRepo = huggingFaceRepo
        self.revision = revision
    }
}

/// Quantization scheme. 1-bit (Binary) needs the PrismML fork kernel; ternary 2-bit is upstream-native.
public enum QuantSpec: Sendable, Hashable, Codable {
    case binary1bit    // {bits:1}, group_size 128 — PrismML fork
    case ternary2bit   // {bits:2}, group_size 128 — upstream stock

    public var bits: Int { self == .binary1bit ? 1 : 2 }
    public var groupSize: Int { 128 }
    public var displayName: String { self == .binary1bit ? "1-bit" : "Ternary (2-bit)" }
}

/// Which inference backend a variant needs.
public enum Backend: Sendable, Hashable, Codable {
    case mlxFork          // 1-bit, PrismML fork kernel (bits=1 is not in upstream MLX)
    case mlxStock         // ternary 2-bit, upstream `bits ∈ {2,…}`
    case awqUnsupported   // AWQ-gemm + fp16 vision tower — excluded

    /// The ~0.5 GB non-weight working set an MLX runtime holds (framework + reuse pool + scratch).
    /// Added to the on-disk weight bytes to estimate the resident floor.
    public var runtimeOverheadBytes: Int64 { 500_000_000 }
}

/// The KV-cache shape — the only memory lever, since weights are always resident (DESIGN §1/§2.5).
public enum AttentionShape: Sendable, Hashable, Codable {
    /// Dense attention (qwen3): every layer grows a KV cache.
    case fullAttention(kvHeads: Int, headDim: Int, layers: Int)
    /// Hybrid Gated-DeltaNet (qwen3_5): only `fullLayers` grow a KV cache; the `recurrent` linear
    /// layers hold fixed `MambaCache` state (≈ no growth with context).
    case hybridLinear(fullLayers: Int, kvHeads: Int, headDim: Int, recurrent: Int)

    /// KV-cache bytes at `tokens` of context. Counts K and V (×2), each `bytesPerElement` wide
    /// (fp16 → 2), across only the attention layers that actually grow a cache.
    public func kvBytes(tokens: Int, bytesPerElement: Int = 2) -> Int64 {
        switch self {
        case let .fullAttention(kvHeads, headDim, layers):
            return Self.cache(layers: layers, kvHeads: kvHeads, headDim: headDim,
                              tokens: tokens, bytesPerElement: bytesPerElement)
        case let .hybridLinear(fullLayers, kvHeads, headDim, _):
            return Self.cache(layers: fullLayers, kvHeads: kvHeads, headDim: headDim,
                              tokens: tokens, bytesPerElement: bytesPerElement)
        }
    }

    private static func cache(layers: Int, kvHeads: Int, headDim: Int, tokens: Int, bytesPerElement: Int) -> Int64 {
        // per layer: K and V, each kvHeads · headDim · tokens elements.
        Int64(layers) * Int64(kvHeads) * Int64(headDim) * Int64(tokens) * Int64(bytesPerElement) * 2
    }
}

/// How the runtime obtains the chat template. Every seed repo ships a `chat_template.jinja` (ChatML/Qwen).
public enum ChatTemplateSource: Sendable, Hashable, Codable {
    case repoFile(String)   // a template file bundled in the weights repo (e.g. "chat_template.jinja")
    case builtin(String)    // a named template compiled into the app
}

/// The architecture facts the factory + governor need (keys into `LLMModelFactory`, KV shape, etc).
public struct LLMArchitecture: Sendable, Hashable, Codable {
    public let modelType: String        // config.json `model_type`, e.g. "qwen3_5_text" | "qwen3"
    public let swiftModelClass: String  // the mlx-swift-lm model class, e.g. "Qwen35Model" | "Qwen3Model"
    public let hidden: Int
    public let layers: Int
    public let vocab: Int
    public let tieWordEmbeddings: Bool
    public let attention: AttentionShape
    public let nativeContext: Int
    public let thinkingCapable: Bool
    public let eos: String              // e.g. "<|im_end|>"
    public let chatTemplate: ChatTemplateSource

    public init(modelType: String, swiftModelClass: String, hidden: Int, layers: Int, vocab: Int,
                tieWordEmbeddings: Bool, attention: AttentionShape, nativeContext: Int,
                thinkingCapable: Bool, eos: String, chatTemplate: ChatTemplateSource) {
        self.modelType = modelType
        self.swiftModelClass = swiftModelClass
        self.hidden = hidden
        self.layers = layers
        self.vocab = vocab
        self.tieWordEmbeddings = tieWordEmbeddings
        self.attention = attention
        self.nativeContext = nativeContext
        self.thinkingCapable = thinkingCapable
        self.eos = eos
        self.chatTemplate = chatTemplate
    }
}

/// One installable variant of a model (a specific quant + backend + weights repo).
public struct LLMVariant: Sendable, Hashable, Codable, Identifiable {
    public let quant: QuantSpec
    public let backend: Backend
    public let onDiskBytes: Int64
    public let source: ModelSource

    /// Unique per variant (each variant is a distinct HF repo).
    public var id: String { source.huggingFaceRepo }

    public init(quant: QuantSpec, backend: Backend, onDiskBytes: Int64, source: ModelSource) {
        self.quant = quant
        self.backend = backend
        self.onDiskBytes = onDiskBytes
        self.source = source
    }
}

/// A model in the catalog: display metadata + architecture + its installable variants.
public struct LLMModel: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let family: LLMFamily
    public let publisher: String
    public let summary: String
    public let license: ModelLicense
    public let architecture: LLMArchitecture
    public let variants: [LLMVariant]
    /// The quant selected by default for this model.
    public let defaultVariant: QuantSpec

    public init(id: String, displayName: String, family: LLMFamily, publisher: String, summary: String,
                license: ModelLicense, architecture: LLMArchitecture, variants: [LLMVariant],
                defaultVariant: QuantSpec) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.publisher = publisher
        self.summary = summary
        self.license = license
        self.architecture = architecture
        self.variants = variants
        self.defaultVariant = defaultVariant
    }

    /// The variant for a given quant, if this model ships it.
    public func variant(for quant: QuantSpec) -> LLMVariant? {
        variants.first { $0.quant == quant }
    }

    /// The default variant (falls back to the first if the default quant is somehow absent).
    public var defaultVariantValue: LLMVariant {
        variant(for: defaultVariant) ?? variants[0]
    }
}
