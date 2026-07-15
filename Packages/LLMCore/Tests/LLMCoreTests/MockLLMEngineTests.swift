// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import LLMCore

final class MockLLMEngineTests: XCTestCase {

    /// The mock streams a `<think>` block (reasoning) then an answer, and terminates with `.done`.
    func testStreamsThinkThenAnswerThenDone() async throws {
        let engine = MockLLMEngine(script: .init(reasoning: "considering the options",
                                                 answer: "the answer is 42",
                                                 chunkSize: 1))
        var reasoning = "", answer = ""
        var reasoningEndedBeforeAnswer = true
        var sawAnswer = false
        var done: Stats?

        for try await delta in engine.generate(messages: [ChatTurn(role: .user, content: "hi")],
                                               params: Sampling()) {
            switch delta {
            case .reasoning(let s):
                reasoning += s
                if sawAnswer { reasoningEndedBeforeAnswer = false }   // reasoning must precede answer
            case .answer(let s):
                answer += s
                sawAnswer = true
            case .done(let stats):
                done = stats
            }
        }

        XCTAssertEqual(reasoning, "considering the options")
        XCTAssertEqual(answer, "the answer is 42")
        XCTAssertTrue(reasoningEndedBeforeAnswer, "all reasoning deltas arrive before any answer delta")
        XCTAssertTrue(sawAnswer)

        let stats = try XCTUnwrap(done, "the stream must end with .done(Stats)")
        XCTAssertEqual(stats.stopReason, .eos)
        XCTAssertGreaterThan(stats.genTokens, 0)
    }

    /// With thinking disabled the mock emits only an answer (no reasoning), still ending with `.done`.
    func testThinkingDisabledEmitsOnlyAnswer() async throws {
        let engine = MockLLMEngine(script: .init(reasoning: "should not appear", answer: "direct"))
        var reasoning = "", answer = ""
        var done = false
        var params = Sampling(); params.thinking = false

        for try await delta in engine.generate(messages: [], params: params) {
            switch delta {
            case .reasoning(let s): reasoning += s
            case .answer(let s):    answer += s
            case .done:             done = true
            }
        }
        XCTAssertEqual(reasoning, "")
        XCTAssertEqual(answer, "direct")
        XCTAssertTrue(done)
    }

    /// The final `.done` is always the last event and the stream then finishes (terminates).
    func testDoneIsTerminal() async throws {
        let engine = MockLLMEngine()
        var deltas: [EngineDelta] = []
        for try await d in engine.generate(messages: [], params: Sampling()) { deltas.append(d) }

        guard case .done = deltas.last else {
            return XCTFail("last delta must be .done")
        }
        // exactly one .done
        let doneCount = deltas.filter { if case .done = $0 { return true } else { return false } }.count
        XCTAssertEqual(doneCount, 1)
    }
}
