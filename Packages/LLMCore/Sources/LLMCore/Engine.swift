// SPDX-License-Identifier: MIT

import Foundation

/// One turn in a chat, as handed to the engine (DESIGN §2.2 / §2.3).
public struct ChatTurn: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Equatable, Codable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String
    /// Encoded image bytes (JPEG/PNG) attached to this turn, in display order. Empty for a text-only
    /// turn (the default) — the vision-capable llama.cpp engine feeds these to the model's mmproj via
    /// mtmd; every other path ignores them. Kept as raw encoded bytes (not decoded pixels) because
    /// `mtmd_helper_bitmap_init_from_buf` accepts encoded files directly.
    public let images: [Data]

    public init(role: Role, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    // Hand-written Codable so old persisted turns (no `images` key) still decode — `images` defaults to
    // empty — and a text-only turn re-encodes to the SAME bytes as before (the key is omitted when empty).
    // ChatStore builds ChatTurn transiently today, but the type is Codable and must stay snapshot-safe.
    private enum CodingKeys: String, CodingKey { case role, content, images }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        images = try c.decodeIfPresent([Data].self, forKey: .images) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !images.isEmpty { try c.encode(images, forKey: .images) }
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
