// SPDX-License-Identifier: MIT

import Foundation

// The extensible model catalog schema (DESIGN §3). The download + UI layer is family-agnostic; the
// governor's memory model is qwen-shaped ("qwen-family v1"). Adding a Qwen3/Llama/Mistral model later
// = append an `LLMModel` with the right `modelType` / `swiftModelClass`, no schema change.

/// Publisher/architecture family. Extensible; adding a family = one case + a display name.
public enum LLMFamily: String, Sendable, Hashable, CaseIterable, Codable {
    case bonsai
    case qwen
    case minicpm
    case hunyuan
    case deepseek
    case gemma
    case apple
    public var displayName: String {
        switch self {
        case .bonsai: "Bonsai"
        case .qwen: "Qwen"
        case .minicpm: "MiniCPM"
        case .hunyuan: "Hunyuan"
        case .deepseek: "DeepSeek"
        case .gemma: "Gemma"
        case .apple: "Apple"
        }
    }
}

/// The license a model ships under (kept local so LLMCore is self-contained).
public enum ModelLicense: String, Sendable, Hashable, Codable {
    case apache2 = "Apache-2.0"
    case mit = "MIT"
    case tencentHunyuan = "Tencent Hunyuan Community"
    case gemma = "Gemma Terms of Use"
    /// Not an open-source licence: the system model is part of the OS and is covered by its terms.
    /// There is no repo, no weights file, and nothing for the user to accept here.
    case appleSystem = "Included with Apple Intelligence"
    public var displayName: String { rawValue }
}

/// Where a variant's weights come from (a Hugging Face repo at a pinned revision). Local to LLMCore.
public struct ModelSource: Sendable, Hashable, Codable {
    public let huggingFaceRepo: String
    public let revision: String
    /// The single weight file to fetch from a multi-file repo (e.g. one `*.gguf`); `nil` = the whole
    /// flat repo (the MLX case). Threaded through the downloader as a one-entry glob.
    public let fileName: String?
    public init(huggingFaceRepo: String, revision: String = "main", fileName: String? = nil) {
        self.huggingFaceRepo = huggingFaceRepo
        self.revision = revision
        self.fileName = fileName
    }
}

/// Which inference engine runs a variant's weights (DESIGN §1 / §6). Three engines sit behind the one
/// `LLMEngine` protocol: the resident-weights MLX engine, a llama.cpp engine (mmap'd GGUF) for large
/// models on memory-tight phones, and Apple's system model (FoundationModels) — which owns no weights
/// of ours at all.
public enum EngineKind: String, Sendable, Codable, CaseIterable, Hashable {
    case mlx
    case llamaCpp
    case apple

    /// Human-facing name for the picker + subtitles.
    public var label: String {
        switch self {
        case .mlx: "MLX"
        case .llamaCpp: "llama.cpp"
        case .apple: "Apple Intelligence"
        }
    }
}

/// Whether the OS's own system model (the `.apple` engine) can be used right now, and if not, why.
///
/// This is the app's framework-free vocabulary for `FoundationModels.SystemLanguageModel.availability`:
/// that type is `@available(iOS 26, macOS 26)`, so nothing below those OSes — including this package and
/// its tests — can even name it. The engine package maps the framework enum onto these cases; everything
/// else (the install probe, the Models card) reads only this.
public enum SystemModelStatus: Sendable, Equatable {
    case available
    case unavailable(Reason)

    /// Why the system model can't be used. Mirrors the framework's `UnavailableReason`, plus the two
    /// cases the framework can't express: an OS that predates it, and a reason a future OS adds.
    public enum Reason: Sendable, Equatable {
        /// This OS ships no system model (below iOS 26 / macOS 26), or the app was built without the SDK.
        case unsupportedOS
        /// The hardware isn't eligible for Apple Intelligence.
        case deviceNotEligible
        /// Apple Intelligence is switched off in Settings.
        case notEnabled
        /// Eligible and switched on, but the model is still downloading.
        case modelNotReady
        /// The framework reported a reason this build doesn't know about.
        case unknown

