// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import LLMCore

/// Resource and relevance boundaries for the on-device agent loop. These are behavioral guards, not model
/// prompt tests: even a weak quantized model that ignores the written policy must not drift from memory
/// bookkeeping into web search, repeat one identical call, or consume an unbounded number of full prefills.
final class ToolLoopBudgetTests: XCTestCase {

    func testSuccessfulRememberGoesStraightToToolFreeFinalAnswer() async throws {
        let memory = FakeMemoryStore()
        let registry = ToolRegistry([
            RememberTool(store: memory),
            StubTool(name: ToolID.webSearch.rawValue, result: "SEARCH MUST NOT RUN"),
        ])
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"remember","arguments":{"text":"The user is named Dong."}}</tool_call>"#,
            #"<tool_call>{"name":"web_search","arguments":{"query":"Dong"}}</tool_call>"#,
            "This turn must never be reached.",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: registry, maxIterations: 3),
            "Please remember that my name is Dong."
        )

        XCTAssertEqual(toolCallNames(events), [ToolID.remember.rawValue],
                       "memory bookkeeping must never open an unrelated web chain")
        let savedFacts = await memory.list()
        XCTAssertEqual(savedFacts.map(\.text), ["The user is named Dong."])
        XCTAssertEqual(engine.generateCallCount(), 2, "one tool pass plus one final synthesis")
        XCTAssertTrue(answerText(events).contains(ToolPrompt.missingFinalAnswer),
                      "a hallucinated final-pass call is hidden but must not leave an empty reply")

        let histories = engine.receivedHistories()
        XCTAssertEqual(histories.count, 2)
        let finalSystem = histories[1].first(where: { $0.role == .system })?.content ?? ""
        XCTAssertFalse(finalSystem.contains(ToolID.remember.rawValue))
        XCTAssertFalse(finalSystem.contains(ToolID.webSearch.rawValue),
                       "the final pass receives no tool schemas at all")

        let samplings = engine.receivedSamplings()
        XCTAssertFalse(samplings[0].thinking,
                       "tool selection is bounded control flow and must not start a long hidden think")
        XCTAssertEqual(samplings[0].temperature, 0)
        XCTAssertEqual(samplings[0].maxTokens, Sampling().maxTokens,
                       "an ordinary tools-on answer keeps the caller's full output budget")
        XCTAssertFalse(samplings[1].thinking, "a short tool wrap-up must not start another long think")
        XCTAssertEqual(samplings[1].temperature, Sampling().temperature,
                       "the visible synthesis keeps the caller's sampling temperature")
        XCTAssertEqual(samplings[1].maxTokens, Sampling().maxTokens)
    }

    /// Exact Qwen/Bonsai shape observed on the phone: natural possessive English is normalized and really
    /// executed, instead of being rejected and eventually echoed as if it had been saved.
    func testBonsaiPossessiveMemoryCallIsNormalizedExecutedAndAcknowledged() async throws {
        let memory = FakeMemoryStore()
        let registry = ToolRegistry([
            RememberTool(store: memory),
            StubTool(name: ToolID.webSearch.rawValue, result: "SEARCH MUST NOT RUN"),
        ])
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"remember","arguments":{"text":"The user's temporary device-test name is QuartzBonsai52039."}}</tool_call>"#,
            "MEMORY_SAVED_OK",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: registry, dialect: .qwen),
            "Please remember that my temporary device-test name is QuartzBonsai52039."
        )

        XCTAssertEqual(toolCallNames(events), [ToolID.remember.rawValue])
        XCTAssertEqual(answerText(events), "MEMORY_SAVED_OK")
        XCTAssertEqual(engine.generateCallCount(), 2)
        let facts = await memory.list()
        XCTAssertEqual(facts.map(\.text), [
            "The user says their temporary device-test name is QuartzBonsai52039."
        ])
        let surfacedCall = events.compactMap {
            if case .toolCall(let call) = $0 { return call }
            return nil
        }.first
        XCTAssertEqual(surfacedCall?.arg("text"),
                       "The user says their temporary device-test name is QuartzBonsai52039.")
        XCTAssertTrue(engine.receivedSamplings().allSatisfy { !$0.thinking })
    }

    /// Exact Gemma tool dialect observed on-device. This pins the parser + normalizer + execution handoff,
    /// not merely the model's ability to print the requested acknowledgement token.
    func testGemmaPossessiveMemoryCallIsNormalizedExecutedAndAcknowledged() async throws {
        let memory = FakeMemoryStore()
        let registry = ToolRegistry([
            RememberTool(store: memory),
            StubTool(name: ToolID.webSearch.rawValue, result: "SEARCH MUST NOT RUN"),
        ])
        let engine = TurnScriptedEngine([
            #"<|tool_call>call:remember{text:<|"|>The user's temporary device-test name is QuartzGemma49226.<|"|>}<tool_call|>"#,
            "MEMORY_SAVED_OK",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: registry, dialect: .gemma),
            "Please remember that my temporary device-test name is QuartzGemma49226."
        )

        XCTAssertEqual(toolCallNames(events), [ToolID.remember.rawValue])
        XCTAssertEqual(answerText(events), "MEMORY_SAVED_OK")
        XCTAssertEqual(engine.generateCallCount(), 2)
        let facts = await memory.list()
        XCTAssertEqual(facts.map(\.text), [
            "The user says their temporary device-test name is QuartzGemma49226."
        ])
        XCTAssertTrue(engine.receivedSamplings().allSatisfy { !$0.thinking })
    }

    func testSecondInvalidRememberIsVisibleAndStopsBeforeWebSearch() async throws {
        let memory = FakeMemoryStore()
        let registry = ToolRegistry([
            RememberTool(store: memory),
            StubTool(name: ToolID.webSearch.rawValue, result: "SEARCH MUST NOT RUN"),
        ])
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"remember","arguments":{"text":"用户叫 Dong"}}</tool_call>"#,
            #"<tool_call>{"name":"remember","arguments":{"text":"The user 用户叫 Dong"}}</tool_call>"#,
            #"<tool_call>{"name":"web_search","arguments":{"query":"Dong"}}</tool_call>"#,
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: registry),
            "Please remember that my name is Dong."
        )

        XCTAssertEqual(engine.generateCallCount(), 2, "a failed correction is terminal")
        XCTAssertEqual(toolCallNames(events), [ToolID.remember.rawValue])
        XCTAssertEqual(toolResults(events), [RememberTool.rejectedMemoryResult])
        XCTAssertEqual(answerText(events), RememberTool.rejectedMemoryReply)
        XCTAssertFalse(toolCallNames(events).contains(ToolID.webSearch.rawValue))
        let facts = await memory.list()
        XCTAssertTrue(facts.isEmpty)
        XCTAssertTrue(engine.receivedSamplings().allSatisfy { !$0.thinking })
    }

    func testPlainSuccessClaimDuringRememberCorrectionIsSuppressed() async throws {
        let memory = FakeMemoryStore()
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"remember","arguments":{"text":"用户叫 Dong"}}</tool_call>"#,
            "MEMORY_SAVED_OK",
            "A third generation must never run.",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: ToolRegistry([RememberTool(store: memory)])),
            "Please remember that my name is Dong."
        )

        XCTAssertEqual(engine.generateCallCount(), 2)
        XCTAssertFalse(answerText(events).contains("MEMORY_SAVED_OK"),
                       "plain prose cannot claim a tool side effect that was never executed")
        XCTAssertEqual(answerText(events), RememberTool.rejectedMemoryReply)
        XCTAssertEqual(toolResults(events), [RememberTool.rejectedMemoryResult])
        let facts = await memory.list()
        XCTAssertTrue(facts.isEmpty)
        XCTAssertTrue(engine.receivedSamplings().allSatisfy { !$0.thinking })
    }

    func testInitialFakeAckGetsOneRememberOnlyCorrectionAndCanSucceed() async throws {
        let memory = FakeMemoryStore()
        let registry = ToolRegistry([
            RememberTool(store: memory),
            StubTool(name: ToolID.webSearch.rawValue, result: "SEARCH MUST NOT RUN"),
        ])
        let engine = TurnScriptedEngine([
            "MEMORY_SAVED_OK",
            #"<tool_call>{"name":"remember","arguments":{"text":"The user is named QuartzRetry."}}</tool_call>"#,
            "SAVE_CONFIRMED",
        ])
        let params = Sampling(temperature: 0.83, maxTokens: 777, thinking: true)

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: registry),
            "Please remember that my temporary name is QuartzRetry.",
            params: params
        )

        XCTAssertEqual(answerText(events), "SAVE_CONFIRMED",
                       "the unverified first acknowledgement must never leak")
        XCTAssertEqual(toolCallNames(events), [ToolID.remember.rawValue])
        XCTAssertEqual(engine.generateCallCount(), 3)
        let facts = await memory.list()
        XCTAssertEqual(facts.map(\.text), ["The user is named QuartzRetry."])

        let samplings = engine.receivedSamplings()
        XCTAssertEqual(samplings.map(\.maxTokens), [777, 384, 777],
                       "only the correction pass receives the short structured-output cap")
        XCTAssertEqual(samplings.map(\.thinking), [false, false, false])
        XCTAssertEqual(samplings.map(\.temperature), [0, 0, 0.83])
        let firstSystem = engine.receivedHistories()[0]
            .first(where: { $0.role == .system })?.content ?? ""
        XCTAssertTrue(firstSystem.contains(ToolID.remember.rawValue))
        XCTAssertFalse(firstSystem.contains(ToolID.webSearch.rawValue),
                       "an explicit memory turn advertises remember only from its first pass")
    }

    func testInitialFakeAckGetsOnlyOneCorrectionThenFailsDeterministically() async throws {
        let memory = FakeMemoryStore()
        let engine = TurnScriptedEngine([
            "MEMORY_SAVED_OK",
            "MEMORY_SAVED_OK",
            #"<tool_call>{"name":"remember","arguments":{"text":"The user is named TooLate."}}</tool_call>"#,
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: ToolRegistry([RememberTool(store: memory)])),
            "Please remember that my name is Dong."
        )

        XCTAssertEqual(engine.generateCallCount(), 2)
        XCTAssertEqual(answerText(events), RememberTool.rejectedMemoryReply)
        XCTAssertFalse(answerText(events).contains("MEMORY_SAVED_OK"))
        XCTAssertTrue(toolCallNames(events).isEmpty)
        let facts = await memory.list()
        XCTAssertTrue(facts.isEmpty)
    }

    func testMemorySuccessClaimWithoutExplicitRequestStillRequiresTheTool() async throws {
        let memory = FakeMemoryStore()
        let engine = TurnScriptedEngine([
            "I'll remember that.",
            #"<tool_call>{"name":"remember","arguments":{"text":"The user is named ClaimGuard."}}</tool_call>"#,
            "Understood.",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: ToolRegistry([RememberTool(store: memory)])),
            "My temporary name is ClaimGuard."
        )

        XCTAssertEqual(answerText(events), "Understood.")
        XCTAssertFalse(answerText(events).contains("I'll remember"))
        let facts = await memory.list()
        XCTAssertEqual(facts.map(\.text), ["The user is named ClaimGuard."])
    }

    func testMalformedRememberThenPlainAckFailsInsteadOfPassingAsAnswer() async throws {
        let memory = FakeMemoryStore()
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"remember","arguments":{oops}}</tool_call>"#,
            "MEMORY_SAVED_OK",
            "A third generation must never run.",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: ToolRegistry([RememberTool(store: memory)])),
            "My temporary name is MalformedGuard."
        )

        XCTAssertEqual(engine.generateCallCount(), 2)
        XCTAssertEqual(answerText(events), ToolPrompt.malformedCallFailure)
        XCTAssertFalse(answerText(events).contains("MEMORY_SAVED_OK"))
        XCTAssertTrue(toolCallNames(events).isEmpty)
        let facts = await memory.list()
        XCTAssertTrue(facts.isEmpty)
        XCTAssertEqual(engine.receivedSamplings().map(\.maxTokens), [Sampling().maxTokens, 384])
        XCTAssertTrue(engine.receivedSamplings().allSatisfy { !$0.thinking })
    }

    func testPreToolSuccessProseIsDiscardedBeforeInvalidRememberCorrection() async throws {
        let memory = FakeMemoryStore()
        let engine = TurnScriptedEngine([
            #"Saved successfully. <tool_call>{"name":"remember","arguments":{"text":"用户叫 Dong"}}</tool_call>"#,
            #"<tool_call>{"name":"remember","arguments":{"text":"The user is named Dong."}}</tool_call>"#,
            "Actually saved.",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: ToolRegistry([RememberTool(store: memory)])),
            "Please remember that my name is Dong."
        )

        XCTAssertEqual(answerText(events), "Actually saved.")
        XCTAssertFalse(answerText(events).contains("Saved successfully"),
                       "pre-tool prose is unverified control-pass output and must be discarded")
        let facts = await memory.list()
        XCTAssertEqual(facts.map(\.text), ["The user is named Dong."])
    }

    func testRememberWriteFailureIsTerminalAndPreToolClaimNeverLeaks() async throws {
        let registry = ToolRegistry([
            RememberTool(store: LoopFailingMemoryStore()),
            StubTool(name: ToolID.webSearch.rawValue, result: "SEARCH MUST NOT RUN"),
        ])
        let engine = TurnScriptedEngine([
            #"Saved successfully. <tool_call>{"name":"remember","arguments":{"text":"The user is named DiskFailure."}}</tool_call>"#,
            #"<tool_call>{"name":"web_search","arguments":{"query":"DiskFailure"}}</tool_call>"#,
            "MEMORY_SAVED_OK",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: registry),
            "Please remember that my name is DiskFailure."
        )

        XCTAssertEqual(engine.generateCallCount(), 1,
                       "every remember result, including a write error, ends tool selection")
        XCTAssertEqual(toolCallNames(events), [ToolID.remember.rawValue])
        XCTAssertEqual(answerText(events), RememberTool.rejectedMemoryReply)
        XCTAssertFalse(answerText(events).contains("Saved successfully"))
        XCTAssertFalse(toolCallNames(events).contains(ToolID.webSearch.rawValue))
        XCTAssertEqual(toolResults(events).count, 1)
        XCTAssertTrue(toolResults(events)[0].hasPrefix("Error:"))
    }

    func testExplicitMemoryTurnRejectsWebAndAllowsOneRememberCorrection() async throws {
        let memory = FakeMemoryStore()
        let registry = ToolRegistry([
            RememberTool(store: memory),
            StubTool(name: ToolID.webSearch.rawValue, result: "SEARCH MUST NOT RUN"),
        ])
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"web_search","arguments":{"query":"QuartzBoundary"}}</tool_call>"#,
            #"<tool_call>{"name":"remember","arguments":{"text":"The user is named QuartzBoundary."}}</tool_call>"#,
            "Saved now.",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: registry),
            "Please remember that my temporary name is QuartzBoundary."
        )

        XCTAssertEqual(toolCallNames(events), [ToolID.remember.rawValue],
                       "the first web call is rejected before execution")
        XCTAssertFalse(toolResults(events).contains("SEARCH MUST NOT RUN"))
        XCTAssertEqual(answerText(events), "Saved now.")
        let facts = await memory.list()
        XCTAssertEqual(facts.map(\.text), ["The user is named QuartzBoundary."])
    }

    func testExplicitMemoryTurnMalformedWebCannotCorrectIntoValidWeb() async throws {
        let memory = FakeMemoryStore()
        let registry = ToolRegistry([
            RememberTool(store: memory),
            StubTool(name: ToolID.webSearch.rawValue, result: "SEARCH MUST NOT RUN"),
        ])
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"web_search","arguments":{oops}}</tool_call>"#,
            #"<tool_call>{"name":"web_search","arguments":{"query":"QuartzBoundary"}}</tool_call>"#,
            "A third generation must never run.",
        ])

        let events = try await collectLoop(
            ToolLoop(engine: engine, registry: registry),
            "Please remember that my temporary name is QuartzBoundary."
        )

        XCTAssertEqual(engine.generateCallCount(), 2)
        XCTAssertTrue(toolCallNames(events).isEmpty, "neither web attempt may execute")
        XCTAssertFalse(toolResults(events).contains("SEARCH MUST NOT RUN"))
        XCTAssertEqual(answerText(events), RememberTool.rejectedMemoryReply)
        let facts = await memory.list()
        XCTAssertTrue(facts.isEmpty)
    }

    func testOrdinaryNoToolAnswerKeepsCallerMaxTokensButDisablesThinking() async throws {
        let engine = TurnScriptedEngine(["A deliberately ordinary tools-on answer."])
        let params = Sampling(temperature: 0.91, maxTokens: 777, thinking: true)

        let events = try await collectLoop(
            ToolLoop(engine: engine,
                     registry: ToolRegistry([StubTool(name: "probe", result: "unused")])),
            "Explain something without using a tool.",
            params: params
        )

        XCTAssertEqual(answerText(events), "A deliberately ordinary tools-on answer.")
        let sampling = try XCTUnwrap(engine.receivedSamplings().first)
        XCTAssertEqual(sampling.maxTokens, 777)
        XCTAssertEqual(sampling.temperature, 0)
        XCTAssertFalse(sampling.thinking)
    }

    func testMemoryIntentQuestionsAndFileSaveDoNotForceRememberCorrection() async throws {
        for prompt in [
            "Do you remember my name?",
            "What have you remembered?",
            "Please save this file.",
            "你记得我的名字吗？",
        ] {
            let memory = FakeMemoryStore()
            let engine = TurnScriptedEngine(["Here is a direct answer.", "A retry must never run."])
            let events = try await collectLoop(
                ToolLoop(engine: engine, registry: ToolRegistry([RememberTool(store: memory)])),
                prompt
            )

            XCTAssertEqual(engine.generateCallCount(), 1, prompt)
            XCTAssertEqual(answerText(events), "Here is a direct answer.", prompt)
            let facts = await memory.list()
            XCTAssertTrue(facts.isEmpty, prompt)
        }
    }

    func testExactDuplicateCallIsExecutedOnlyOnceThenFinalized() async throws {
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"probe","arguments":{"b":2,"a":1}}</tool_call>"#,
            #"<tool_call>{"name":"probe","arguments":{"a":1,"b":2}}</tool_call>"#,
            "Done after the duplicate was suppressed.",
        ])
        let events = try await collectLoop(
            ToolLoop(engine: engine,
                     registry: ToolRegistry([StubTool(name: "probe", result: "probe result")])),
            "run the probe"
        )

        XCTAssertEqual(toolCallNames(events), ["probe"],
                       "reordered JSON keys still describe the same call and must not execute twice")
        XCTAssertEqual(engine.generateCallCount(), 3)
        XCTAssertTrue(answerText(events).contains("Done after the duplicate"))
        XCTAssertFalse(engine.receivedSamplings().last?.thinking ?? true)
    }

    func testSameToolWithDifferentArgumentsCanStillChain() async throws {
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"web_search","arguments":{"query":"Vienna weather"}}</tool_call>"#,
            #"<tool_call>{"name":"web_search","arguments":{"query":"top news today"}}</tool_call>"#,
            "Here is your briefing.",
        ])
        let events = try await collectLoop(
            ToolLoop(engine: engine,
                     registry: ToolRegistry([StubTool(name: ToolID.webSearch.rawValue,
                                                     result: "search results")])),
            "Give me a daily briefing."
        )

        XCTAssertEqual(toolCallNames(events),
                       [ToolID.webSearch.rawValue, ToolID.webSearch.rawValue],
                       "the duplicate guard compares arguments, not just the tool name")
        XCTAssertEqual(engine.generateCallCount(), 3)
        XCTAssertTrue(answerText(events).contains("Here is your briefing."))
    }

    func testThreeToolBudgetEndsWithOneToolFreePass() async throws {
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"probe","arguments":{"step":1}}</tool_call>"#,
            #"<tool_call>{"name":"probe","arguments":{"step":2}}</tool_call>"#,
            #"<tool_call>{"name":"probe","arguments":{"step":3}}</tool_call>"#,
            #"<tool_call>{"name":"probe","arguments":{"step":4}}</tool_call>"#,
            "A fifth generation must never run.",
        ])
        let events = try await collectLoop(
            ToolLoop(engine: engine,
                     registry: ToolRegistry([StubTool(name: "probe", result: "ok")]),
                     maxIterations: 3),
            "run several steps"
        )

        XCTAssertEqual(toolCallNames(events), ["probe", "probe", "probe"])
        XCTAssertEqual(engine.generateCallCount(), 4,
                       "three executions plus one answer-only pass; never the old fifth generation")
        XCTAssertTrue(answerText(events).contains(ToolPrompt.missingFinalAnswer))
        XCTAssertFalse(engine.receivedSamplings().last?.thinking ?? true)
    }

    func testCorrectionConsumesTheSameFourPassBudget() async throws {
        let engine = TurnScriptedEngine([
            #"<tool_call>{"name":"probe","arguments":{oops}}</tool_call>"#,
            #"<tool_call>{"name":"probe","arguments":{"step":1}}</tool_call>"#,
            #"<tool_call>{"name":"probe","arguments":{"step":2}}</tool_call>"#,
            #"<tool_call>{"name":"probe","arguments":{"step":3}}</tool_call>"#,
            "A fifth generation must never run.",
        ])
        let events = try await collectLoop(
            ToolLoop(engine: engine,
                     registry: ToolRegistry([StubTool(name: "probe", result: "ok")]),
                     maxIterations: 3),
            "run several steps"
        )

        XCTAssertEqual(toolCallNames(events), ["probe", "probe"],
                       "the correction pass consumes one slot from the shared generation budget")
        XCTAssertEqual(engine.generateCallCount(), 4,
                       "one correction, two tools, one final synthesis — never five prefills")
        XCTAssertTrue(answerText(events).contains(ToolPrompt.missingFinalAnswer))
        XCTAssertFalse(engine.receivedSamplings().last?.thinking ?? true)
    }

    func testToolPromptAsksForDirectlyRelevantMinimumCalls() {
        let block = ToolPrompt.systemBlock(
            [StubTool(name: "probe", result: "ok").schema],
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(block.contains("minimum number of tools"))
        XCTAssertTrue(block.contains("latest user request or active skill"))
        XCTAssertTrue(block.contains("never choose a new tool"))
    }
}

private actor LoopFailingMemoryStore: MemoryStoring {
    private struct WriteFailure: LocalizedError {
        var errorDescription: String? { "Injected durable write failure" }
    }

    func save(_ text: String, source: MemoryFact.Source) throws -> MemoryFact { throw WriteFailure() }
    func saveIfAbsent(_ text: String, source: MemoryFact.Source) throws -> MemorySaveResult {
        throw WriteFailure()
    }
    func list() -> [MemoryFact] { [] }
    func update(id: String, text: String) throws { throw WriteFailure() }
    func delete(id: String) throws { throw WriteFailure() }
    func deleteAll() throws { throw WriteFailure() }
}
