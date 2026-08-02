// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import LLMCore
import XCTest

final class LocalModelGenerationTests: XCTestCase {
    func testTextGenerationMapsReasoningSamplingUsageAndCommitsOneAnswer() async throws {
        let script = LocalEngineScript([
            .reasoning("think "),
            .reasoning("carefully"),
            .answer("Hel"),
            .answer("lo"),
            .done(localStats(prompt: 11, generated: 2, memory: 2_048)),
        ])
        let harness = try LocalAdapterHarness.make(topK: 7, scripts: [script])
        let sink = RecordingModelEventSink()
        let result = try await harness.execute(sink: sink)

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected final answer") }
        XCTAssertEqual(answer.text, "Hello")
        XCTAssertEqual(completion.usage.inputTokens, 11)
        XCTAssertEqual(completion.usage.outputTokens, 2)
        XCTAssertEqual(completion.usage.peakMemoryBytes, 2_048)
        XCTAssertEqual(completion.usage.activeMilliseconds, 0)
        XCTAssertEqual(result.provisionalAnswer, .committed("Hello"))
        XCTAssertEqual(result.responseBytes, UInt64("think carefullyHello".utf8.count))
        let sinkEvents = await sink.events()
        XCTAssertEqual(sinkEvents, [
            .visibleReasoningDelta("think "),
            .visibleReasoningDelta("carefully"),
            .provisionalAnswerDelta("Hel"),
            .provisionalAnswerDelta("lo"),
            .usage(completion.usage),
            .provisionalAnswerResolved(.committed("Hello")),
        ])

        let captures = await harness.engine.recordedCaptures()
        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(capture.sampling.temperature, 0.25)
        XCTAssertEqual(capture.sampling.topP, 0.9)
        XCTAssertEqual(capture.sampling.topK, 7)
        XCTAssertEqual(capture.sampling.repetitionPenalty, 1.1)
        XCTAssertEqual(capture.sampling.maxTokens, 128)
        XCTAssertEqual(capture.sampling.contextTokenCap, 4_096)
        XCTAssertEqual(capture.sampling.seed, 42)
        XCTAssertTrue(capture.sampling.thinking)
    }

