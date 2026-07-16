// SPDX-License-Identifier: MIT

import Foundation

/// A model discovered live on the Hugging Face Hub (the **Explore** tier). Unlike the curated `LLMModel`
/// catalog, these carry no hand-verified adapter — they load generically from the model's own chat
/// template, so the UI flags them "Unverified" until tried. One `RemoteModel` groups every quant of the
/// same base checkpoint into a variant list, so the card shows a precision picker like a curated model.
public struct RemoteModel: Sendable, Identifiable, Hashable {
    public let id: String            // synthetic identity: "<publisher>/<baseName>"
    public let name: String          // display name, e.g. "Qwen3.5 9B"
    public let publisher: String     // HF org, e.g. "mlx-community"
    public let engine: EngineKind    // .mlx (mlx-community) or .llamaCpp (GGUF orgs)
    public let downloads: Int         // popularity (max across the group's repos)
    public let variants: [RemoteVariant]

    public init(id: String, name: String, publisher: String, engine: EngineKind,
                downloads: Int, variants: [RemoteVariant]) {
        self.id = id; self.name = name; self.publisher = publisher
        self.engine = engine; self.downloads = downloads; self.variants = variants
    }
}

/// One precision of a `RemoteModel`. For MLX each quant is its own repo; for GGUF a quant is a file
/// inside a shared repo (`fileName` set).
public struct RemoteVariant: Sendable, Hashable {
    public let quantLabel: String    // "4-bit", "8-bit", "Q4_K_M"
    public let repo: String          // HF repo id to download
    public let fileName: String?     // GGUF single file, or nil for a flat MLX repo
    public let sizeBytes: Int64?     // known on-disk size, or nil until fetched

    public init(quantLabel: String, repo: String, fileName: String? = nil, sizeBytes: Int64? = nil) {
        self.quantLabel = quantLabel; self.repo = repo; self.fileName = fileName; self.sizeBytes = sizeBytes
    }
}

/// The outcome of resolving a discovered model's real architecture (A2.5). `isResolved` is false when the
/// `config.json` / GGUF-metadata fetch or parse failed and we fell back to the generic defaults — so the
/// UI can badge the context as unverified rather than presenting an INVENTED 32K ceiling as fact.
public struct ResolvedArchitecture: Sendable, Hashable {
    public let architecture: LLMArchitecture
    public let isResolved: Bool
    public init(architecture: LLMArchitecture, isResolved: Bool) {
        self.architecture = architecture
        self.isResolved = isResolved
    }
}

extension RemoteModel {
    /// Convert a discovered model into a catalog `LLMModel` so it flows through the same download / fit /
    /// activate pipeline as the curated models. The architecture is GENERIC — a placeholder KV shape + 32K
    /// context — so the fit badge uses the estimated size and MLX loads the checkpoint from its own config
    /// + jinja template (no hand adapter), which is exactly why Explore models are flagged unverified.
    ///
    /// The generic 32K/`fullAttention(8,128,32)` guess DEFEATS the ContextPolicy clamp for the very models
    /// it protects (a community checkpoint can be 4K- or 256K-native). Prefer the
    /// `asLLMModel(paramsBillions:architecture:)` overload fed a `RemoteCatalog.realArchitecture(for:)`
    /// result, which carries the model's own context/KV shape.
    public func asLLMModel(paramsBillions: Double?) -> LLMModel {
        asLLMModel(paramsBillions: paramsBillions, architecture: RemoteCatalog.genericArchitecture(engine: engine))
    }

