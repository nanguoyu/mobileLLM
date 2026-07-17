// SPDX-License-Identifier: MIT
//
// Local gate for the llama.cpp engine (macOS). Loads a catalog model's GGUF via `LlamaEngine` — using
// that model's real PromptTemplate + ReasoningStyle — and streams a short answer, proving the adapter,
// Metal, and the ThinkSplitter/PieceDecoder path are correct per model.
//
//   swift run llama-smoke <catalog-id> <gguf-dir> ["prompt"] [--think] [--image <path>]… [--mmproj <path>]
//   e.g. swift run llama-smoke minicpm5-1b /Users/.../gguf-models "你好，请用一句话介绍你自己"
//   vision: swift run llama-smoke qwen3.5-4b /Users/.../gguf "describe this" --image cat.jpg --mmproj mmproj-F16.gguf
//   tools:  swift run llama-smoke gemma-4-e2b /Users/.../gguf "我叫Tom，请记住我的名字" --tools
//
// `--tools` is the gate for tool calling: it runs the REAL agent loop with the REAL registry, in the
// model's own `ToolDialect`, and reports whether a tool actually EXECUTED. Nothing else catches this —
// a model handed the wrong tool dialect doesn't error, it improvises an unreadable call and then claims
// success in prose. That shipped: on Gemma/Hunyuan/DeepSeek no tool ever ran, and unit tests couldn't
// see it because they assert against our own idea of the format. Run this whenever a model is added.
//
// (run needs `DYLD_FALLBACK_LIBRARY_PATH=/usr/lib` for libc++.)

import Foundation
import LLMCore
import LLMEngineLlama
import AppRuntime

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: llama-smoke <catalog-id> <gguf-dir> [prompt] [--think] [--image <path>]… [--mmproj <path>]\n".utf8))
    let ids = LLMCatalog.all.map(\.id).joined(separator: ", ")
    FileHandle.standardError.write(Data("catalog ids: \(ids)\n".utf8))
    exit(2)
}
let modelID = args[1]
let dir = URL(fileURLWithPath: args[2], isDirectory: true)
let prompt = args.count >= 4 && !args[3].hasPrefix("--") ? args[3] : "The capital of France is"
let think = args.contains("--think")

// --image <path> (repeatable) attaches an encoded image to the user turn; --mmproj <path> supplies the
// vision projector so the engine brings up its multimodal context — together they verify the mtmd vision
// path end-to-end from the CLI (the orchestrator runs this with a real model + image).
var imagePaths: [String] = []
var mmprojPath: String?
do {
    var i = 0
    while i < args.count {
        if args[i] == "--image", i + 1 < args.count { imagePaths.append(args[i + 1]); i += 2; continue }
        if args[i] == "--mmproj", i + 1 < args.count { mmprojPath = args[i + 1]; i += 2; continue }
        i += 1
    }
}

guard var model = LLMCatalog.model(id: modelID) else {
    FileHandle.standardError.write(Data("unknown catalog id '\(modelID)'\n".utf8))
    exit(2)
}

// --style=none|think|implicit overrides the reasoning style; --auto forces the GGUF's embedded template
// (the Explore path) instead of the hand-written builder. Both are per-model tuning experiments.
let styleArg = args.first(where: { $0.hasPrefix("--style=") })?.split(separator: "=").last.map(String.init)
let forceAuto = args.contains("--auto")
if styleArg != nil || forceAuto {
    let style: ReasoningStyle = switch styleArg {
        case "none": .none; case "think": .thinkTags; case "implicit": .thinkTagsImplicitOpen
        default: model.architecture.reasoningStyle }
    let a = model.architecture
    let arch = LLMArchitecture(
        modelType: a.modelType, swiftModelClass: a.swiftModelClass, hidden: a.hidden, layers: a.layers,
        vocab: a.vocab, tieWordEmbeddings: a.tieWordEmbeddings, attention: a.attention,
        nativeContext: a.nativeContext, thinkingCapable: a.thinkingCapable, eos: a.eos,
        chatTemplate: a.chatTemplate, promptTemplate: forceAuto ? .auto : a.promptTemplate,
        reasoningStyle: style, modalities: a.modalities)
    model = LLMModel(id: model.id, displayName: model.displayName, family: model.family,
                     publisher: model.publisher, summary: model.summary, license: model.license,
                     architecture: arch, variants: model.variants, defaultVariant: model.defaultVariant)
    FileHandle.standardError.write(Data("(override: template=\(forceAuto ? "auto" : a.promptTemplate.rawValue) style=\(style.rawValue))\n".utf8))
}
guard var variant = model.variants(for: .llamaCpp).first else {
    FileHandle.standardError.write(Data("'\(modelID)' has no GGUF variant\n".utf8))
    exit(2)
}

// A CLI --mmproj overrides (or supplies) the variant's vision projector via its absolute path, so the
// engine's resolveProjector picks it up and initializes mtmd even for a catalog model that ships none.
if let mmprojPath {
    let size = ((try? FileManager.default.attributesOfItem(atPath: mmprojPath))?[.size] as? NSNumber)?.int64Value ?? 0
    variant = LLMVariant(quant: variant.quant, backend: variant.backend, onDiskBytes: variant.onDiskBytes,
                         source: variant.source,
                         visionProjector: VisionProjector(fileName: mmprojPath, sizeBytes: size))
}