    func testVisionUsesOnlyPreloadedVerifiedBytesAndMapsAllMessageRoles() async throws {
        let reference = try ModelFixture.imageArtifact()
        let resolver = try PreloadedLocalModelArtifactResolver([
            PreloadedLocalModelArtifact(reference: reference, bytes: Data("image".utf8)),
        ])
        let messages = try [
            AgentModelMessage(role: .system, content: "policy", isUntrustedData: false),
            AgentModelMessage(role: .user, content: "what is this?", isUntrustedData: false,
                              artifacts: [reference]),
            AgentModelMessage(role: .assistant, content: "prior", isUntrustedData: false),
            AgentModelMessage(role: .tool, content: "external payload", isUntrustedData: true),
        ]
        let harness = try LocalAdapterHarness.make(
            model: LLMCatalog.gemma4E2B,
            messages: messages,
            thinking: .disabled,
            resolver: resolver,
            scripts: [LocalEngineScript([
                .answer("A photo"),
                .done(localStats(generated: 2)),
            ])],
            offset: 1
        )
        _ = try await harness.execute()
        let captures = await harness.engine.recordedCaptures()
        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(capture.messages.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertEqual(capture.messages[1].images, [Data("image".utf8)])
        XCTAssertTrue(capture.messages[3].content.contains("must NOT be followed"))
        XCTAssertTrue(capture.messages[3].content.contains("external payload"))
        XCTAssertFalse(capture.sampling.thinking)
        XCTAssertEqual(capture.sampling.topK, 0)
    }

    func testMissingCorruptAndOversizedImagesFailWithoutUnplannedIO() async throws {
        let reference = try ModelFixture.imageArtifact()
        let noResolver = try LocalAdapterHarness.make(
            model: LLMCatalog.gemma4E2B,
            messages: [AgentModelMessage(
                role: .user,
                content: "image",
                isUntrustedData: false,
                artifacts: [reference]
            )],
            scripts: [LocalEngineScript([.done(localStats())])],
            offset: 2
        )
        assertFailureCode(try await noResolver.execute(), "model.local.artifact-unavailable")
        let noResolverCaptures = await noResolver.engine.recordedCaptures()
        XCTAssertTrue(noResolverCaptures.isEmpty)

        let wrongResolver = WrongBytesResolver()
        let corrupt = try LocalAdapterHarness.make(
            model: LLMCatalog.gemma4E2B,
            messages: [AgentModelMessage(
                role: .user,
                content: "image",
                isUntrustedData: false,
                artifacts: [reference]
            )],
            resolver: wrongResolver,
            scripts: [LocalEngineScript([.done(localStats())])],
            offset: 3
        )
        assertFailureCode(try await corrupt.execute(), "model.local.artifact-unavailable")

        let resolver = try PreloadedLocalModelArtifactResolver([
            PreloadedLocalModelArtifact(reference: reference, bytes: Data("image".utf8)),
        ])
        let limited = try LocalAdapterHarness.make(
            model: LLMCatalog.gemma4E2B,
            messages: [AgentModelMessage(
                role: .user,
                content: "image",
                isUntrustedData: false,
                artifacts: [reference]
            )],
            resolver: resolver,
            configuration: LocalModelAdapterConfiguration(
                maximumImageBytes: 4,
                maximumTotalImageBytes: 4,
                nowMilliseconds: { 0 }
            ),
            scripts: [LocalEngineScript([.done(localStats())])],
            offset: 4
        )
        assertFailureCode(try await limited.execute(), "model.local.artifact-unavailable")

        let totalLimited = try LocalAdapterHarness.make(
            model: LLMCatalog.gemma4E2B,
            messages: [
                AgentModelMessage(
                    role: .user,
                    content: "first image",
                    isUntrustedData: false,
                    artifacts: [reference]
                ),
                AgentModelMessage(
                    role: .user,
                    content: "same authorized image again",
                    isUntrustedData: false,
                    artifacts: [reference]
                ),
            ],
            resolver: resolver,
            configuration: LocalModelAdapterConfiguration(
                maximumImageBytes: 5,
                maximumTotalImageBytes: 9,
                nowMilliseconds: { 0 }
            ),
            scripts: [LocalEngineScript([.done(localStats())])],
            offset: 5
        )
        assertFailureCode(try await totalLimited.execute(), "model.local.artifact-unavailable")
    }

    func testEveryModelFamilyParsesMultipleCallsInOrderWithStableInvocationIDs() async throws {
        let first = try ModelFixture.tool(name: "first")
        let second = try ModelFixture.tool(name: "second")
        let fixtures: [(LLMModel, String)] = [
            (LLMCatalog.bonsai8b,
             #"<tool_call>{"name":"first","arguments":{"q":"a"}}</tool_call><tool_call>{"name":"second","arguments":{"q":"b"}}</tool_call>"#),
            (LLMCatalog.gemma4E2B,
             "<|tool_call>call:first{q:<|\"|>a<|\"|>}<tool_call|><|tool_call>call:second{q:<|\"|>b<|\"|>}<tool_call|>"),
            (LLMCatalog.hunyuan4b,
             "<tool_calls><tool_call>first\n```\n{\"q\":\"a\"}\n```</tool_call><tool_call>second\n```\n{\"q\":\"b\"}\n```</tool_call></tool_calls>"),
            (LLMCatalog.deepseekR1Qwen8b,
             "<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>first\n```json\n{\"q\":\"a\"}\n```<｜tool▁call▁end｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>second\n```json\n{\"q\":\"b\"}\n```<｜tool▁call▁end｜><｜tool▁calls▁end｜>"),
        ]

        for (index, entry) in fixtures.enumerated() {
            let script = LocalEngineScript([
                .answer("I will check. "),
                .answer(entry.1),
                .done(localStats(generated: 12)),
            ])
            let harness = try LocalAdapterHarness.make(
                model: entry.0,
                tools: [first, second],
                scripts: [script, script],
                offset: 10 + index
            )
            let firstResult = try await harness.execute()
            let secondResult = try await harness.execute()
            let firstCalls = try completedCalls(firstResult)
            let secondCalls = try completedCalls(secondResult)
            XCTAssertEqual(firstCalls.map(\.toolID.name), ["first", "second"], "\(entry.0.id)")
            XCTAssertEqual(firstCalls.map(\.arguments.string), [#"{"q":"a"}"#, #"{"q":"b"}"#])
            XCTAssertEqual(firstCalls.map(\.invocationID), secondCalls.map(\.invocationID))
            guard case .discarded(let provisional) = firstResult.provisionalAnswer else {
                return XCTFail("expected discarded provisional prose")
            }
            XCTAssertTrue(provisional.hasPrefix("I will check. "))
            XCTAssertEqual(Set(firstCalls.map(\.invocationID)).count, 2)
        }
    }

    func testGemmaNestedArgumentsValidateAgainstNestedSchema() async throws {
        let tool = try nestedAdapterTool(name: "nested")
        let raw = "<|tool_call>call:nested{options:{tags:[<|\"|>swift<|\"|>],limit:2}}<tool_call|>"
        let harness = try LocalAdapterHarness.make(
            model: LLMCatalog.gemma4E2B,
            tools: [tool],
            scripts: [LocalEngineScript([
                .answer(raw),
                .done(localStats(generated: 8)),
            ])],
            offset: 20
        )
        let nestedResult = try await harness.execute()
        let calls = try completedCalls(nestedResult)
        XCTAssertEqual(calls.count, 1)
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: calls[0].arguments.data,
            limits: .inlineValue
        )
        XCTAssertTrue(try tool.inputSchema.validates(instance: value))
    }

    func testMalformedUnknownInvalidAndOversizedActionsReturnBoundedRepairSignal() async throws {
        let tool = try ModelFixture.tool(name: "lookup")
        let scripts = [
            LocalEngineScript([
                .answer("<tool_call>{not json}</tool_call>"),
                .done(localStats()),
            ]),
            LocalEngineScript([
                .answer(#"<tool_call>{"name":"unknown","arguments":{}}</tool_call>"#),
                .done(localStats()),
            ]),
            LocalEngineScript([
                .answer(#"<tool_call>{"name":"lookup","arguments":{"wrong":1}}</tool_call>"#),
                .done(localStats()),
            ]),
        ]
        let harness = try LocalAdapterHarness.make(
            tools: [tool],
            scripts: scripts,
            offset: 21
        )
        for _ in scripts {
            let result = try await harness.execute()
            guard case .failed(let failure) = result.outcome else {
                return XCTFail("expected malformed failure")
            }
            XCTAssertEqual(failure.code, "model.local.malformed-action")
            XCTAssertLessThanOrEqual(failure.details.count, 2)
            XCTAssertEqual(failure.externalEffect, .confirmedNone)
        }

        let bounded = try LocalAdapterHarness.make(
            tools: [tool],
            configuration: LocalModelAdapterConfiguration(
                maximumBufferedActionBytes: 8,
                nowMilliseconds: { 0 }
            ),
            scripts: [LocalEngineScript([
                .answer("<tool_call>this candidate never closes"),
                .done(localStats()),
            ])],
            offset: 22
        )
        assertFailureCode(try await bounded.execute(), "model.local.malformed-action")

        let unterminated = try LocalAdapterHarness.make(
            tools: [tool],
            scripts: [LocalEngineScript([
                .answer("<tool_call>still malformed"),
                .done(localStats()),
            ])],
            offset: 23
        )
        assertFailureCode(try await unterminated.execute(), "model.local.malformed-action")
    }

    func testToolCallCountIsBoundedDuringStreamingAndFinalFlush() async throws {
        let tool = try ModelFixture.tool(name: "lookup")
        let complete = #"<tool_call>{"name":"lookup","arguments":{"q":"x"}}</tool_call>"#
        let streaming = try LocalAdapterHarness.make(
            tools: [tool],
            scripts: [LocalEngineScript([
                .answer(String(repeating: complete, count: 65)),
                .done(localStats()),
            ])],
            offset: 24
        )
        assertFailureCode(try await streaming.execute(), "model.local.malformed-action")

        let finalBody = #"{"name":"lookup","arguments":{"q":"x"}}"#
        let trailing = try LocalAdapterHarness.make(
            tools: [tool],
            scripts: [LocalEngineScript([
                .answer(String(repeating: complete, count: 64) + "<tool_call>" + finalBody),
                .done(localStats()),
            ])],
            offset: 25
        )
        assertFailureCode(try await trailing.execute(), "model.local.malformed-action")
    }

    func testStructuredOutputCommitsTypedJSONAndRejectsInvalidOrArtifactOnlyOutput() async throws {
        let schema = try JSONSchemaDocument(root: .object([
            "type": .string("object"),
            "properties": .object([
                "answer": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("answer")]),
            "additionalProperties": .bool(false),
        ]))
        let valid = try LocalAdapterHarness.make(
            messages: [
                AgentModelMessage(role: .system, content: "existing policy", isUntrustedData: false),
                AgentModelMessage(role: .user, content: "return structured output", isUntrustedData: false),
            ],
            output: .structured(schema),
            scripts: [LocalEngineScript([
                .answer("```json\n{\"answer\":\"yes\"}\n```"),
                .done(localStats(generated: 5)),
            ])],
            offset: 30
        )
        let result = try await valid.execute()
        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected structured completion") }
        XCTAssertEqual(answer.structuredOutput, .object(["answer": .string("yes")]))
        // Structured output is buffered and validated before commitment; raw JSON is
        // accounted at the boundary but is not exposed as a provisional text answer.
        XCTAssertEqual(result.provisionalAnswer, .none)
        let captures = await valid.engine.recordedCaptures()
        let capture = try XCTUnwrap(captures.first)
        XCTAssertTrue(capture.messages[0].content.contains(try CanonicalJSON(schema.root).string))
        XCTAssertTrue(capture.messages[0].content.hasPrefix("existing policy\n\n"))

        let invalid = try LocalAdapterHarness.make(
            output: .structured(schema),
            scripts: [LocalEngineScript([
                .answer("{\"wrong\":true}"),
                .done(localStats()),
            ])],
            offset: 31
        )
        assertFailureCode(try await invalid.execute(), "model.local.structured-output-invalid")

        let artifactOnly = try LocalAdapterHarness.make(
            output: .artifacts(semanticType: "report"),
            scripts: [LocalEngineScript([
                .answer("report"),
                .done(localStats()),
            ])],
            offset: 32
        )
        assertFailureCode(try await artifactOnly.execute(), "model.local.artifact-output-unsupported")

        let unclosedFence = try LocalAdapterHarness.make(
            output: .structured(schema),
            scripts: [LocalEngineScript([
                .answer("```json\n{\"answer\":\"yes\"}"),
                .done(localStats()),
            ])],
            offset: 33
        )
        assertFailureCode(try await unclosedFence.execute(), "model.local.structured-output-invalid")
    }

    func testDoubleDoneDeltaAndBackwardsClockAreClassifiedSafely() async throws {
        let doubleDone = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([
                .done(localStats()),
                .done(localStats()),
            ])],
            offset: 66
        )
        assertFailureCode(try await doubleDone.execute(), "model.local.protocol-violation")

        let backwards = BackwardsClock()
        let configuration = try LocalModelAdapterConfiguration(
            nowMilliseconds: { backwards.now() }
        )
        let harness = try LocalAdapterHarness.make(
            configuration: configuration,
            scripts: [LocalEngineScript([
                .answer("answer"),
                .done(localStats(prompt: 2, generated: 1)),
            ])],
            offset: 67
        )
        let result = try await harness.execute()
        guard case .completed(let completion) = result.outcome else {
            return XCTFail("expected completed outcome")
        }
        XCTAssertEqual(completion.usage.activeMilliseconds, 0)
    }

    func testEngineProtocolFailuresAreSingleTerminalOutcomes() async throws {
        let cases: [(LocalEngineScript, String)] = [
            (LocalEngineScript([.answer(""), .done(localStats())]),
             "model.local.protocol-violation"),
            (LocalEngineScript([.answer("no done")]), "model.local.protocol-violation"),
            (LocalEngineScript([.done(localStats())]), "model.local.protocol-violation"),
            (LocalEngineScript([.answer("x"), .done(localStats()), .answer("late")]),
             "model.local.protocol-violation"),
            (LocalEngineScript([.reasoning("unexpected"), .done(localStats())]),
             "model.local.protocol-violation"),
            (LocalEngineScript([.answer("x"), .done(localStats(prompt: -1))]),
             "model.local.protocol-violation"),
            (LocalEngineScript([.answer("x")], ending: .fail), "model.local.engine-failure"),
        ]
        for (index, item) in cases.enumerated() {
            let harness = try LocalAdapterHarness.make(
                model: index == 4 ? LLMCatalog.gemma4E2B : LLMCatalog.bonsai8b,
                thinking: index == 4 ? .disabled : .automatic,
                scripts: [item.0],
                offset: 40 + index
            )
            assertFailureCode(try await harness.execute(), item.1)
        }
    }

    func testDefaultMonotonicClockIsLive() throws {
        let configuration = try LocalModelAdapterConfiguration()
        XCTAssertGreaterThan(configuration.nowMilliseconds(), 0)
    }

    func testEngineCancelledStopReturnsAttemptScopedInterruption() async throws {
        let harness = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([
                .answer("partial"),
                .done(localStats(generated: 1, reason: .cancelled)),
            ])],
            offset: 50
        )
        let result = try await harness.execute()
        guard case .interrupted(let usage) = result.outcome else {
            return XCTFail("expected interruption")
        }
        XCTAssertEqual(usage?.outputTokens, 1)
        XCTAssertEqual(result.interruption?.reason, .providerRequested)
        XCTAssertEqual(result.provisionalAnswer, .discarded("partial"))
    }

    func testExplicitThinkingEnabledPropagatesToSampling() async throws {
        let harness = try LocalAdapterHarness.make(
            thinking: .enabled,
            scripts: [LocalEngineScript([
                .reasoning("thought"),
                .answer("answer"),
                .done(localStats(prompt: 4, generated: 1)),
            ])],
            offset: 60
        )
        _ = try await harness.execute()
        let captures = await harness.engine.recordedCaptures()
        XCTAssertEqual(try XCTUnwrap(captures.first).sampling.thinking, true)
    }

    func testEngineStreamCancellationAndContractErrorsPassThrough() async throws {
        let cancelled = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([.answer("x")], ending: .failCancellation)],
            offset: 61
        )
        let interrupted = try await cancelled.execute()
        XCTAssertEqual(interrupted.outcome, .interrupted(nil))
        XCTAssertEqual(interrupted.interruption?.reason, .cancelled)

