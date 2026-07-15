// SPDX-License-Identifier: MIT
//
// Local gate for the llama.cpp engine (macOS). Loads a GGUF via `LlamaEngine` and streams a short
// answer, proving the binaryTarget links, Metal runs, and the ThinkSplitter/PieceDecoder path is clean.
//
//   swift run llama-smoke /path/to/Bonsai-8B-Q1_0.gguf "The capital of France is"
//
// (run needs `DYLD_FALLBACK_LIBRARY_PATH=/usr/lib` for libc++.)

import Foundation
import LLMCore
import LLMEngineLlama

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: llama-smoke <model.gguf> [prompt]\n".utf8))
    exit(2)
}
let modelPath = URL(fileURLWithPath: args[1])
let prompt = args.count >= 3 ? args[2] : "The capital of France is"

// A minimal single-turn model/variant pointing at the local file's directory.
let fileName = modelPath.lastPathComponent
let dir = modelPath.deletingLastPathComponent()
let arch = LLMArchitecture(
    modelType: "qwen3", swiftModelClass: "Qwen3Model", hidden: 0, layers: 0, vocab: 0,
    tieWordEmbeddings: false, attention: .fullAttention(kvHeads: 0, headDim: 0, layers: 0),
    nativeContext: 8192, thinkingCapable: true, eos: "<|im_end|>", chatTemplate: .builtin("chatml"))
let variant = LLMVariant(quant: .binary1bit, backend: .llamaCppGGUF, onDiskBytes: 0,
                         source: ModelSource(huggingFaceRepo: "local", fileName: fileName))
let model = LLMModel(id: "smoke", displayName: "Smoke", family: .bonsai, publisher: "local",
                     summary: "", license: .apache2, architecture: arch, variants: [variant],
                     defaultVariant: .binary1bit)

let engine = LlamaEngine()

func line(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

do {
    line("Loading \(fileName) …")
    let t0 = Date()
    try await engine.load(model: model, variant: variant, weightsDir: dir) { _ in }
    line(String(format: "Loaded in %.2fs. Generating …", Date().timeIntervalSince(t0)))

    var params = Sampling()
    params.maxTokens = 48
    params.thinking = false            // deterministic-ish; ChatML pre-fills an empty think block
    params.temperature = 0
    params.seed = 42

    let messages = [ChatTurn(role: .user, content: prompt)]
    print(prompt, terminator: "")
    for try await delta in engine.generate(messages: messages, params: params) {
        switch delta {
        case .reasoning(let s): FileHandle.standardError.write(Data(s.utf8))
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