        /// User-facing text for the Models card. Each names the real reason and, where the user can
        /// actually do something, the action — never a bare enum dump, and never a fake "download".
        public var message: String {
            switch self {
            case .unsupportedOS:
                return "Apple Intelligence needs a newer version of this operating system."
            case .deviceNotEligible:
                return "This device isn't eligible for Apple Intelligence, so its built-in model can't run here."
            case .notEnabled:
                return "Apple Intelligence is turned off. Switch it on in Settings to use the built-in model."
            case .modelNotReady:
                return "Apple Intelligence is still downloading its model. It'll be ready shortly."
            case .unknown:
                return "Apple Intelligence isn't available on this device right now."
            }
        }
    }

    public var isAvailable: Bool { self == .available }

    /// The reason it's unusable, or `nil` when it's ready.
    public var unavailableReason: Reason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// The user's inference-engine preference (Settings → Inference engine). `auto` lets the Auto-policy
/// pick the greenest-fitting variant; the explicit cases pin an engine when the model ships one.
public enum EnginePreference: String, Sendable, Codable, CaseIterable, Hashable {
    case auto
    case mlx
    case llamaCpp

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .mlx: EngineKind.mlx.label
        case .llamaCpp: EngineKind.llamaCpp.label
        }
    }

    /// The engine this preference pins to, or `nil` for `.auto`.
    public var pinnedEngine: EngineKind? {
        switch self {
        case .auto: nil
        case .mlx: .mlx
        case .llamaCpp: .llamaCpp
        }
    }
}

/// Quantization scheme. 1-bit (Binary) needs the PrismML fork kernel; ternary 2-bit is upstream-native
/// MLX; `gguf4bit` is llama.cpp's Q4_K_M (the standard on-device GGUF quant, ~4.5 bpw).
public enum QuantSpec: Sendable, Hashable, Codable {
    case binary1bit    // {bits:1}, group_size 128 — PrismML fork
    case ternary2bit   // {bits:2}, group_size 128 — upstream stock
    case gguf4bit      // Q4_K_M — llama.cpp
    case other(String) // an arbitrary community quant label (Explore) — MLX "4-bit"/"8-bit", GGUF "Q5_K_M"…

    public var bits: Int {
        switch self {
        case .binary1bit: return 1
        case .ternary2bit: return 2
        case .gguf4bit: return 4
        case .other(let s):
            if let m = s.range(of: #"\d+"#, options: .regularExpression), let n = Int(s[m]) { return n }
            return 4
        }
    }
    public var groupSize: Int { 128 }
    public var displayName: String {
        switch self {
        case .binary1bit: "1-bit"
        case .ternary2bit: "Ternary (2-bit)"
        case .gguf4bit: "Q4_K_M"
        case .other(let s): s
        }
    }
}

/// Which inference backend a variant needs.
public enum Backend: Sendable, Hashable, Codable {
    case mlxFork          // 1-bit, PrismML fork kernel (bits=1 is not in upstream MLX)
    case mlxStock         // ternary 2-bit, upstream `bits ∈ {2,…}`
    case llamaCppGGUF     // GGUF weights on the (planned) llama.cpp engine — mmap'd, memory-tight phones
    case awqUnsupported   // AWQ-gemm + fp16 vision tower — excluded
    /// The OS's own model, reached through FoundationModels. There are no weights to fetch, load or
    /// budget for: the system owns them, out of process. A variant on this backend is `onDiskBytes: 0`,
    /// is never downloaded or deleted, and is "installed" exactly when the OS says the model is available.
    case appleSystem

