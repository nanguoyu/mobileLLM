// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// A scripted engine: each successive `generate` call replays the next canned answer (as one chunk),
/// so the agent loop can be driven deterministically without a real model.
private final class ScriptedEngine: LLMEngine, @unchecked Sendable {
    private let scripts: [String]
    private let lock = NSLock()
    private var call = 0
    init(_ scripts: [String]) { self.scripts = scripts }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}

    func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
        lock.lock(); let idx = call; call += 1; lock.unlock()
        let answer = idx < scripts.count ? scripts[idx] : "(no more script)"
        return AsyncThrowingStream { cont in
            cont.yield(.answer(answer))
            cont.yield(.done(Stats(promptTokens: 0, genTokens: 1, promptTPS: 0, tokensPerSecond: 1,
                                   peakMemoryBytes: 0, stopReason: .eos)))
            cont.finish()
        }
    }
}

final class ToolLoopTests: XCTestCase {

    private func collect(_ loop: ToolLoop, _ msg: String) async throws -> [ToolLoopEvent] {
        var out: [ToolLoopEvent] = []
        for try await e in loop.run(messages: [ChatTurn(role: .user, content: msg)], params: Sampling()) {
            out.append(e)
        }
        return out
    }

    func testInjectsToolsIntoSystemTurn() {
        let msgs = ToolPrompt.inject(ToolRegistry.builtIn.schemas, into: [ChatTurn(role: .user, content: "hi")])
        XCTAssertEqual(msgs.first?.role, .system)
        XCTAssertTrue(msgs.first?.content.contains("calculator") ?? false)
        XCTAssertTrue(msgs.first?.content.contains("<tool_call>") ?? false)
    }

    func testRunsToolThenAnswers() async throws {
        // Pass 1: the model asks for the calculator. Pass 2: it answers using the result.
        let engine = ScriptedEngine([
            #"I'll compute that. <tool_call>{"name":"calculator","arguments":{"expression":"17+25"}}</tool_call>"#,
            "The answer is 42.",
        ])
        let loop = ToolLoop(engine: engine, registry: .builtIn, maxIterations: 4)
        let events = try await collect(loop, "what is 17+25?")

        // A calculator call ran and produced 42.
        XCTAssertTrue(events.contains { if case .toolCall(let c) = $0 { return c.name == "calculator" }; return false })
        XCTAssertTrue(events.contains { if case .toolResult(_, let r) = $0 { return r == "42" }; return false })
        // The pre-tool text streamed as answer, the tool markup did NOT.
        let answers = events.compactMap { if case .answer(let s) = $0 { return s }; return nil }.joined()
        XCTAssertTrue(answers.contains("The answer is 42."))
        XCTAssertFalse(answers.contains("tool_call"))
        // Ends with a done.
        XCTAssertTrue(events.last.map { if case .done = $0 { return true }; return false } ?? false)
    }

    func testAnswersDirectlyWhenNoToolNeeded() async throws {
        let engine = ScriptedEngine(["Paris is the capital of France."])
        let loop = ToolLoop(engine: engine, registry: .builtIn)
        let events = try await collect(loop, "capital of France?")
        XCTAssertFalse(events.contains { if case .toolCall = $0 { return true }; return false })
        let answers = events.compactMap { if case .answer(let s) = $0 { return s }; return nil }.joined()
        XCTAssertTrue(answers.contains("Paris"))
    }

    func testUnknownToolIsReportedNotCrashed() async throws {
        let engine = ScriptedEngine([#"<tool_call>{"name":"nonesuch","arguments":{}}</tool_call>"#])
        let loop = ToolLoop(engine: engine, registry: .builtIn)
        let events = try await collect(loop, "do something")
        // No toolCall event (we don't have it), but the loop finishes cleanly with a note.
        XCTAssertTrue(events.contains { if case .answer(let s) = $0 { return s.contains("nonesuch") }; return false })
        XCTAssertTrue(events.last.map { if case .done = $0 { return true }; return false } ?? false)
    }

    func testMaxIterationsGuardStops() async throws {
        // A model that ALWAYS asks for a tool must still terminate (guard), not loop forever.
        let engine = ScriptedEngine(Array(repeating:
            #"<tool_call>{"name":"current_datetime","arguments":{}}</tool_call>"#, count: 20))
        let loop = ToolLoop(engine: engine, registry: .builtIn, maxIterations: 3)
        let events = try await collect(loop, "loop please")
        let calls = events.filter { if case .toolCall = $0 { return true }; return false }.count
        XCTAssertLessThanOrEqual(calls, 3, "must not exceed maxIterations tool calls")
        XCTAssertTrue(events.last.map { if case .done = $0 { return true }; return false } ?? false)
    }
}
