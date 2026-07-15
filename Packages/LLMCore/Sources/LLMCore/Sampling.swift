// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Decode / sampling parameters for one generation (DESIGN §2.2). Defaults are the shipped values.
public struct Sampling: Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repetitionPenalty: Double
    public var maxTokens: Int
    /// Emit a `<think>` block (`enable_thinking` in the chat template).
    public var thinking: Bool
    /// History is trimmed to this many tokens before prefill (always keeping the system turn).
    public var contextTokenCap: Int
    /// KV-cache quantization width; `0` = unquantized. 4-bit quantizes each cache after a warmup.
    public var kvBits: Int
    /// Number of tokens to keep unquantized before switching the KV cache to `kvBits` (DESIGN §2.2).
    public var quantizedKVStart: Int
    /// Optional fixed seed for reproducible sampling.
    public var seed: UInt64?

    public init(temperature: Double = 0.7,
                topP: Double = 0.95,
                topK: Int = 20,
                repetitionPenalty: Double = 1.05,
                maxTokens: Int = 1024,
                thinking: Bool = true,
                contextTokenCap: Int = 8192,
                kvBits: Int = 4,
                quantizedKVStart: Int = 256,
                seed: UInt64? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.contextTokenCap = contextTokenCap
        self.kvBits = kvBits
        self.quantizedKVStart = quantizedKVStart
        self.seed = seed
    }
}
