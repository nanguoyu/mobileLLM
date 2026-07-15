// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A deterministic, MLX-free `LLMEngine` for the app + tests. It emits a scripted `<think>…</think>`
/// block followed by an answer, char-chunked and fed through the real `ThinkSplitter`, so the whole
/// streaming path — reasoning/answer disclosure, incremental rendering, `.done(Stats)` — is exercised
/// with no accelerator. This is what the UI runs against until the fork-linked engine lands.
public actor MockLLMEngine: LLMEngine {

    /// What the mock "generates". `chunkSize == 1` splits every tag across chunk boundaries, which is
    /// exactly the case the `ThinkSplitter` must survive.
    public struct Script: Sendable {
        public var reasoning: String
        public var answer: String
        public var chunkSize: Int
        /// Optional per-chunk delay (nanoseconds). Defaults to 0 so tests run instantly.
        public var chunkDelayNanos: UInt64

        public init(reasoning: String = "The user asked a question. Let me reason about it step by step, "
                                       + "then give a clear, direct answer.",
                    answer: String = "Here is the answer: everything is working end to end.",
                    chunkSize: Int = 1,
                    chunkDelayNanos: UInt64 = 0) {
            self.reasoning = reasoning
            self.answer = answer
            self.chunkSize = max(1, chunkSize)
            self.chunkDelayNanos = chunkDelayNanos
        }
    }

    private let script: Script
    private var loaded = false

    public init(script: Script = Script()) {
        self.script = script
    }

    public func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        for i in 1...5 { progress(Double(i) / 5) }   // a few progress ticks
        loaded = true
    }

    public func unload() async {
        loaded = false
    }

    public nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(messages: messages, params: params, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Produce the scripted raw token stream and route it through `ThinkSplitter`, honoring the
    /// `thinking` flag and cooperative cancellation.
    private func run(messages: [ChatTurn], params: Sampling,
                     into continuation: AsyncThrowingStream<EngineDelta, Error>.Continuation) async throws {
        let raw = params.thinking
            ? "<think>\(script.reasoning)</think>\(script.answer)"
            : script.answer
        let start = Date()

        var splitter = ThinkSplitter()
        var idx = raw.startIndex
        while idx < raw.endIndex {
            try Task.checkCancellation()
            let end = raw.index(idx, offsetBy: script.chunkSize, limitedBy: raw.endIndex) ?? raw.endIndex
            let chunk = String(raw[idx..<end])
            idx = end
            for delta in splitter.feed(chunk) { yield(delta, to: continuation) }
            if script.chunkDelayNanos > 0 { try await Task.sleep(nanoseconds: script.chunkDelayNanos) }
        }
        for delta in splitter.finish() { yield(delta, to: continuation) }   // flush the withheld tail

        let elapsed = max(0.0001, Date().timeIntervalSince(start))
        let promptChars = messages.reduce(0) { $0 + $1.content.count }
        let stats = Stats(promptTokens: promptChars / 4,        // rough char→token proxy
                          genTokens: raw.count,
                          promptTPS: 0,
                          tokensPerSecond: Double(raw.count) / elapsed,
                          peakMemoryBytes: 0,
                          stopReason: .eos)
        continuation.yield(.done(stats))
    }

    private func yield(_ delta: ThinkSplitter.Delta,
                       to continuation: AsyncThrowingStream<EngineDelta, Error>.Continuation) {
        switch delta {
        case .reasoning(let s): continuation.yield(.reasoning(s))
        case .answer(let s):    continuation.yield(.answer(s))
        }
    }
}