    /// As `asLLMModel(paramsBillions:)`, but with an explicit architecture — e.g. the corrected one from
    /// `RemoteCatalog.realArchitecture(for:)`, whose real `nativeContext` + KV shape the fit estimate and
    /// the context clamp then honor instead of the fabricated defaults.
    public func asLLMModel(paramsBillions: Double?, architecture: LLMArchitecture) -> LLMModel {
        let backend: Backend = engine == .mlx ? .mlxStock : .llamaCppGGUF
        let vs = variants.map { v in
            LLMVariant(quant: .other(v.quantLabel), backend: backend,
                       onDiskBytes: v.sizeBytes ?? RemoteModel.estimateBytes(paramsBillions: paramsBillions, quant: v.quantLabel),
                       source: ModelSource(huggingFaceRepo: v.repo, fileName: v.fileName))
        }
        return LLMModel(id: id, displayName: name, family: .qwen, publisher: publisher,
                        summary: "Community model — loaded from its own template. Not hand-verified.",
                        license: .apache2, architecture: architecture, variants: vs,
                        defaultVariant: vs.first?.quant ?? .gguf4bit)
    }

    /// Parse the parameter count from a model name, in billions (largest number followed by B/M).
    /// "Qwen3 9B" → 9, "Qwen3 0.6B" → 0.6, "gpt-oss 20b" → 20, "30B A3B" (MoE) → 30 (total, for size).
    public static func paramCount(from name: String) -> Double? {
        var best: Double?
        let scanner = name.replacingOccurrences(of: "-", with: " ")
        for token in scanner.split(separator: " ") {
            let t = token.lowercased()
            if t.range(of: #"^\d+(\.\d+)?[bm]$"#, options: .regularExpression) != nil {
                let num = Double(t[t.startIndex..<t.index(before: t.endIndex)]) ?? 0
                let b = t.hasSuffix("m") ? num / 1000 : num
                if best == nil || b > best! { best = b }
            }
        }
        return best
    }

    /// Rough on-disk bytes from param count × bytes-per-weight for the quant (fallback when HF size unknown).
    static func estimateBytes(paramsBillions: Double?, quant: String) -> Int64 {
        let b = paramsBillions ?? 4      // assume ~4B when the name has no size
        let l = quant.lowercased()
        let bpw: Double
        if l.contains("1-bit") || l.contains("q1") { bpw = 0.16 }
        else if l.contains("2-bit") || l.contains("q2") || l.contains("mxfp4") { bpw = 0.30 }
        else if l.contains("3-bit") || l.contains("q3") { bpw = 0.42 }
        else if l.contains("4-bit") || l.contains("q4") || l.contains("nf4") || l.contains("int4") { bpw = 0.55 }
        else if l.contains("5-bit") || l.contains("q5") { bpw = 0.68 }
        else if l.contains("6-bit") || l.contains("q6") { bpw = 0.82 }
        else if l.contains("8-bit") || l.contains("q8") || l.contains("int8") { bpw = 1.06 }
        else if l.contains("bf16") || l.contains("fp16") || l.contains("16-bit") { bpw = 2.0 }
        else { bpw = 0.6 }
        return Int64(b * 1_000_000_000 * bpw)
    }
}

/// Live Hugging Face Hub browser for the Explore tier. Networking + parsing only — no MLX, so it stays
/// in the unit-testable LLMCore. The grouping heuristic (repo name → model identity + quant) is pure and
/// covered by tests; the fetch is a thin URLSession wrapper around the public Hub API.
public enum RemoteCatalog {

    /// The MLX checkpoint source (the org FlowDown browses too). Hundreds of pre-quantized models.
    public static let mlxOrg = "mlx-community"
    /// GGUF publishers, most prolific first. Unlike MLX (one repo per quant), a GGUF repo holds MANY
    /// quant FILES, so a repo == a model and its quants are fetched lazily (`quants(for:)`).
    public static let ggufOrgs = ["bartowski", "unsloth", "ggml-org", "lmstudio-community"]

    /// Which checkpoint world to browse.
    public enum Source: String, Sendable, CaseIterable, Hashable {
        case mlx, gguf
        public var label: String { self == .mlx ? "MLX" : "GGUF" }
        public var engine: EngineKind { self == .mlx ? .mlx : .llamaCpp }
    }

    public enum CatalogError: Error, Sendable { case badResponse }

    /// Trending models for a source, most-downloaded first.
    public static func trending(source: Source = .mlx, limit: Int = 80,
                                session: URLSession = .shared) async throws -> [RemoteModel] {
        try await list(source: source, query: nil, limit: limit, session: session)
    }

