// SPDX-License-Identifier: MIT

import Foundation
import LLMCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The third engine: Apple's own on-device model, via FoundationModels. It conforms to
/// `LLMCore.LLMEngine`, so the app drives it exactly like the MLX and llama.cpp engines — but it owns no
/// weights. The OS holds the model and runs it out of process, which is why `load` fetches nothing,
/// `unload` frees nothing, and the memory governor gives this backend a free pass.
///
/// Deliberately NOT annotated `@available(iOS 26, macOS 26)`: app assembly registers it in the router
/// unconditionally, so on a device that can't run it the engine is still there to say WHY ("Apple
/// Intelligence is turned off…") rather than being absent and leaving the UI to invent an explanation.
///
/// TEXT ONLY: `ChatTurn.images` is ignored — this API surface takes no image input. In practice the
/// composer only offers images for a variant that advertises vision (llama.cpp + mmproj), so no image
/// ever reaches this engine.
public actor AppleLLMEngine: LLMEngine {

    public init() {}

    /// The OS's live verdict on its own model. Cheap, and safe on any OS.
    public nonisolated var status: SystemModelStatus { AppleSystemModel.status() }

    // MARK: - Loading

    /// Nothing to load: the system model has no weights of ours to fetch or map, and `weightsDir` names a
    /// directory that never exists for this engine. All this does is answer "can it run?" up front —
    /// throwing the REAL reason — so a tap on Use reports the problem like any other load failure instead
    /// of appearing to work and dead-ending at the first message.
    public func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        if let reason = status.unavailableReason { throw AppleEngineError.unavailable(reason) }
        progress(1)   // there is no download: it's ready the moment the OS says it is
    }

    /// A true no-op: we hold no weights to release. The OS decides when to unload its own model.
    public func unload() async {}

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
            // Re-checked per generation, not just at load: Apple Intelligence can be switched off, or the
            // model evicted, between activating this engine and sending a message.
            if let reason = status.unavailableReason { throw AppleEngineError.unavailable(reason) }
            let chat = try AppleChatMapping.prepareChat(messages)
            #if canImport(FoundationModels)
            if #available(iOS 26, macOS 26, *) {
                try await stream(chat, plan: AppleChatMapping.plan(for: params), into: cont)
                return
            }
            #endif
            // Unreachable: `status` reports `.unsupportedOS` on exactly the OSes that fail the check
            // above, so it has already thrown. Kept as the honest answer rather than a `fatalError`.
            throw AppleEngineError.unavailable(.unsupportedOS)
        } catch is CancellationError {
            cont.yield(.done(Self.stats(stop: .cancelled)))   // the partial answer is already emitted
            cont.finish()
        } catch {
            cont.finish(throwing: error)
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    private func stream(_ chat: AppleChatMapping.PreparedChat,
                        plan: AppleChatMapping.GenerationPlan,
                        into cont: AsyncThrowingStream<EngineDelta, Error>.Continuation) async throws {
        // A FRESH session per generation. Our contract hands over the full history every time (the
        // ToolLoop appends tool results as new turns), so the transcript we build IS the conversation
        // state — reusing a session across calls would replay the history on top of itself.
        let session = LanguageModelSession(transcript: Self.transcript(for: chat))
        var splitter = ThinkSplitter()
        var differ = SnapshotDiffer()
        do {
            for try await snapshot in session.streamResponse(to: chat.prompt,
                                                             options: Self.options(for: plan)) {
                try Task.checkCancellation()
                // Snapshots are CUMULATIVE: each carries the whole answer so far. Subtract what's already
                // been emitted, or the UI repeats the entire response on every chunk.
                let delta = differ.delta(for: snapshot.content)
                if delta.isEmpty { continue }
                // Through the same splitter as every other engine: this model has no <think> convention,
                // so in practice it all lands in `.answer` — but the routing stays uniform.
                for d in splitter.feed(delta) { cont.yield(Self.map(d)) }
            }
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.mapped(error)
        }
        for d in splitter.finish() { cont.yield(Self.map(d)) }   // flush the withheld partial-tag tail
        cont.yield(.done(Self.stats(stop: .eos)))
        cont.finish()
    }

    /// Replay the conversation as a transcript. Instructions first (the session reads them from here when
    /// constructed with a transcript), then each prior turn in order.
    @available(iOS 26, macOS 26, *)
    private static func transcript(for chat: AppleChatMapping.PreparedChat) -> Transcript {
        var entries: [Transcript.Entry] = []
        if let instructions = chat.instructions {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: [])))
        }
        for turn in chat.history {
            let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: turn.content))]
            switch turn.role {
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            case .user, .system:
                // `prepareChat` has already coalesced every system turn into `instructions`, so anything
                // left here is a user turn.
                entries.append(.prompt(Transcript.Prompt(segments: segments)))
            }
        }
        return Transcript(entries: entries)
    }

    @available(iOS 26, macOS 26, *)
    private static func options(for plan: AppleChatMapping.GenerationPlan) -> GenerationOptions {
        let sampling: GenerationOptions.SamplingMode?
        switch plan.sampling {
        case .greedy: sampling = .greedy
        case .topK(let k, let seed): sampling = .random(top: k, seed: seed)
        case .nucleus(let threshold, let seed): sampling = .random(probabilityThreshold: threshold, seed: seed)
        case .automatic: sampling = nil
        }
        return GenerationOptions(sampling: sampling,
                                 temperature: plan.temperature,
                                 maximumResponseTokens: plan.maximumResponseTokens)
    }

    /// Framework error → ours. The cases a user can act on get our own wording; the rest keep the
    /// framework's own `localizedDescription` rather than a message we invented for a failure we don't
    /// model. `GenerationError` isn't frozen, so an unknown case degrades to the same honest passthrough.
    @available(iOS 26, macOS 26, *)
    static func mapped(_ error: LanguageModelSession.GenerationError) -> AppleEngineError {
        switch error {
        case .exceededContextWindowSize:
            return .contextWindowExceeded
        case .guardrailViolation, .refusal:
            return .guardrailViolation
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        case .assetsUnavailable:
            // The model's assets went away underneath us — the same situation as "still downloading".
            return .unavailable(.modelNotReady)
        default:
            return .generationFailed(reason: error.localizedDescription)
        }
    }
    #endif

    // MARK: - Stats

    /// FoundationModels exposes NO token counts: `Response` and `Snapshot` carry the text, the raw content
    /// and the transcript entries — there is no prompt-token, generated-token or stop-reason signal to
    /// read. So the counts are honest zeros rather than a guess; a SNAPSHOT count is not a token count (one
    /// snapshot can carry many tokens), and inventing a rate from it would be worse than reporting none.
    /// The stats footer already hides a zero rate. `peakMemoryBytes` is 0 for the same reason this engine
    /// is free: the weights live in the OS's process, never in our footprint.
    ///
    /// `stopReason` is `.eos` for any completed stream because the framework reports no reason: if a
    /// response were truncated at `maximumResponseTokens` we'd have no way to tell.
    private static func stats(stop: StopReason) -> Stats {
        Stats(promptTokens: 0, genTokens: 0, promptTPS: 0, tokensPerSecond: 0,
              peakMemoryBytes: 0, stopReason: stop)
    }

    private static func map(_ d: ThinkSplitter.Delta) -> EngineDelta {
        switch d {
        case .reasoning(let s): .reasoning(s)
        case .answer(let s): .answer(s)
        }
    }
}
