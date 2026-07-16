// SPDX-License-Identifier: MIT
//
// Local gate for the llama.cpp engine (macOS). Loads a catalog model's GGUF via `LlamaEngine` — using
// that model's real PromptTemplate + ReasoningStyle — and streams a short answer, proving the adapter,
// Metal, and the ThinkSplitter/PieceDecoder path are correct per model.
//
//   swift run llama-smoke <catalog-id> <gguf-dir> ["prompt"] [--think]
//   e.g. swift run llama-smoke minicpm5-1b /Users/.../gguf-models "你好，请用一句话介绍你自己"
//
// (run needs `DYLD_FALLBACK_LIBRARY_PATH=/usr/lib` for libc++.)

import Foundation
import LLMCore
import LLMEngineLlama

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: llama-smoke <catalog-id> <gguf-dir> [prompt] [--think]\n".utf8))
    let ids = LLMCatalog.all.map(\.id).joined(separator: ", ")
    FileHandle.standardError.write(Data("catalog ids: \(ids)\n".utf8))
    exit(2)
}
let modelID = args[1]
let dir = URL(fileURLWithPath: args[2], isDirectory: true)
let prompt = args.count >= 4 && !args[3].hasPrefix("--") ? args[3] : "The capital of France is"
let think = args.contains("--think")

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
guard let variant = model.variants(for: .llamaCpp).first else {
    FileHandle.standardError.write(Data("'\(modelID)' has no GGUF variant\n".utf8))
    exit(2)
}

let engine = LlamaEngine()
func line(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

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

    let messages = [ChatTurn(role: .user, content: prompt)]
    line("PROMPT> \(prompt)")
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