    /// Search a source by free text (HF full-text search scoped to the orgs).
    public static func search(_ query: String, source: Source = .mlx, limit: Int = 60,
                              session: URLSession = .shared) async throws -> [RemoteModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return try await list(source: source, query: q.isEmpty ? nil : q, limit: limit, session: session)
    }

    private static func list(source: Source, query: String?, limit: Int,
                             session: URLSession) async throws -> [RemoteModel] {
        let enc = query?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        switch source {
        case .mlx:
            var url = "https://huggingface.co/api/models?author=\(mlxOrg)&pipeline_tag=text-generation"
                    + "&sort=downloads&direction=-1&limit=\(min(limit * 3, 300))&full=false"
            if let enc { url += "&search=\(enc)" }
            return group(try await fetch(url, session: session), publisher: mlxOrg, engine: .mlx)
                .prefix(limit).map { $0 }
        case .gguf:
            // One repo == one model; quants are files inside it, fetched on demand.
            var models: [RemoteModel] = []
            for org in ggufOrgs {
                var url = "https://huggingface.co/api/models?author=\(org)&search=\(enc.map { "\($0)%20GGUF" } ?? "GGUF")"
                        + "&sort=downloads&direction=-1&limit=\(max(8, limit / 2))&full=false"
                if enc == nil { url += "&pipeline_tag=text-generation" }
                guard let raw = try? await fetch(url, session: session) else { continue }
                for (repo, dl) in raw {
                    let leaf = repo.split(separator: "/").last.map(String.init) ?? repo
                    guard leaf.lowercased().contains("gguf"), isChatModel(leaf) else { continue }
                    models.append(RemoteModel(id: repo, name: ggufModelName(leaf), publisher: org,
                                              engine: .llamaCpp, downloads: dl, variants: []))
                }
            }
            return models.sorted { $0.downloads > $1.downloads }.prefix(limit).map { $0 }
        }
    }

    /// The quant files inside a GGUF repo → variants (with real byte sizes). Called when a row is opened,
    /// since listing files for every repo up front would be hundreds of requests.
    public static func quants(for model: RemoteModel, session: URLSession = .shared) async throws -> [RemoteVariant] {
        guard model.engine == .llamaCpp else { return model.variants }
        guard let url = URL(string: "https://huggingface.co/api/models/\(model.id)/tree/main?recursive=true") else {
            throw CatalogError.badResponse
        }
        var req = URLRequest(url: url); req.setValue("mobileLLM", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogError.badResponse }
        return parseGGUFTree(data, repo: model.id)
    }

