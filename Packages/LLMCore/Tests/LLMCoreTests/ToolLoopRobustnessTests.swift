// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The agent-loop failure modes the existing `ToolLoopTests` leaves open: cancellation *while a tool is
/// mid-execution*, a syntactically broken `<tool_call>` body, and TWO calls emitted in one turn. These pin
/// the CURRENT contract (read off the implementation), not an aspirational one — a green run is the
/// no-hang / no-leak guarantee.
final class ToolLoopRobustnessTests: XCTestCase {

    // MARK: - Scaffolding

    /// A scripted engine that replays one canned answer per `generate` call (as a single chunk) and counts
    /// how many times it was asked to generate — so a test can prove the loop stopped calling the model.
    private final class CountingScriptedEngine: LLMEngine, @unchecked Sendable {
        private let scripts: [String]
        private let lock = NSLock()
        private var callCount = 0
        init(_ scripts: [String]) { self.scripts = scripts }

        var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }

        func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {}
        func unload() async {}

        func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
            lock.lock(); let idx = callCount; callCount += 1; lock.unlock()
            let answer = idx < scripts.count ? scripts[idx] : "(no more script)"
            return AsyncThrowingStream { cont in
                cont.yield(.answer(answer))
                cont.yield(.done(Stats(promptTokens: 0, genTokens: 1, promptTPS: 0, tokensPerSecond: 1,
                                       peakMemoryBytes: 0, stopReason: .eos)))
                cont.finish()
            }
        }
    }

    /// A tool that announces when it has started executing, then waits cooperatively for cancellation. The
    /// wait is BOUNDED (never an infinite spin) so a propagation failure fails the test instead of hanging.
    private struct ProbeTool: Tool {
        let gate: Gate
        var schema: ToolSchema {
            ToolSchema(name: "probe", description: "A test tool that blocks until cancelled.", parameters: [])
        }
        func execute(argumentsJSON: String) async -> String {
            await gate.markStarted()
            for _ in 0..<600 {                       // ≤ ~6 s hard cap — cancellation exits far sooner
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return "probe-executed"
        }
    }

    private actor Gate {
        private(set) var started = false
        func markStarted() { started = true }
        func isStarted() -> Bool { started }
    }

    private actor Sink {
        private(set) var events: [ToolLoopEvent] = []
        private(set) var finished = false
        func append(_ e: ToolLoopEvent) { events.append(e) }
        func finish() { finished = true }
        func isFinished() -> Bool { finished }
        func answers() -> String {
            events.compactMap { if case .answer(let s) = $0 { return s }; return nil }.joined()
        }
        func toolCallNames() -> [String] {
            events.compactMap { if case .toolCall(let c) = $0 { return c.name }; return nil }
        }
    }

    /// Poll `cond` until true or the deadline elapses — a hang-proof wait (no unbounded `await`).
    private func poll(_ deadline: TimeInterval = 5, until cond: @Sendable () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func collect(_ loop: ToolLoop, _ msg: String) async throws -> [ToolLoopEvent] {
        var out: [ToolLoopEvent] = []
        for try await e in loop.run(messages: [ChatTurn(role: .user, content: msg)], params: Sampling()) {
            out.append(e)
        }
        return out
    }

    // MARK: - Cancellation mid-tool-execution

    /// Cancelling the consumer WHILE a tool is executing must (a) terminate the loop promptly — no hang —
    /// and (b) never emit a further model turn: the second script must never reach the consumer as an answer.
    func testCancellationMidToolExecutionStopsPromptlyWithoutFurtherTurns() async {
        let engine = CountingScriptedEngine([
            #"<tool_call>{"name":"probe","arguments":{}}</tool_call>"#,
            "SENTINEL_SECOND_TURN",                  // the answer that must NOT appear once we cancel
        ])
        let gate = Gate()
        let loop = ToolLoop(engine: engine, registry: ToolRegistry([ProbeTool(gate: gate)]), maxIterations: 4)
        let sink = Sink()

        let consumer = Task {
            do {
                for try await e in loop.run(messages: [ChatTurn(role: .user, content: "go")], params: Sampling()) {
                    await sink.append(e)
                }
            } catch {}
            await sink.finish()
        }

        let started = await poll { await gate.isStarted() }
        XCTAssertTrue(started, "the probe tool must have begun executing before we cancel")

        consumer.cancel()                            // cancel mid-tool-execution

        let terminated = await poll { await sink.isFinished() }
        XCTAssertTrue(terminated, "the loop must terminate promptly after cancellation (no hang)")

        let answers = await sink.answers()
        XCTAssertFalse(answers.contains("SENTINEL_SECOND_TURN"),
                       "no further model turn may be surfaced to the consumer after cancellation")
        _ = await consumer.result                    // the task is fully settled (belt-and-braces)
    }

    // MARK: - Malformed tool_call JSON

    /// A syntactically broken `<tool_call>` body must not crash and must not leak its markup as visible
    /// text. CURRENT contract: the parse fails → no tool runs, nothing is fed back, and the loop ends with a
    /// clean `.done` (the model simply "answered" whatever plain text preceded the broken block).
    func testMalformedToolCallJSONIsDroppedNotExecutedNorLeaked() async throws {
        let engine = CountingScriptedEngine([
            // Truncated JSON body — missing the closing braces the model never emitted.
            #"Working on it. <tool_call>{"name": "calculator", "arguments": {"expression": "1+1""#
                + "</tool_call>",
        ])
        let loop = ToolLoop(engine: engine, registry: .builtIn, maxIterations: 4)
        let events = try await collect(loop, "compute 1+1")

        XCTAssertFalse(events.contains { if case .toolCall = $0 { return true }; return false },
                       "a malformed tool call must not execute any tool")
        let answers = events.compactMap { if case .answer(let s) = $0 { return s }; return nil }.joined()
        XCTAssertTrue(answers.contains("Working on it."), "plain text before the broken block still streams")
        XCTAssertFalse(answers.contains("tool_call"), "the <tool_call> markup must never leak as answer text")
        XCTAssertFalse(answers.contains("calculator"), "the broken JSON body must never leak as answer text")
        XCTAssertTrue(events.last.map { if case .done = $0 { return true }; return false } ?? false,
                      "the loop ends cleanly with a single .done")
    }

    // MARK: - Two calls in one turn

    /// When the model emits TWO `<tool_call>` blocks in a single turn, the loop runs only the FIRST and
    /// drops the rest (`break loop` on the first detected call). Pinning this first-call-only contract.
    func testTwoToolCallsInOneTurnRunsOnlyTheFirst() async throws {
        let engine = CountingScriptedEngine([
            #"<tool_call>{"name":"calculator","arguments":{"expression":"1+1"}}</tool_call>"#
                + #"<tool_call>{"name":"current_datetime","arguments":{}}</tool_call>"#,
            "Done.",
        ])
        let loop = ToolLoop(engine: engine, registry: .builtIn, maxIterations: 4)
        let events = try await collect(loop, "do two things")

        let toolCalls = events.compactMap { if case .toolCall(let c) = $0 { return c.name }; return nil }
        XCTAssertEqual(toolCalls, ["calculator"], "only the first of two same-turn calls runs")
        XCTAssertFalse(toolCalls.contains("current_datetime"), "the second same-turn call is dropped")
        XCTAssertTrue(events.contains { if case .toolResult(_, let r) = $0 { return r == "2" }; return false },
                      "the first call's result (1+1 = 2) is fed back")
    }
}

/// The on-device failure this pins: a 2B model asked for a reminder emitted a `<tool_call>` whose JSON
/// didn't parse. The processor dropped it silently — no tool, no error, no text — so the turn committed
/// empty and the UI could only say "Stopped". The loop now hands the mistake back so the model can retry.
final class MalformedToolCallRecoveryTests: XCTestCase {

    func testMalformedBodyIsReportedNotDropped() {
        var p = ToolCallProcessor()
        var events = p.feed("<tool_call>{\"name\": \"create_reminder\", \"arguments\": {oops}</tool_call>")
        events += p.finish()
        guard case .malformed(let body)? = events.first else {
            return XCTFail("a malformed body must surface, got \(events)")
        }
        XCTAssertTrue(body.contains("create_reminder"), "the raw body rides along so the model sees its mistake")
    }

    func testUnterminatedMalformedCallAtStreamEndIsReported() {
        var p = ToolCallProcessor()
        _ = p.feed("<tool_call>{\"name\": ")
        let events = p.finish()
        XCTAssertTrue(events.contains { if case .malformed = $0 { return true } else { return false } })
    }

    /// End-to-end: turn 1 emits bad JSON, the loop feeds back the correction, turn 2 gets it right, the
    /// tool runs, turn 3 answers — instead of the whole turn vanishing.
    func testLoopRecoversFromAMalformedCall() async throws {
        let engine = TurnScriptedEngine([
            "<tool_call>{\"name\": \"calculator\", \"arguments\": {17+25}}</tool_call>",
            "<tool_call>{\"name\": \"calculator\", \"arguments\": {\"expression\": \"17+25\"}}</tool_call>",
            "It's 42.",
        ])
        let loop = ToolLoop(engine: engine, registry: .builtIn)
        var answer = "", ranTool = false
        for try await event in loop.run(messages: [ChatTurn(role: .user, content: "17+25?")],
                                        params: Sampling()) {
            switch event {
            case .answer(let s): answer += s
            case .toolCall(let c): XCTAssertEqual(c.name, "calculator"); ranTool = true
            default: break
            }
        }
        XCTAssertTrue(ranTool, "the retry's valid call must actually run")
        XCTAssertTrue(answer.contains("42"), "the model reaches its answer, got: \(answer)")

        // The correction was handed back before the retry, quoting what the model actually sent. Asserted
        // on the behavior, not the wording: the note used to hard-code "wasn't valid JSON", which is a lie
        // in three of the four tool dialects — Gemma's native call isn't JSON at all — so it now speaks the
        // active dialect (`ToolDialect.malformedNote`).
        let second = engine.receivedHistories()[1]
        XCTAssertTrue(second.contains { $0.content.contains("could not be read") },
                      "turn 2 must be told the last call didn't parse")
        XCTAssertTrue(second.contains { $0.content.contains("{17+25}") },
                      "turn 2 must see the body it actually sent")
    }
}
