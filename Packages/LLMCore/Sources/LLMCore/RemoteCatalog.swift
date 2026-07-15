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

extension RemoteModel {
    /// Convert a discovered model into a catalog `LLMModel` so it flows through the same download / fit /
    /// activate pipeline as the curated models. The architecture is GENERIC — the fit badge uses the
    /// estimated size, and MLX loads the checkpoint from its own config + jinja template (no hand adapter),
    /// which is exactly why Explore models are flagged unverified.
    public func asLLMModel(paramsBillions: Double?) -> LLMModel {
        let arch = LLMArchitecture(
            modelType: "generic", swiftModelClass: "", hidden: 0, layers: 0, vocab: 0,
            tieWordEmbeddings: false, attention: .fullAttention(kvHeads: 8, headDim: 128, layers: 32),
            nativeContext: 32_768, thinkingCapable: true, eos: "<|im_end|>",
            chatTemplate: .repoFile("chat_template.jinja"), promptTemplate: .chatML, reasoningStyle: .thinkTags)
        let backend: Backend = engine == .mlx ? .mlxStock : .llamaCppGGUF
        let vs = variants.map { v in
            LLMVariant(quant: .other(v.quantLabel), backend: backend,
                       onDiskBytes: v.sizeBytes ?? RemoteModel.estimateBytes(paramsBillions: paramsBillions, quant: v.quantLabel),
                       source: ModelSource(huggingFaceRepo: v.repo, fileName: v.fileName))
        }
        return LLMModel(id: id, displayName: name, family: .qwen, publisher: publisher,
                        summary: "Community model — loaded from its own template. Not hand-verified.",
                        license: .apache2, architecture: arch, variants: vs,
                        defaultVariant: vs.first?.quant ?? .gguf4bit)
    }

    /// Parse the parameter count from a model name, in billions (largest number followed by B/M).
    /// "Qwen3 9B" → 9, "Qwen3 0.6B" → 0.6, "gpt-oss 20b" → 20, "30B A3B" (MoE) → 30 (total, for size).
    public static func paramCount(from name: String) -> Double? {
        var best: Double?
        let scanner = name.replacingOccurrences(of: "-", with: " ")
        for token in scanner.split(separator: " ") {
            let t = token.lowercased()
            if let m = t.range(of: #"^\d+(\.\d+)?[bm]$"#, options: .regularExpression) {
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

    public enum CatalogError: Error, Sendable { case badResponse }

    /// Trending MLX models, most-downloaded first, grouped into models-with-variants.
    public static func trending(limit: Int = 80,
                                session: URLSession = .shared) async throws -> [RemoteModel] {
        let raw = try await fetch(
            "https://huggingface.co/api/models?author=\(mlxOrg)&pipeline_tag=text-generation"
            + "&sort=downloads&direction=-1&limit=\(min(limit * 3, 300))&full=false", session: session)
        return group(raw, publisher: mlxOrg, engine: .mlx).prefix(limit).map { $0 }
    }

    /// Search MLX models by free text (HF full-text search over the org).
    public static func search(_ query: String, limit: Int = 60,
                              session: URLSession = .shared) async throws -> [RemoteModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return try await trending(limit: limit, session: session) }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let raw = try await fetch(
            "https://huggingface.co/api/models?author=\(mlxOrg)&search=\(enc)"
            + "&sort=downloads&direction=-1&limit=\(min(limit * 3, 300))&full=false", session: session)
        return group(raw, publisher: mlxOrg, engine: .mlx).prefix(limit).map { $0 }
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