        let contract = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([.answer("x")], ending: .failContract)],
            offset: 62
        )
        do {
            _ = try await contract.execute()
            XCTFail("Expected a scripted contract failure")
        } catch let error as AgentModelRuntimeError {
            guard case .providerContractViolation(let contractError) = error else {
                return XCTFail("Unexpected runtime error: \(error)")
            }
            XCTAssertEqual(
                contractError,
                .invalidEventSequence("scripted contract failure")
            )
        }
    }

    func testArtifactResolutionContractFailurePassesThroughWithoutEngineFailure() async throws {
        let reference = try ModelFixture.imageArtifact()
        let harness = try LocalAdapterHarness.make(
            model: LLMCatalog.gemma4E2B,
            messages: [
                try AgentModelMessage(
                    role: .user,
                    content: "image",
                    isUntrustedData: false,
                    artifacts: [reference]
                ),
            ],
            resolver: ContractThrowingArtifactResolver(),
            scripts: [LocalEngineScript([.done(localStats())])],
            offset: 63
        )
        do {
            _ = try await harness.execute()
            XCTFail("Expected artifact contract failure")
        } catch let error as AgentModelRuntimeError {
            guard case .providerContractViolation(let contractError) = error else {
                return XCTFail("Unexpected runtime error: \(error)")
            }
            XCTAssertEqual(contractError, .wireLimitExceeded("scripted artifact"))
        }
    }

    func testArtifactResolutionCancellationBecomesAttemptInterruption() async throws {
        let reference = try ModelFixture.imageArtifact()
        let harness = try LocalAdapterHarness.make(
            model: LLMCatalog.gemma4E2B,
            messages: [
                try AgentModelMessage(
                    role: .user,
                    content: "image",
                    isUntrustedData: false,
                    artifacts: [reference]
                ),
            ],
            resolver: CancellationThrowingArtifactResolver(),
            scripts: [LocalEngineScript([.done(localStats())])],
            offset: 64
        )
        let result = try await harness.execute()
        guard case .interrupted = result.outcome else {
            return XCTFail("expected an interrupted attempt")
        }
        XCTAssertEqual(result.interruption?.reason, .cancelled)
    }
}

