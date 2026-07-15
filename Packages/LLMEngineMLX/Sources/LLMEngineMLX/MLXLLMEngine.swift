// SPDX-License-Identifier: MIT

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import LLMCore

/// The real on-device engine: loads an MLX model (1-bit via the PrismML fork) and streams tokens,
/// routing the Bonsai `<think>` block to `.reasoning` and the rest to `.answer` via `ThinkSplitter`.
/// Conforms to `LLMCore.LLMEngine`, so the UI layer drives it exactly like `MockLLMEngine`.
public actor MLXLLMEngine: LLMEngine {
    public enum EngineError: Error, Sendable { case notLoaded, noUserMessage }

    private var container: ModelContainer?
    private var loadedID: String?

    public init() {}
    public var isLoaded: Bool { container != nil }

    // MARK: - Loading

    /// Load by Hugging Face id, downloading via the hub if absent (first-run / smoke path).
    public func loadFromHub(_ id: String,
                            progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        let c = try await loadModelContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id: id
        ) { p in progress(p.fractionCompleted) }
        adopt(c, id: id)
    }

    /// Load from a local directory of already-downloaded weights (the app path — AppRuntime downloads).
    public func load(directory: URL,
                     progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        let c = try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader())
        adopt(c, id: directory.lastPathComponent)
        progress(1)
    }

    /// `LLMEngine` conformance — load the app-downloaded weights directory.
    /// (`LLMModel`/`LLMVariant` are qualified: MLXLLM also defines an `LLMModel`.)
    public func load(model: LLMCore.LLMModel, variant: LLMCore.LLMVariant, weightsDir: URL,
                     progress: @Sendable @escaping (Double) -> Void) async throws {
        try await load(directory: weightsDir, progress: progress)
    }

    public func unload() async {
        container = nil; loadedID = nil
        MLX.GPU.clearCache()
    }

    private func adopt(_ c: ModelContainer, id: String) {
        container = c; loadedID = id
        MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)   // weights are resident → keep the reuse pool small
    }

    // MARK: - Generation

    public nonisolated func generate(messages: [ChatTurn],
                                     params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { await self.run(messages: messages, params: params, into: continuation) }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func run(messages: [ChatTurn], params: Sampling,
                     into cont: AsyncThrowingStream<EngineDelta, Error>.Continuation) async {
        do {
            guard let container else { throw EngineError.notLoaded }
            let system = messages.last { $0.role == .system }?.content
            guard let prompt = messages.last(where: { $0.role == .user })?.content else {
                throw EngineError.noUserMessage
            }
            let gp = GenerateParameters(maxTokens: params.maxTokens, temperature: Float(params.temperature),
                                        topP: Float(params.topP), topK: params.topK)
            let session = ChatSession(container, instructions: system, generateParameters: gp)
            session.additionalContext = ["enable_thinking": params.thinking]

            var splitter = ThinkSplitter()
            var tokens = 0
            let start = Date()
            MLX.GPU.resetPeakMemory()
            for try await chunk in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                tokens += 1
                for d in splitter.feed(chunk) { cont.yield(Self.map(d)) }
            }
            for d in splitter.finish() { cont.yield(Self.map(d)) }

            let secs = max(Date().timeIntervalSince(start), 0.0001)
            let stop: StopReason = (params.maxTokens > 0 && tokens >= params.maxTokens) ? .maxTokens : .eos
            cont.yield(.done(stats(tokens: tokens, tps: Double(tokens) / secs, stop: stop)))
            cont.finish()
        } catch is CancellationError {
            cont.yield(.done(stats(tokens: 0, tps: 0, stop: .cancelled)))   // partial answer already emitted
            cont.finish()
        } catch {
            cont.finish(throwing: error)
        }
    }

    private func stats(tokens: Int, tps: Double, stop: StopReason) -> Stats {
        Stats(promptTokens: 0, genTokens: tokens, promptTPS: 0, tokensPerSecond: tps,
              peakMemoryBytes: Int64(MLX.GPU.peakMemory), stopReason: stop)
    }

    private static func map(_ d: ThinkSplitter.Delta) -> EngineDelta {
        switch d {
        case .reasoning(let s): .reasoning(s)
        case .answer(let s): .answer(s)
        }
    }
}