    /// Pure: turn an HF file tree into GGUF quant variants (skipping mmproj + sharded parts).
    static func parseGGUFTree(_ data: Data, repo: String) -> [RemoteVariant] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [RemoteVariant] = []
        for item in items {
            guard let path = item["path"] as? String, let quant = ggufQuantLabel(path) else { continue }
            let size = (item["size"] as? Int64) ?? (item["lfs"] as? [String: Any])?["size"] as? Int64
            out.append(RemoteVariant(quantLabel: quant, repo: repo, fileName: path, sizeBytes: size))
        }
        return out.sorted { quantRank($0.quantLabel) < quantRank($1.quantLabel) }
    }

    /// `bartowski/Qwen_Qwen3.5-9B-GGUF` → "Qwen3.5 9B" (drop the -GGUF suffix + the `Org_` prefix).
    static func ggufModelName(_ leaf: String) -> String {
        var s = leaf
        for suffix in ["-GGUF", "-gguf", "-Gguf"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        if let underscore = s.firstIndex(of: "_") { s = String(s[s.index(after: underscore)...]) }
        return prettify(s)
    }

    /// The quant label from a `.gguf` filename ("…-Q4_K_M.gguf" → "Q4_K_M"); nil for mmproj/shards/other.
    static func ggufQuantLabel(_ path: String) -> String? {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        guard file.lowercased().hasSuffix(".gguf"), !file.lowercased().contains("mmproj") else { return nil }
        let name = String(file.dropLast(5))
        if name.range(of: #"-\d{5}-of-\d{5}$"#, options: .regularExpression) != nil { return nil }  // shard part
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let tail = String(name[name.index(after: dash)...])
        let ok = tail.range(of: #"^(I?Q\d+(_\w+)*|f16|bf16|f32|MXFP4(_\w+)?)$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
        return ok ? tail.uppercased() : nil
    }

    // MARK: - Fetch

    private struct HubItem: Decodable { let id: String; let downloads: Int? }

    private static func fetch(_ url: String, session: URLSession) async throws -> [(repo: String, dl: Int)] {
        guard let u = URL(string: url) else { throw CatalogError.badResponse }
        var req = URLRequest(url: u); req.setValue("mobileLLM", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogError.badResponse }
        let items = try JSONDecoder().decode([HubItem].self, from: data)
        return items.map { (repo: $0.id, dl: $0.downloads ?? 0) }
    }

    private static func fetchData(_ url: URL, session: URLSession) async throws -> Data {
        var req = URLRequest(url: url); req.setValue("mobileLLM", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogError.badResponse }
        return data
    }

    // MARK: - Real architecture (A2.5) — fetch a discovered model's true context/KV shape

    /// The generic, UNVERIFIED architecture used for a discovered model before its real config is known: a
    /// placeholder KV shape + a 32K context. This is a guess; `realArchitecture(for:)` replaces it with the
    /// model's own `config.json` / GGUF metadata so the ContextPolicy clamp and fit badge are honest.
    static func genericArchitecture(engine: EngineKind) -> LLMArchitecture {
        LLMArchitecture(
            modelType: "generic", swiftModelClass: "", hidden: 0, layers: 0, vocab: 0,
            tieWordEmbeddings: false, attention: .fullAttention(kvHeads: 8, headDim: 128, layers: 32),
            nativeContext: 32_768, thinkingCapable: true, eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja"),
            // A GGUF from Explore renders with its OWN embedded template (`.auto`); MLX applies the repo's
            // jinja itself, so its prompt template is moot.
            promptTemplate: engine == .mlx ? .chatML : .auto,
            reasoningStyle: .thinkTags)
    }

    /// Fetch a discovered model's REAL architecture, replacing the fabricated generic defaults so the fit
    /// badge + ContextPolicy clamp stop inventing a 32K ceiling. MLX: the repo's `config.json`. GGUF: the
    /// HF model API's `gguf` metadata block. On ANY failure it returns the generic fallback marked
    /// `isResolved: false` — an honest "unknown", never an invented context.
    public static func realArchitecture(for model: RemoteModel,
                                        session: URLSession = .shared) async -> ResolvedArchitecture {
        let fallback = genericArchitecture(engine: model.engine)
        switch model.engine {
        case .mlx:
            guard let repo = model.variants.first?.repo,
                  let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/config.json"),
                  let data = try? await fetchData(url, session: session),
                  let arch = parseMLXConfig(data, fallback: fallback) else {
                return ResolvedArchitecture(architecture: fallback, isResolved: false)
            }
            return ResolvedArchitecture(architecture: arch, isResolved: true)
        case .llamaCpp:
            guard let url = URL(string: "https://huggingface.co/api/models/\(model.id)?expand%5B%5D=gguf"),
                  let data = try? await fetchData(url, session: session),
                  let arch = parseGGUFMetadata(data, fallback: fallback) else {
                return ResolvedArchitecture(architecture: fallback, isResolved: false)
            }
            return ResolvedArchitecture(architecture: arch, isResolved: true)
        case .apple:
            // Unreachable: Explore browses Hugging Face and `Source.engine` only ever yields .mlx or
            // .llamaCpp — the OS's system model has no repo to discover, let alone a config to resolve.
            // If one ever reaches here, "unresolved" is the honest answer; there is nothing to fetch.
            return ResolvedArchitecture(architecture: fallback, isResolved: false)
        }
    }

    /// Pure: parse an MLX repo's `config.json` into a corrected architecture (nil if the essential shape
    /// fields are absent — the caller then keeps the honest fallback). A VLM config nests the language
    /// model under `text_config`; we read that when present. `head_dim` falls back to `hidden/heads`.
    static func parseMLXConfig(_ data: Data, fallback: LLMArchitecture) -> LLMArchitecture? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let cfg = (root["text_config"] as? [String: Any]) ?? root
        func int(_ key: String) -> Int? { (cfg[key] as? NSNumber)?.intValue ?? (root[key] as? NSNumber)?.intValue }
        guard let layers = int("num_hidden_layers"),
              let hidden = int("hidden_size"),
              let heads = int("num_attention_heads"),
              let context = int("max_position_embeddings"), context > 0 else { return nil }
        let kvHeads = int("num_key_value_heads") ?? heads
        let headDim = int("head_dim") ?? (heads > 0 ? hidden / heads : 128)
        let vocab = int("vocab_size") ?? fallback.vocab
        let modelType = (cfg["model_type"] as? String) ?? fallback.modelType
        let tie = (cfg["tie_word_embeddings"] as? NSNumber)?.boolValue ?? fallback.tieWordEmbeddings
        return LLMArchitecture(
            modelType: modelType, swiftModelClass: fallback.swiftModelClass,
            hidden: hidden, layers: layers, vocab: vocab, tieWordEmbeddings: tie,
            attention: .fullAttention(kvHeads: max(1, kvHeads), headDim: max(1, headDim), layers: layers),
            nativeContext: context, thinkingCapable: fallback.thinkingCapable, eos: fallback.eos,
            chatTemplate: fallback.chatTemplate, promptTemplate: fallback.promptTemplate,
            reasoningStyle: fallback.reasoningStyle, modalities: fallback.modalities)
    }

    /// Pure: parse a GGUF repo's HF `gguf` metadata block. The public API exposes `context_length`
    /// (+ architecture / eos_token) but not the KV-head shape, so we correct the native context — the lever
    /// the ContextPolicy clamp needs — and keep the fallback KV shape. Nil if `context_length` is absent.
    static func parseGGUFMetadata(_ data: Data, fallback: LLMArchitecture) -> LLMArchitecture? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gguf = root["gguf"] as? [String: Any],
              let context = (gguf["context_length"] as? NSNumber)?.intValue, context > 0 else { return nil }
        let modelType = (gguf["architecture"] as? String) ?? fallback.modelType
        let eos = (gguf["eos_token"] as? String) ?? fallback.eos
        return LLMArchitecture(
            modelType: modelType, swiftModelClass: fallback.swiftModelClass,
            hidden: fallback.hidden, layers: fallback.layers, vocab: fallback.vocab,
            tieWordEmbeddings: fallback.tieWordEmbeddings, attention: fallback.attention,
            nativeContext: context, thinkingCapable: fallback.thinkingCapable, eos: eos,
            chatTemplate: fallback.chatTemplate, promptTemplate: fallback.promptTemplate,
            reasoningStyle: fallback.reasoningStyle, modalities: fallback.modalities)
    }

    // MARK: - Grouping (pure — unit-tested)

    /// Group a flat repo list into models-with-variants: peel the trailing quant descriptor off each repo
    /// name to get the base identity, then collect every quant under it (most-downloaded model first).
    public static func group(_ repos: [(repo: String, dl: Int)],
                             publisher: String, engine: EngineKind) -> [RemoteModel] {
        struct Acc { var name: String; var dl: Int; var variants: [RemoteVariant] }
        var byBase: [String: Acc] = [:]
        var order: [String] = []

        for (repo, dl) in repos {
            let leaf = repo.split(separator: "/").last.map(String.init) ?? repo
            guard isChatModel(leaf) else { continue }
            let (base, quant) = splitQuant(leaf)
            let key = base.lowercased()
            let v = RemoteVariant(quantLabel: quant, repo: repo, fileName: nil, sizeBytes: nil)
            if byBase[key] == nil { byBase[key] = Acc(name: prettify(base), dl: dl, variants: [v]); order.append(key) }
            else {
                byBase[key]!.dl = max(byBase[key]!.dl, dl)
                if !byBase[key]!.variants.contains(where: { $0.quantLabel == quant }) { byBase[key]!.variants.append(v) }
            }
        }
        // Preserve download order (repos arrive sorted), variants sorted by a bit-precision rank.
        return order.map { key in
            let a = byBase[key]!
            return RemoteModel(id: "\(publisher)/\(a.name)", name: a.name, publisher: publisher,
                               engine: engine, downloads: a.dl,
                               variants: a.variants.sorted { quantRank($0.quantLabel) < quantRank($1.quantLabel) })
        }
    }

    /// Skip embeddings / rerankers / vision-only / non-chat artifacts that slip past the pipeline filter.
    static func isChatModel(_ leaf: String) -> Bool {
        let l = leaf.lowercased()
        for bad in ["embedding", "reranker", "-rerank", "guard", "whisper", "-vl-", "-ocr", "-tts", "-asr"] {
            if l.contains(bad) { return false }
        }
        return true
    }

    /// The tokens (from the end) that describe a quantization, and the base name that precedes them.
    static func splitQuant(_ leaf: String) -> (base: String, quant: String) {
        var parts = leaf.split(separator: "-").map(String.init)
        var peeled: [String] = []
        while let last = parts.last, isQuantToken(last), parts.count > 1 {
            peeled.insert(last, at: 0); parts.removeLast()
        }
        let base = parts.joined(separator: "-")
        let quant = peeled.isEmpty ? "default" : normalizeQuant(peeled.joined(separator: "-"))
        return (base, quant)
    }

    static func isQuantToken(_ t: String) -> Bool {
        let s = t.lowercased()
        if s.range(of: #"^\d+bit$"#, options: .regularExpression) != nil { return true }         // 4bit, 8bit
        if s.range(of: #"^q\d+(_\w+)*$"#, options: .regularExpression) != nil { return true }     // q8, q4_k_m
        if s.range(of: #"^dq\d*(plus)?$"#, options: .regularExpression) != nil { return true }     // dq, dq4plus
        return ["bf16", "fp16", "fp8", "mxfp4", "nf4", "dwq", "optiq", "qat", "awq", "gptq",
                "int4", "int8", "8bpw", "4bpw"].contains(s)
    }

    /// A human label for a peeled quant descriptor.
    static func normalizeQuant(_ q: String) -> String {
        let s = q.lowercased()
        if let m = s.range(of: #"\d+bit"#, options: .regularExpression) { return String(s[m]).replacingOccurrences(of: "bit", with: "-bit") }
        if s.hasPrefix("q") { return q.uppercased() }
        if s == "bf16" || s == "fp16" { return s.uppercased() }
        if s == "mxfp4" { return "MXFP4" }
        return q
    }

    /// Sort key so lower-precision (smaller) variants list first.
    static func quantRank(_ label: String) -> Int {
        let l = label.lowercased()
        if l.contains("1-bit") || l.contains("q1") { return 1 }
        if l.contains("2-bit") || l.contains("q2") || l.contains("mxfp4") { return 2 }
        if l.contains("3-bit") || l.contains("q3") { return 3 }
        if l.contains("4-bit") || l.contains("q4") || l.contains("nf4") || l.contains("int4") { return 4 }
        if l.contains("5-bit") || l.contains("q5") { return 5 }
        if l.contains("6-bit") || l.contains("q6") { return 6 }
        if l.contains("8-bit") || l.contains("q8") || l.contains("int8") { return 8 }
        if l.contains("bf16") || l.contains("fp16") || l.contains("16-bit") { return 16 }
        return 10
    }

    /// Tidy a base repo name into a display name: drop trailing "-it"/"-Instruct"/"-Chat" noise, spaces.
    static func prettify(_ base: String) -> String {
        var s = base
        for suffix in ["-it", "-It", "-Instruct", "-instruct", "-Chat", "-chat"] {
            if s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        }
        return s.replacingOccurrences(of: "-", with: " ")
    }
}