    /// Which inference engine this backend runs on. AWQ is treated as an MLX target (it's excluded, but
    /// architecturally it belongs to the MLX side, never llama.cpp).
    public var engine: EngineKind {
        switch self {
        case .mlxFork, .mlxStock, .awqUnsupported: .mlx
        case .llamaCppGGUF: .llamaCpp
        case .appleSystem: .apple
        }
    }

    /// The non-weight working set the runtime holds (framework + reuse pool + scratch), added to the
    /// on-disk weight bytes to estimate the resident floor. **Estimates**: MLX keeps ~0.5 GB of
    /// anonymous/dirty working set resident; llama.cpp mmaps the GGUF and keeps a slimmer ~0.35 GB of
    /// non-weight scratch (the bulk of its weight pages are clean/file-backed — the governor discounts
    /// those separately). Per-engine so the honest fit differs between the two.
    ///
    /// The system model costs us ZERO: inference happens in the OS's own process, so none of its weights
    /// or scratch land in our footprint. This is why the governor hands `.apple` a `.comfortable` plan
    /// instead of doing weight math (`LLMMemoryGovernor.plan`).
    public var runtimeOverheadBytes: Int64 {
        switch engine {
        case .mlx: 500_000_000
        case .llamaCpp: 350_000_000
        case .apple: 0
        }
    }

    /// A short, stable tag for the on-disk weight format, used to keep `LLMVariant.id` unique across
    /// engines so one model can hold both an MLX and a GGUF variant.
    public var formatTag: String {
        switch self {
        case .mlxFork, .mlxStock: "mlx"
        case .llamaCppGGUF: "gguf"
        case .awqUnsupported: "awq"
        case .appleSystem: "apple"
        }
    }
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

    /// True for the hybrid Gated-DeltaNet shape (qwen3_5). Only this arch is unconfirmed on mainline
    /// llama.cpp, so its GGUF variant is held experimental (never green) by the governor / UX.
    public var isHybrid: Bool {
        if case .hybridLinear = self { return true }
        return false
    }
}

/// An input the model can natively take. NOTE: the app currently runs every model **text-only** — we load
/// just the language weights and skip the vision/audio projector — so this describes the CHECKPOINT's own
/// capability, which the UI surfaces so you know what a model could do once we wire those inputs.
public enum Modality: String, Sendable, Hashable, Codable, CaseIterable {
    case text, vision, audio, video

    public var label: String {
        switch self {
        case .text: "Text"; case .vision: "Vision"; case .audio: "Audio"; case .video: "Video"
        }
    }
    public var icon: String {
        switch self {
        case .text: "text.alignleft"; case .vision: "eye"; case .audio: "waveform"; case .video: "video"
        }
    }
}

/// How the runtime obtains the chat template. Every seed repo ships a `chat_template.jinja` (ChatML/Qwen).
public enum ChatTemplateSource: Sendable, Hashable, Codable {
    case repoFile(String)   // a template file bundled in the weights repo (e.g. "chat_template.jinja")
    case builtin(String)    // a named template compiled into the app
}

/// The wire format the **llama.cpp engine** serializes chat turns into (the MLX engine uses the repo's
/// jinja template via `chatTemplate`; the llama.cpp path builds the string by hand for full control).
/// Extensible: add a case + a builder in `LlamaEngine.buildPrompt` to onboard a new template family.
public enum PromptTemplate: String, Sendable, Hashable, Codable {
    case chatML     // <|im_start|>role\n…<|im_end|>  — Qwen3/3.5/3.6, MiniCPM5, Bonsai
    case deepSeek   // <｜begin▁of▁sentence｜>{sys}<｜User｜>…<｜Assistant｜>  — DeepSeek(-R1 distills)
    case hunyuan    // <｜hy_begin▁of▁sentence｜>{sys}<｜hy_User｜>…<｜hy_Assistant｜>  — Tencent Hunyuan
    case gemma      // <|turn>role\n…<turn|>\n  — Google Gemma 4 (asymmetric open/close markers)
    /// Use the template EMBEDDED IN THE GGUF (llama.cpp applies it). The only way an arbitrary community
    /// checkpoint from Explore can be prompted correctly — we can't hand-write a builder per model.
    case auto
}

/// How a model delimits its reasoning, so the engine can build the prompt + split the stream correctly.
public enum ReasoningStyle: String, Sendable, Hashable, Codable {
    /// No reasoning trace — the whole stream is the answer.
    case none
    /// Explicit `<think>…</think>` the model emits itself (Qwen-family). Thinking-off is enforced by
    /// pre-filling an empty `<think></think>` block in the prompt.
    case thinkTags
    /// The chat template pre-fills the OPENING `<think>` in the prompt, so the model streams reasoning
    /// first and emits only the closing `</think>` (DeepSeek-R1 distills). The splitter starts in-think.
    case thinkTagsImplicitOpen

