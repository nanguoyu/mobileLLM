// SPDX-License-Identifier: MIT

import Foundation

/// One turn in a chat, as handed to the engine (DESIGN §2.2 / §2.3).
public struct ChatTurn: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Equatable, Codable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Why generation stopped.
public enum StopReason: String, Sendable, Equatable, Codable {
    case eos            // hit the end-of-sequence token
    case maxTokens      // hit `Sampling.maxTokens`
    case stopSequence   // hit a caller-supplied stop string
    case cancelled      // the caller cancelled (partial answer is still committed)
}

/// End-of-generation statistics (DESIGN §2.2).
public struct Stats: Sendable, Equatable, Codable {
    public var promptTokens: Int
    public var genTokens: Int
    public var promptTPS: Double
    public var tokensPerSecond: Double
    public var peakMemoryBytes: Int64
    public var stopReason: StopReason

    public init(promptTokens: Int, genTokens: Int, promptTPS: Double, tokensPerSecond: Double,
                peakMemoryBytes: Int64, stopReason: StopReason) {
        self.promptTokens = promptTokens
        self.genTokens = genTokens
        self.promptTPS = promptTPS
        self.tokensPerSecond = tokensPerSecond
        self.peakMemoryBytes = peakMemoryBytes
        self.stopReason = stopReason
    }
}

/// A streamed engine event (DESIGN §2.2). Reasoning + answer are already split from the raw token
/// stream by the engine's `ThinkSplitter`; `.done` closes the stream with `Stats`.
public enum EngineDelta: Sendable, Equatable {
    case reasoning(String)
    case answer(String)
    case done(Stats)
}

/// The engine contract the app talks to (DESIGN §2.2). Actor-friendly: the concrete engine is an
/// actor, and `generate` hands back an `AsyncThrowingStream` the UI consumes on the main actor.
/// LLMCore ships only the protocol + a mock; the real MLX-fork engine conforms to it in a later step.
public protocol LLMEngine: Sendable {
    /// Load a model variant's resident weights from `weightsDir` (offline). `progress` reports 0…1.
    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws

    /// Release the resident weights (and clear the accelerator reuse pool in the real engine).
    func unload() async

    /// Stream a generation from the chat history. The stream ends with a single `.done(Stats)` before
    /// finishing (or finishes throwing on error / cancellation).
    func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error>
}
