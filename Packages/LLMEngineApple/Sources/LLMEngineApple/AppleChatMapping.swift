// SPDX-License-Identifier: MIT

import Foundation
import LLMCore

/// The pure half of the engine: how our `[ChatTurn]` and `Sampling` become the shape a
/// `LanguageModelSession` needs.
///
/// Deliberately free of FoundationModels types. Those are `@available(iOS 26, macOS 26)`, so code that
/// mentions them can't even be NAMED on an older OS — a test running there could not construct a
/// `GenerationOptions` to assert against. Factoring every decision into plain functions over plain types
/// keeps the real logic (which turn is the prompt, which sampling knob survives) testable everywhere, and
/// leaves `AppleLLMEngine` with nothing but translation.
enum AppleChatMapping {

    // MARK: - Chat

    /// One generation request, derived purely from the app's `[ChatTurn]`.
    struct PreparedChat: Equatable {
        /// Every system turn, coalesced — a session takes ONE instructions entry.
        var instructions: String?
        /// The prior conversation, roles preserved, oldest first: replayed into the session's transcript.
        var history: [ChatTurn]
        /// The final user turn — the message being answered.
        var prompt: String
    }

    /// Map the FULL history onto the session inputs, preserving order and roles.
    ///
    /// Mirrors `MLXLLMEngine.prepareChat` on purpose. The app may emit more than one system turn (the
    /// system prompt plus an auto-compaction breadcrumb, both `.system`) while a session models a single
    /// instructions entry, so system turns coalesce in order. The final turn is the user message being
    /// answered; everything before it is prior context.
    static func prepareChat(_ turns: [ChatTurn]) throws -> PreparedChat {
        let systemParts = turns.filter { $0.role == .system && !$0.content.isEmpty }.map(\.content)
        let instructions = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")

        let conversation = turns.filter { $0.role != .system }
        guard let last = conversation.last, last.role == .user else {
            throw AppleEngineError.noUserMessage
        }
        return PreparedChat(instructions: instructions,
                            history: Array(conversation.dropLast()),
                            prompt: last.content)
    }

    // MARK: - Sampling

    /// Which sampling mode survives the trip to `GenerationOptions.SamplingMode`. The framework's mode is
    /// an EITHER/OR — top-k XOR nucleus — while our `Sampling` carries both, so exactly one can be honored.
    enum SamplingChoice: Equatable {
        /// Deterministic: what a temperature of 0 actually means.
        case greedy
        case topK(Int, seed: UInt64?)
        /// Nucleus / top-p, which the framework spells `random(probabilityThreshold:)`.
        case nucleus(Double, seed: UInt64?)
        /// Neither knob constrains anything — leave sampling to the framework's own default.
        case automatic
    }

    /// The `GenerationOptions` we'd build, expressed without naming the framework's types.
    struct GenerationPlan: Equatable {
        var sampling: SamplingChoice
        var temperature: Double?
        var maximumResponseTokens: Int?
    }

    /// Pure: our sampling knobs → the framework's. Only `temperature`, one truncation knob, the seed and
    /// `maxTokens` have equivalents. The rest are dropped rather than faked onto something that isn't them:
    ///   • `repetitionPenalty` — no equivalent; the OS owns decoding.
    ///   • `thinking` — the system model has no `<think>` convention to switch on or off.
    ///   • `kvBits` / `quantizedKVStart` — the KV cache is the OS's, out of our process entirely.
    ///   • `contextTokenCap` — no equivalent, but nothing is lost: `ChatStore` has already trimmed the
    ///     history to it before the engine is called, and the session owns its own context window.
    static func plan(for params: Sampling) -> GenerationPlan {
        // Temperature 0 means "don't sample". Say that with `.greedy` rather than handing the framework a
        // 0 temperature alongside a random sampler — a contradiction it shouldn't have to resolve.
        guard params.temperature > 0 else {
            return GenerationPlan(sampling: .greedy, temperature: nil,
                                  maximumResponseTokens: responseTokenCap(params))
        }
        // Only one of our two truncation knobs can survive. Prefer nucleus when it actually constrains
        // anything: it's the finer-grained of the two, and the app's default (top-p 0.95) is a real
        // constraint while its top-k (20) is the coarser backstop.
        let sampling: SamplingChoice
        if params.topP > 0, params.topP < 1 {
            sampling = .nucleus(params.topP, seed: params.seed)
        } else if params.topK > 0 {
            sampling = .topK(params.topK, seed: params.seed)
        } else {
            sampling = .automatic
        }
        return GenerationPlan(sampling: sampling, temperature: params.temperature,
                              maximumResponseTokens: responseTokenCap(params))
    }

    /// `maxTokens <= 0` is our vocabulary for "no cap"; the framework spells that `nil`.
    private static func responseTokenCap(_ params: Sampling) -> Int? {
        params.maxTokens > 0 ? params.maxTokens : nil
    }
}