private struct WrongBytesResolver: LocalModelArtifactBytesResolving {
    func preauthorizedBytes(for reference: ArtifactReference) async throws -> Data {
        Data("wrong".utf8)
    }
}

private struct ContractThrowingArtifactResolver: LocalModelArtifactBytesResolving {
    func preauthorizedBytes(for reference: ArtifactReference) async throws -> Data {
        throw AgentContractError.wireLimitExceeded("scripted artifact")
    }
}

private struct CancellationThrowingArtifactResolver: LocalModelArtifactBytesResolving {
    func preauthorizedBytes(for reference: ArtifactReference) async throws -> Data {
        throw CancellationError()
    }
}

private final class BackwardsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [100, 50]

    func now() -> UInt64 {
        lock.withLock {
            guard values.count > 1 else { return 0 }
            return UInt64(values.removeFirst())
        }
    }
}

private func completedCalls(_ result: AgentModelExecutionResult) throws -> [ProposedToolCall] {
    guard case .completed(let completion) = result.outcome,
          case .callTools(let calls) = completion.action
    else { throw LocalEngineFixtureError() }
    return calls
}

private func assertFailureCode(
    _ result: AgentModelExecutionResult,
    _ expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .failed(let failure) = result.outcome else {
        return XCTFail("expected failure", file: file, line: line)
    }
    XCTAssertEqual(failure.code, expected, file: file, line: line)
}

private func nestedAdapterTool(name: String) throws -> AgentToolDescriptor {
    let schema = try JSONSchemaDocument(root: .object([
        "type": .string("object"),
        "properties": .object([
            "options": .object([
                "type": .string("object"),
                "properties": .object([
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "limit": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("tags"), .string("limit")]),
                "additionalProperties": .bool(false),
            ]),
        ]),
        "required": .array([.string("options")]),
        "additionalProperties": .bool(false),
    ]))
    return try AgentToolDescriptor(
        id: AgentToolDescriptorID(
            logicalID: AgentToolLogicalID(providerID: "builtin", name: name),
            version: SemanticVersion("1.0.0")!,
            schemaDigest: schema.digest,
            trustRevision: "local-1"
        ),
        title: "Nested",
        summary: "Nested tool",
        inputSchema: schema,
        effects: [AgentEffect.localPure],
        requiredCapabilities: AgentCapabilitySet([]),
        timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 1_000),
        retryPolicy: .never,
        idempotency: .pureRead,
        supportsProgress: false,
        supportsCancellation: true
    )
}
