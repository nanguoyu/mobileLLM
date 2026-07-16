// SPDX-License-Identifier: MIT

import Foundation
@testable import LLMCore

// Shared test doubles for driving the FULL agent loop (`ToolLoop`) deterministically. The doubles in
// `ToolLoopTests`/`ToolLoopRobustnessTests` are file-private and answer-only; these are richer and shared:
// a turn can emit `.reasoning` before its `.answer` (with an embedded `<tool_call>`), and every generate
// call's message history is recorded so a test can assert the framed tool result reached the NEXT turn.

/// A scripted `LLMEngine`: each `generate` call replays the next turn's exact `EngineDelta` sequence, then a
/// trailing `.done` (unless the script already ends in one). This lets a test interleave reasoning + answer
/// per turn and drive the loop through multiple tool round-trips.
final class TurnScriptedEngine: LLMEngine, @unchecked Sendable {
    private let turns: [[EngineDelta]]
    private let lock = NSLock()
    private var callIndex = 0
    private var histories: [[ChatTurn]] = []

    /// Full control: each turn is the exact delta sequence to emit (a `.done` is appended automatically).
    init(deltaTurns: [[EngineDelta]]) { self.turns = deltaTurns }

    /// Convenience: answer-only turns (one `.answer` chunk each), like the existing `ScriptedEngine`.
    convenience init(_ answers: [String]) { self.init(deltaTurns: answers.map { [.answer($0)] }) }

    /// The message histories received across all `generate` calls, in order (thread-safe snapshot).
    func receivedHistories() -> [[ChatTurn]] { lock.lock(); defer { lock.unlock() }; return histories }
    /// How many times the engine was asked to generate (proves the loop stopped calling the model).
    func generateCallCount() -> Int { lock.lock(); defer { lock.unlock() }; return callIndex }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}

    func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
        lock.lock()
        let idx = callIndex; callIndex += 1
        histories.append(messages)
        lock.unlock()
        let deltas = idx < turns.count ? turns[idx] : [.answer("(no more script)")]
        return AsyncThrowingStream { cont in
            for d in deltas { cont.yield(d) }
            let hasDone = deltas.contains { if case .done = $0 { return true }; return false }
            if !hasDone {
                cont.yield(.done(Stats(promptTokens: 1, genTokens: 1, promptTPS: 1, tokensPerSecond: 1,
                                       peakMemoryBytes: 0, stopReason: .eos)))
            }
            cont.finish()
        }
    }
}

/// A minimal `Tool` with a fixed name whose `execute` returns a canned string (ignoring arguments) — for
/// pinning registry semantics (name collisions) and untrusted-framing regardless of tool identity.
struct StubTool: Tool {
    let name: String
    let result: String
    let desc: String
    init(name: String, result: String, desc: String = "a stub tool") {
        self.name = name; self.result = result; self.desc = desc
    }
    var schema: ToolSchema { ToolSchema(name: name, description: desc, parameters: []) }
    func execute(argumentsJSON: String) async -> String { result }
}

/// A `Tool` that echoes back the exact `argumentsJSON` it received — proves the loop hands the model's
/// serialized arguments to `execute` unchanged (the argument-JSON handoff).
struct EchoArgsTool: Tool {
    let name: String
    init(name: String = "echo_args") { self.name = name }
    var schema: ToolSchema {
        ToolSchema(name: name, description: "Echoes the arguments it was given.",
                   parameters: [ToolParam(name: "value", kind: .string, description: "anything", required: false)])
    }
    func execute(argumentsJSON: String) async -> String { "ARGS=\(argumentsJSON)" }
}

/// Drain a `ToolLoop` for a single user message into an ordered event list (shared across the loop tests).
func collectLoop(_ loop: ToolLoop, _ message: String,
                 params: Sampling = Sampling()) async throws -> [ToolLoopEvent] {
    var out: [ToolLoopEvent] = []
    for try await e in loop.run(messages: [ChatTurn(role: .user, content: message)], params: params) {
        out.append(e)
    }
    return out
}

/// The concatenated `.answer` text surfaced by a loop run.
func answerText(_ events: [ToolLoopEvent]) -> String {
    events.compactMap { if case .answer(let s) = $0 { return s }; return nil }.joined()
}

/// The `.toolCall` names in order.
func toolCallNames(_ events: [ToolLoopEvent]) -> [String] {
    events.compactMap { if case .toolCall(let c) = $0 { return c.name }; return nil }
}

/// The `.toolResult` result strings in order.
func toolResults(_ events: [ToolLoopEvent]) -> [String] {
    events.compactMap { if case .toolResult(_, let r) = $0 { return r }; return nil }
}
