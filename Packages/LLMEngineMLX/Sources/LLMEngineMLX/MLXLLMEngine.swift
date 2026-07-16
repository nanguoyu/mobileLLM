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
    public enum EngineError: Error, Sendable, Equatable, LocalizedError {
        case notLoaded
        case noUserMessage
        case loadFailed(reason: String)

        // User-facing text: this surfaces via `error.localizedDescription` in the chat UI, so it must
        // read as guidance, never a raw enum dump. The load hint keeps the real reason (a network vs.
        // out-of-memory failure needs different action) rather than blindly blaming memory.
        public var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "No model is loaded yet. Pick a model and wait for it to finish loading, then try again."
            case .noUserMessage:
                return "There's nothing to answer yet — send a message first."
            case .loadFailed(let reason):
                return "Couldn't load the model (\(reason)). If memory is tight, try a smaller quantization "
                    + "(for example a 4-bit build); otherwise re-download the model and try again."
            }
        }
    }

    private var container: ModelContainer?
    private var loadedID: String?

    public init() {}
    public var isLoaded: Bool { container != nil }

    // MARK: - Loading

    /// Load by Hugging Face id, downloading via the hub if absent (first-run / smoke path).
    public func loadFromHub(_ id: String,
                            progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        do {
            let c = try await loadModelContainer(
                from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id: id
            ) { p in progress(p.fractionCompleted) }
            adopt(c, id: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineError.loadFailed(reason: Self.reason(for: error))
        }
    }

    /// Load from a local directory of already-downloaded weights (the app path — AppRuntime downloads).
    public func load(directory: URL,
                     progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        do {
            let c = try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader())
            adopt(c, id: directory.lastPathComponent)
            progress(1)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineError.loadFailed(reason: Self.reason(for: error))
        }
    }

    /// A short, human-readable reason from a thrown load error. A custom `LocalizedError` (e.g. the
    /// hub layer's own) already carries a good message; anything else (NSError, plain enums) gives a
    /// bland or empty `localizedDescription`, so fall back to `String(describing:)` which keeps the
    /// MLX/Hub domain + code specifics.
    private static func reason(for error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        return String(describing: error)
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
            let chat = try Self.prepareChat(messages)

            // Every sampling knob the app exposes must reach the model — history is not the only thing
            // that used to be dropped. `kvBits == 0` means "unquantized" here but `nil` upstream; a
            // repetition penalty of exactly 1 is a no-op, so skip building the processor for it.
            let gp = GenerateParameters(
                maxTokens: params.maxTokens,
                kvBits: params.kvBits > 0 ? params.kvBits : nil,
                quantizedKVStart: params.quantizedKVStart,
                temperature: Float(params.temperature),
                topP: Float(params.topP),
                topK: params.topK,
                repetitionPenalty: params.repetitionPenalty == 1 ? nil : Float(params.repetitionPenalty),
                seed: params.seed)

            // Restore the FULL conversation via the history initializer so multi-turn chat (and the
            // ToolLoop, which appends tool results as new turns) keeps every prior turn, not just the
            // latest user line.
            let session = ChatSession(container, instructions: chat.instructions,
                                      history: chat.history, generateParameters: gp)
            session.additionalContext = ["enable_thinking": params.thinking]

            var splitter = ThinkSplitter()
            var tokens = 0
            let start = Date()
            MLX.GPU.resetPeakMemory()
            for try await chunk in session.streamResponse(to: chat.prompt) {
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

    // MARK: - Chat mapping

    /// The MLX-side shape of one generation request, derived purely from the app's `[ChatTurn]`:
    /// a coalesced system instruction, the prior conversation as `Chat.Message` history, and the
    /// final user turn to answer.
    struct PreparedChat {
        var instructions: String?
        var history: [Chat.Message]
        var prompt: String
    }

    /// Map the FULL `[ChatTurn]` history to the `ChatSession` inputs, preserving order and roles.
    /// Pure and weight-free so `run` and the unit tests share one mapping.
    ///
    /// The app may emit more than one system turn (the system prompt plus an auto-compaction
    /// breadcrumb, both `.system`); chat templates model a single system message, so every system
    /// turn is coalesced into `instructions`. The final turn is the user message being answered —
    /// everything before it becomes prior context handed to the model.
    static func prepareChat(_ turns: [ChatTurn]) throws -> PreparedChat {
        let systemParts = turns.filter { $0.role == .system && !$0.content.isEmpty }.map(\.content)
        let instructions = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")

        let conversation = turns.filter { $0.role != .system }
        guard let last = conversation.last, last.role == .user else {
            throw EngineError.noUserMessage
        }
        let history = conversation.dropLast().map { turn -> Chat.Message in
            turn.role == .assistant ? .assistant(turn.content) : .user(turn.content)
        }
        return PreparedChat(instructions: instructions, history: Array(history), prompt: last.content)
    }
}