    /// Whether the model can produce a reasoning trace at all (drives the composer's 🧠 toggle).
    public var canThink: Bool { self != .none }
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
    /// The wire format + reasoning convention for the llama.cpp engine (defaults suit the ChatML/Qwen
    /// seed models; a non-Qwen GGUF sets these to onboard cleanly without touching the engine).
    public let promptTemplate: PromptTemplate
    public let reasoningStyle: ReasoningStyle
    /// What the checkpoint natively accepts. We run text-only today, so anything beyond `.text` is shown
    /// as a capability of the model, not of the app (yet).
    public let modalities: [Modality]

    /// Native inputs beyond text (empty for a pure text model) — what the UI badges.
    public var extraModalities: [Modality] { modalities.filter { $0 != .text } }

    /// The hybrid Gated-DeltaNet arch (qwen3_5) — unconfirmed on mainline llama.cpp (held experimental).
    public var isHybrid: Bool { attention.isHybrid }

    public init(modelType: String, swiftModelClass: String, hidden: Int, layers: Int, vocab: Int,
                tieWordEmbeddings: Bool, attention: AttentionShape, nativeContext: Int,
                thinkingCapable: Bool, eos: String, chatTemplate: ChatTemplateSource,
                promptTemplate: PromptTemplate = .chatML,
                reasoningStyle: ReasoningStyle = .thinkTags,
                modalities: [Modality] = [.text]) {
        self.modalities = modalities
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
        self.promptTemplate = promptTemplate
        self.reasoningStyle = reasoningStyle
    }
}

/// A vision projector (mmproj) companion file for a llama.cpp vision model: the multimodal-projector
/// weights that turn an image into embedding tokens the text model consumes (loaded via mtmd). It ships
/// as a second GGUF beside the text weights in the SAME repo; `sizeBytes` is the HF-verified file size,
/// fed to the governor's weight math and the storage/download accounting.
public struct VisionProjector: Sendable, Hashable, Codable {
    /// The repo-relative file name (e.g. `mmproj-F16.gguf`).
    public let fileName: String
    /// The projector file's true size in bytes (HF tree API `lfs.size`).
    public let sizeBytes: Int64
    public init(fileName: String, sizeBytes: Int64) {
        self.fileName = fileName
        self.sizeBytes = sizeBytes
    }
}

/// One installable variant of a model (a specific quant + backend + weights repo).
public struct LLMVariant: Sendable, Hashable, Codable, Identifiable {
    public let quant: QuantSpec
    public let backend: Backend
    public let onDiskBytes: Int64
    public let source: ModelSource
    /// The vision projector (mmproj) this variant pairs with, when it can accept image input; `nil` for a
    /// text-only variant. Present only on llama.cpp GGUF vision variants (the mmproj lives in `source`'s
    /// repo). Optional + decode-defaulted so persisted snapshots / adopted registries written before this
    /// field survive a decode unchanged.
    public let visionProjector: VisionProjector?

    /// Unique per variant across models AND engines: the repo plus the backend's format tag, so one
    /// model can hold both an MLX and a GGUF variant of the same quant without an id collision.
    public var id: String { "\(source.huggingFaceRepo)#\(backend.formatTag)" }