let engine = LlamaEngine()
func line(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// In-memory store for `--tools`, so the gate can prove a `remember` call actually WROTE something
/// without touching the app's real memory file.
actor SmokeMemoryStore: MemoryStoring {
    private var facts: [MemoryFact] = []
    func save(_ text: String, source: MemoryFact.Source) async -> MemoryFact {
        let f = MemoryFact(text: text, source: source); facts.append(f); return f
    }
    func list() async -> [MemoryFact] { facts }
    func update(id: String, text: String) async {}
    func delete(id: String) async {}
    func deleteAll() async {}
}

do {
    line("Loading \(model.displayName) — \(variant.source.fileName ?? "?") "
         + "[\(model.architecture.promptTemplate.rawValue)/\(model.architecture.reasoningStyle.rawValue)] …")
    let t0 = Date()
    try await engine.load(model: model, variant: variant, weightsDir: dir) { _ in }
    line(String(format: "Loaded in %.2fs. Generating (thinking=%@) …", Date().timeIntervalSince(t0), think ? "on" : "off"))

    var params = Sampling()
    params.maxTokens = 64
    params.thinking = think
    params.temperature = think ? 0.6 : 0
    params.seed = 42

    var images: [Data] = []
    for p in imagePaths {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { line("cannot read image: \(p)"); exit(2) }
        images.append(d)
    }
    // --tools: the real registry + the real agent loop, in this model's own dialect. Reports what the
    // model EMITTED, whether our processor could read it, and whether the tool actually ran — the three
    // things that were silently false on every non-ChatML model.
    if args.contains("--tools") {
        // A tool round trip is a call, a result, and then an answer — 64 tokens (fine for the plain smoke)
        // truncates the model mid-call and reads as "it didn't call anything", which is the exact wrong
        // conclusion for this gate to hand back. Reasoning models need room for the thought too.
        params.maxTokens = think ? 1024 : 384
        let dialect = ToolDialect(model.architecture.promptTemplate)
        let store = SmokeMemoryStore()
        let registry = ToolRegistry.assemble(config: .default, memoryStore: store,
                                             eventStore: nil, locationProvider: nil)
        line("Dialect: \(dialect.rawValue) (from template \(model.architecture.promptTemplate.rawValue)) — "
             + "\(registry.schemas.count) tools")
        line("PROMPT> \(prompt)")
        var ran: [String] = []
        var answer = ""
        let loop = ToolLoop(engine: engine, registry: registry, dialect: dialect)
        for try await event in loop.run(messages: [ChatTurn(role: .user, content: prompt)], params: params) {
            switch event {
            case .toolCall(let c): line("  → CALL \(c.name) \(c.argumentsJSON)"); ran.append(c.name)
            case .toolResult(_, let r): line("  ← RESULT \(r.prefix(100))")
            case .answer(let s): answer += s
            case .reasoning, .done: break
            }
        }
        line("ANSWER> \(answer.trimmingCharacters(in: .whitespacesAndNewlines))")
        let saved = await store.list().map(\.text)
        line("TOOLS EXECUTED: \(ran.isEmpty ? "NONE" : ran.joined(separator: ", "))")
        line("MEMORY WRITTEN: \(saved)")
        // A model that says it remembered while nothing was saved is the exact failure this gate exists
        // for, so make it a non-zero exit rather than a line in the noise.
        let claimed = answer.contains("记住") || answer.lowercased().contains("remember")
        if ran.isEmpty && claimed {
            line("*** FAIL: the model claims it used a tool, but none ran. ***")
            await engine.unload(); exit(1)
        }
        await engine.unload()
        exit(ran.isEmpty ? 1 : 0)
    }

    let messages = [ChatTurn(role: .user, content: prompt, images: images)]
    line("PROMPT> \(prompt)\(images.isEmpty ? "" : "  [+\(images.count) image(s), mmproj=\(mmprojPath ?? variant.visionProjector?.fileName ?? "?")]")")
    var reasoningShown = false
    for try await delta in engine.generate(messages: messages, params: params) {
        switch delta {
        case .reasoning(let s):
            if !reasoningShown { FileHandle.standardError.write(Data("[reasoning] ".utf8)); reasoningShown = true }
            FileHandle.standardError.write(Data(s.utf8))
        case .answer(let s): print(s, terminator: ""); fflush(stdout)
        case .done(let stats):
            print("")
            line(String(format: "— done: %d tok, %.1f tok/s, prompt %d tok, peak %.0f MB, stop=%@",
                        stats.genTokens, stats.tokensPerSecond, stats.promptTokens,
                        Double(stats.peakMemoryBytes) / 1_048_576, stats.stopReason.rawValue))
        }
    }
    await engine.unload()
} catch {
    line("FAILED: \(error)")
    exit(1)
}
