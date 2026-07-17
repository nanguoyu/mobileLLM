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
    FileHandle.standardError.write(Data("usage: llama-smoke <catalog-id> <gguf-dir> [prompt] [--think] [--tools] [--memory-eval] [--image <path>]… [--mmproj <path>]\n".utf8))
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

/// One labelled turn for `--memory-eval`. Each runs in a FRESH store, so a case can't be carried by what
/// an earlier one saved.
struct MemoryEvalCase {
    let prompt: String
    let shouldSave: Bool
    let kind: String

    /// Written to be HARD in both directions, because the two failure modes hide each other.
    ///
    /// The positives are stated in PASSING — none of them says "remember this". "请记住我的名字" is the
    /// easy case and proves almost nothing; real memory has to notice a fact the user just happened to
    /// mention. They span the categories a person actually has: pet, allergy, work, study, car, hobby,
    /// family, preference, diet, home.
    ///
    /// The negatives include three traps that NAME the same topics without stating a durable fact about
    /// the user — a model matching on keywords ("猫", "车", "工作") saves these and looks like it has
    /// great recall. Apple Intelligence saved "似乎每句都记住" on the user's device; that is the failure
    /// this half exists to catch.
    static let all: [MemoryEvalCase] = [
        // — worth keeping, mentioned in passing —
        .init(prompt: "我养了一只叫Momo的橘猫", shouldSave: true, kind: "pet"),
        .init(prompt: "我对花生过敏，所以那家店我去不了", shouldSave: true, kind: "allergy"),
        .init(prompt: "我在一家做医疗影像的公司当后端工程师", shouldSave: true, kind: "work"),
        .init(prompt: "我在南京大学读计算机，明年毕业", shouldSave: true, kind: "study"),
        .init(prompt: "我开的是一辆蓝色的 Model 3", shouldSave: true, kind: "car"),
        .init(prompt: "我周末基本都在爬山", shouldSave: true, kind: "hobby"),
        .init(prompt: "我有个五岁的女儿", shouldSave: true, kind: "family"),
        .init(prompt: "我写代码只用 Swift，别的语言我不碰", shouldSave: true, kind: "preference"),
        .init(prompt: "I'm vegetarian, by the way", shouldSave: true, kind: "diet/en"),
        .init(prompt: "我住在南京", shouldSave: true, kind: "home"),
        // — chatter: a permanent note here is a bug —
        .init(prompt: "你好", shouldSave: false, kind: "greeting"),
        .init(prompt: "谢谢！", shouldSave: false, kind: "thanks"),
        .init(prompt: "17+25 等于几？", shouldSave: false, kind: "question"),
        .init(prompt: "苹果公司是谁创立的？", shouldSave: false, kind: "question"),
        .init(prompt: "帮我写一个 Python 的快排", shouldSave: false, kind: "task"),
        .init(prompt: "我现在有点饿", shouldSave: false, kind: "transient"),
        .init(prompt: "今天天气不错", shouldSave: false, kind: "small talk"),
        .init(prompt: "我今天有点累", shouldSave: false, kind: "transient"),
        // — the traps: the topic is named, the fact is not —
        .init(prompt: "养猫需要注意什么？", shouldSave: false, kind: "trap: cat, not their cat"),
        .init(prompt: "如果我买辆车，你推荐什么？", shouldSave: false, kind: "trap: hypothetical car"),
    ]
}

/// In-memory store for `--tools` and `--memory-eval`, so a gate can prove a `remember` call actually WROTE
/// something without touching the app's real memory file.
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

    // --memory-eval: does this model save what's worth keeping AND leave the rest alone? Both halves
    // matter and they pull against each other — the failure we shipped was invisible in each direction:
    // a model that saves nothing looks calm, and a model that saves every sentence looks eager. The only
    // test that separates them is a labelled set run against real weights.
    if args.contains("--memory-eval") {
        params.maxTokens = think ? 1024 : 384
        let dialect = ToolDialect(model.architecture.promptTemplate)
        line("Memory eval — \(model.displayName), dialect \(dialect.rawValue)\n")

        var passed = 0, failed = 0
        var savedWhenItShouldnt: [String] = [], missedWhenItShould: [String] = []

        for c in MemoryEvalCase.all {
            let store = SmokeMemoryStore()
            let registry = ToolRegistry.assemble(config: .default, memoryStore: store,
                                                 eventStore: nil, locationProvider: nil)
            // Clock pinned: the block's date line changes every minute, and at temperature 0 that alone
            // swings the score by ±2 cases on identical code — enough to credit a prompt change that did
            // nothing. A gate whose number moves on its own can't be used to decide anything.
            let loop = ToolLoop(engine: engine, registry: registry, dialect: dialect,
                                now: Date(timeIntervalSince1970: 1_784_000_000))
            var reply = ""
            for try await ev in loop.run(messages: [ChatTurn(role: .user, content: c.prompt)], params: params) {
                if case .answer(let s) = ev { reply += s }
            }
            let facts = await store.list().map(\.text)
            let didSave = !facts.isEmpty
            let ok = didSave == c.shouldSave
            ok ? (passed += 1) : (failed += 1)
            if !ok && didSave { savedWhenItShouldnt.append("\(c.prompt) → \(facts.joined(separator: " | "))") }
            if !ok && !didSave { missedWhenItShould.append(c.prompt) }
            let mark = ok ? "PASS" : "FAIL"
            line("\(mark) [\(c.kind)] \(c.prompt)")
            line("       want \(c.shouldSave ? "SAVE" : "no save")  got \(didSave ? facts.joined(separator: " | ") : "(nothing)")")
            // On a failure the model's reply is the evidence for WHY — whether it considered the fact and
            // declined, or never noticed it was one. Guessing at that is how prompt tuning turns into
            // superstition.
            if !ok { line("       said: \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))") }
        }

        let wanted = MemoryEvalCase.all.filter(\.shouldSave).count
        let notWanted = MemoryEvalCase.all.count - wanted
        line("\n=== \(passed)/\(MemoryEvalCase.all.count) — recall \(wanted - missedWhenItShould.count)/\(wanted) "
             + "· restraint \(notWanted - savedWhenItShouldnt.count)/\(notWanted) ===")
        if !missedWhenItShould.isEmpty {
            line("MISSED (a durable fact went unsaved):")
            missedWhenItShould.forEach { line("  · \($0)") }
        }
        if !savedWhenItShouldnt.isEmpty {
            line("OVER-SAVED (chatter became a permanent note):")
            savedWhenItShouldnt.forEach { line("  · \($0)") }
        }
        await engine.unload()
        exit(failed == 0 ? 0 : 1)
    }

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