    /// The inference engine this variant runs on (routing key + UI subtitle).
    public var engine: EngineKind { backend.engine }

    /// True when this variant ships a vision projector — i.e. it can accept image input (drives the
    /// composer's attach-image affordance and the engine's mtmd path).
    public var supportsVisionInput: Bool { visionProjector != nil }

    /// True when the OS provides this variant's weights (the `.apple` engine): there is nothing to
    /// download, delete, size or budget for. The Models card renders it without any download affordance,
    /// and its "installed" state comes from `SystemModelStatus`, never from a disk probe.
    public var isSystemProvided: Bool { backend == .appleSystem }

    /// The repo-relative files this variant must download to be usable, in fetch order: the primary
    /// single weight file (when it pulls one file from a shared repo — e.g. a GGUF) plus its vision
    /// projector when present. Empty = fetch the whole flat repo (the MLX case). Pure and the single
    /// source of truth for the download globs, the "installed?" probe (ALL of these must be present),
    /// deletion, and storage accounting.
    public var requiredFileNames: [String] {
        var names: [String] = []
        if let f = source.fileName { names.append(f) }
        if let p = visionProjector { names.append(p.fileName) }
        return names
    }

    public init(quant: QuantSpec, backend: Backend, onDiskBytes: Int64, source: ModelSource,
                visionProjector: VisionProjector? = nil) {
        self.quant = quant
        self.backend = backend
        self.onDiskBytes = onDiskBytes
        self.source = source
        self.visionProjector = visionProjector
    }

    // Hand-written Codable so a snapshot written before `visionProjector` existed decodes with it nil,
    // and a text-only variant re-encodes without the key (byte-identical to the old form).
    private enum CodingKeys: String, CodingKey { case quant, backend, onDiskBytes, source, visionProjector }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quant = try c.decode(QuantSpec.self, forKey: .quant)
        backend = try c.decode(Backend.self, forKey: .backend)
        onDiskBytes = try c.decode(Int64.self, forKey: .onDiskBytes)
        source = try c.decode(ModelSource.self, forKey: .source)
        visionProjector = try c.decodeIfPresent(VisionProjector.self, forKey: .visionProjector)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quant, forKey: .quant)
        try c.encode(backend, forKey: .backend)
        try c.encode(onDiskBytes, forKey: .onDiskBytes)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(visionProjector, forKey: .visionProjector)
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

    /// The variant for a given quant, if this model ships it. When both engines ship the same quant
    /// (e.g. 1-bit as MLX + GGUF) this returns the first listed — MLX stays first, so the default and
    /// every existing quant-keyed lookup keep resolving to the MLX variant (behavior preserved).
    public func variant(for quant: QuantSpec) -> LLMVariant? {
        variants.first { $0.quant == quant }
    }

    /// The default variant (falls back to the first if the default quant is somehow absent).
    public var defaultVariantValue: LLMVariant {
        variant(for: defaultVariant) ?? variants[0]
    }

    /// True when every variant is OS-provided (the Apple system model) — nothing to fetch or delete.
    public var isSystemProvided: Bool { variants.allSatisfy { $0.isSystemProvided } }

    /// The engines this model ships a variant for, in a stable order (MLX first, then llama.cpp).
    public var engines: [EngineKind] {
        var seen: [EngineKind] = []
        for v in variants where !seen.contains(v.engine) { seen.append(v.engine) }
        return seen
    }

    /// The variants that run on a given engine, in catalog order.
    public func variants(for engine: EngineKind) -> [LLMVariant] {
        variants.filter { $0.engine == engine }
    }

    /// The variant for a specific engine + quant, if this model ships it.
    public func variant(engine: EngineKind, quant: QuantSpec) -> LLMVariant? {
        variants.first { $0.engine == engine && $0.quant == quant }
    }
}
