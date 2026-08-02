// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import XCTest

final class AgentModelExecutorTests: XCTestCase {
    func testAuthorizedExecutionCommitsMatchingStreamedAnswerAndUsage() async throws {
        let fixture = try ModelFixture()
        let firstUsage = try modelUsage(output: 1)
        let finalUsage = try modelUsage(output: 2, milliseconds: 20, memory: 120)
        let completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "Hello")),
            usage: finalUsage
        )
        let outcome = AgentModelAttemptOutcome.completed(completion)
        let digest = StableDigest.sha256(Data("complete-response".utf8))
        let provider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [
                ScriptedEmission(.reasoningDelta("Checking"), responseBytes: 2),
                ScriptedEmission(.answerDelta("Hel"), responseBytes: 3),
                ScriptedEmission(.answerDelta("lo"), responseBytes: 2),
                ScriptedEmission(.usage(firstUsage), responseBytes: 1),
                ScriptedEmission(.completed(completion), responseBytes: 4),
            ],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: outcome, responseDigest: digest)
            )
        )
        let authorized = try await fixture.authorized(provider: provider)
        let sink = RecordingModelEventSink()

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized,
            eventSink: sink
        )

        XCTAssertEqual(result.outcome, outcome)
        XCTAssertNil(result.interruption)
        XCTAssertEqual(result.provisionalAnswer, .committed("Hello"))
        XCTAssertEqual(result.responseBytes, 12)
        XCTAssertEqual(result.responseDigest, digest)
        let invocationCount = await provider.invocationCounter.count()
        let recordedEvents = await sink.events()
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(
            recordedEvents,
            [
                .visibleReasoningDelta("Checking"),
                .provisionalAnswerDelta("Hel"),
                .provisionalAnswerDelta("lo"),
                .usage(firstUsage),
                .provisionalAnswerResolved(.committed("Hello")),
            ]
        )
    }

    func testToolAndUserInputActionsDiscardProvisionalProse() async throws {
        let descriptor = try ModelFixture.tool()
        let toolFixture = try ModelFixture(
            features: AgentModelCapabilitySet([.textToolDialect]),
            toolCallingMode: .textDialect,
            advertisedTools: [descriptor]
        )
        let arguments = try CanonicalJSON(.object(["q": .string("weather")]))
        let call = ProposedToolCall(
            invocationID: ToolInvocationID(rawValue: ModelFixture.uuid(20)),
            toolID: descriptor.id.logicalID,
            arguments: arguments
        )
        let usage = try modelUsage()
        let toolCompletion = try AgentModelCompletion(
            action: .callTools([call]),
            usage: usage
        )
        let toolProvider = ScriptedModelProvider(
            descriptor: toolFixture.descriptor,
            capabilities: toolFixture.capabilities,
            emissions: [
                ScriptedEmission(.answerDelta("Let me check.")),
                ScriptedEmission(.toolCalls([call])),
                ScriptedEmission(.completed(toolCompletion)),
            ],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .completed(toolCompletion))
            )
        )
        let toolResult = try await AgentModelExecutor().execute(
            provider: toolProvider,
            authorized: try await toolFixture.authorized(provider: toolProvider)
        )
        XCTAssertEqual(toolResult.provisionalAnswer, .discarded("Let me check."))
        XCTAssertEqual(toolResult.outcome, .completed(toolCompletion))

        let inputFixture = try ModelFixture(offset: 1)
        let interaction = try UserInputRequest(
            id: InteractionRequestID(rawValue: ModelFixture.uuid(30)),
            runID: inputFixture.request.runID,
            prompt: "Which city?",
            creationStateVersion: 2
        )
        let inputCompletion = try AgentModelCompletion(
            action: .requestUserInput(interaction),
            usage: usage
        )
        let inputProvider = ScriptedModelProvider(
            descriptor: inputFixture.descriptor,
            capabilities: inputFixture.capabilities,
            emissions: [
                ScriptedEmission(.answerDelta("I need one detail.")),
                ScriptedEmission(.requestUserInput(interaction)),
                ScriptedEmission(.completed(inputCompletion)),
            ],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .completed(inputCompletion))
            )
        )
        let inputResult = try await AgentModelExecutor().execute(
            provider: inputProvider,
            authorized: try await inputFixture.authorized(provider: inputProvider)
        )
        XCTAssertEqual(inputResult.provisionalAnswer, .discarded("I need one detail."))
        XCTAssertEqual(inputResult.outcome, .completed(inputCompletion))
    }

    func testTerminalAndThrownFailuresBecomeTypedFailedAttempts() async throws {
        let fixture = try ModelFixture()
        let failure = try modelFailure()
        let terminalProvider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [
                ScriptedEmission(.answerDelta("Partial")),
                ScriptedEmission(.failed(failure)),
            ],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .failed(failure))
            )
        )
        let terminal = try await AgentModelExecutor().execute(
            provider: terminalProvider,
            authorized: try await fixture.authorized(provider: terminalProvider)
        )
        XCTAssertEqual(terminal.outcome, .failed(failure))
        XCTAssertEqual(terminal.provisionalAnswer, .discarded("Partial"))
        XCTAssertNil(terminal.responseDigest)

        let thrownProvider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [ScriptedEmission(.answerDelta("Uncommitted"))],
            termination: .providerFailure(failure)
        )
        let thrown = try await AgentModelExecutor().execute(
            provider: thrownProvider,
            authorized: try await fixture.authorized(provider: thrownProvider)
        )
        XCTAssertEqual(thrown.outcome, .failed(failure))
        XCTAssertEqual(thrown.provisionalAnswer, .discarded("Uncommitted"))
        XCTAssertNil(thrown.responseBytes)

        let unknownProvider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            termination: .unknownFailure
        )
        let unknown = try await AgentModelExecutor().execute(
            provider: unknownProvider,
            authorized: try await fixture.authorized(provider: unknownProvider)
        )
        guard case .failed(let normalized) = unknown.outcome else {
            return XCTFail("Expected normalized failure")
        }
        XCTAssertEqual(normalized.code, "model.provider-runtime")
        XCTAssertEqual(normalized.classification, .transient)
        XCTAssertTrue(normalized.retryAdvice.automaticallyRetryable)
    }

    func testCancellationAndEveryInterruptionRemainAttemptScoped() async throws {
        let fixture = try ModelFixture()
        let cancellationProvider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [ScriptedEmission(.answerDelta("Partial"))],
            termination: .cancellation
        )
        let cancelled = try await AgentModelExecutor().execute(
            provider: cancellationProvider,
            authorized: try await fixture.authorized(provider: cancellationProvider)
        )
        guard case .interrupted = cancelled.outcome else {
            return XCTFail("Expected interrupted attempt")
        }
        XCTAssertEqual(cancelled.interruption?.reason, .cancelled)
        XCTAssertEqual(cancelled.interruption?.failure.classification, .cancelled)
        XCTAssertEqual(cancelled.provisionalAnswer, .discarded("Partial"))

        let usage = try modelUsage(output: 3)
        for reason in [
            AgentModelInterruptionReason.lifecycleQuiescence,
            .resourcePressure,
        ] {
            let provider = ScriptedModelProvider(
                descriptor: fixture.descriptor,
                capabilities: fixture.capabilities,
                emissions: [ScriptedEmission(.usage(usage))],
                termination: .interruption(reason)
            )
            let result = try await AgentModelExecutor().execute(
                provider: provider,
                authorized: try await fixture.authorized(provider: provider)
            )
            XCTAssertEqual(result.outcome, .interrupted(usage))
            XCTAssertEqual(result.interruption?.reason, reason)
            XCTAssertEqual(
                result.interruption?.failure.classification,
                reason == .resourcePressure ? .budgetRelated : .transient
            )
            XCTAssertEqual(result.provisionalAnswer, .none)
        }

        let boundaryProvider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [ScriptedEmission(.usage(usage), responseBytes: 9)],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .interrupted(usage))
            )
        )
        let boundary = try await AgentModelExecutor().execute(
            provider: boundaryProvider,
            authorized: try await fixture.authorized(provider: boundaryProvider)
        )
        XCTAssertEqual(boundary.outcome, .interrupted(usage))
        XCTAssertEqual(boundary.interruption?.reason, .providerRequested)
        XCTAssertEqual(boundary.interruption?.failure.classification, .transient)
        XCTAssertEqual(boundary.responseBytes, 9)
    }

    func testMalformedTerminalActionAndPostTerminalEventsFailClosed() async throws {
        let fixture = try ModelFixture()
        let usage = try modelUsage()
        let completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "done")),
            usage: usage
        )
        let malformed: [[ScriptedEmission]] = [
            [],
            [
                ScriptedEmission(.completed(completion)),
                ScriptedEmission(.usage(usage)),
            ],
        ]
        for emissions in malformed {
            let provider = ScriptedModelProvider(
                descriptor: fixture.descriptor,
                capabilities: fixture.capabilities,
                emissions: emissions,
                termination: .completion(
                    AgentModelBoundaryCompletion(outcome: .completed(completion))
                )
            )
            await assertExecutionError {
                _ = try await AgentModelExecutor().execute(
                    provider: provider,
                    authorized: try await fixture.authorized(provider: provider)
                )
            }
        }

        let tool = try ModelFixture.tool()
        let toolFixture = try ModelFixture(
            features: AgentModelCapabilitySet([.textToolDialect]),
            toolCallingMode: .textDialect,
            advertisedTools: [tool]
        )
        let call = ProposedToolCall(
            invocationID: ToolInvocationID(rawValue: ModelFixture.uuid(41)),
            toolID: tool.id.logicalID,
            arguments: try CanonicalJSON(.object(["q": .string("x")]))
        )
        let conflicting = ScriptedModelProvider(
            descriptor: toolFixture.descriptor,
            capabilities: toolFixture.capabilities,
            emissions: [
                ScriptedEmission(.toolCalls([call])),
                ScriptedEmission(.completed(completion)),
            ],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .completed(completion))
            )
        )
        await assertExecutionError {
            _ = try await AgentModelExecutor().execute(
                provider: conflicting,
                authorized: try await toolFixture.authorized(provider: conflicting)
            )
        }
    }

    func testProvisionalMismatchUsageRegressionAndReasoningViolationFailClosed() async throws {
        let fixture = try ModelFixture()
        let low = try modelUsage(output: 2, milliseconds: 20, memory: 200)
        let regressed = try modelUsage(output: 1, milliseconds: 10, memory: 100)
        let final = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "different")),
            usage: low
        )
        let cases: [ScriptedModelProvider] = [
            ScriptedModelProvider(
                descriptor: fixture.descriptor,
                capabilities: fixture.capabilities,
                emissions: [
                    ScriptedEmission(.answerDelta("streamed")),
                    ScriptedEmission(.completed(final)),
                ],
                termination: .completion(
                    AgentModelBoundaryCompletion(outcome: .completed(final))
                )
            ),
            ScriptedModelProvider(
                descriptor: fixture.descriptor,
                capabilities: fixture.capabilities,
                emissions: [
                    ScriptedEmission(.usage(low)),
                    ScriptedEmission(.usage(regressed)),
                ],
                termination: .completion(
                    AgentModelBoundaryCompletion(outcome: .interrupted(regressed))
                )
            ),
        ]
        for provider in cases {
            await assertExecutionError {
                _ = try await AgentModelExecutor().execute(
                    provider: provider,
                    authorized: try await fixture.authorized(provider: provider)
                )
            }
        }

        let noReasoning = try ModelFixture(
            features: AgentModelCapabilitySet([]),
            thinkingMode: .disabled,
            offset: 2
        )
        let provider = ScriptedModelProvider(
            descriptor: noReasoning.descriptor,
            capabilities: noReasoning.capabilities,
            emissions: [ScriptedEmission(.reasoningDelta("not allowed"))],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .interrupted(nil))
            )
        )
        await assertExecutionError {
            _ = try await AgentModelExecutor().execute(
                provider: provider,
                authorized: try await noReasoning.authorized(provider: provider)
            )
        }
    }

    func testUsageBoundsCostAndMultipleToolCapabilityAreEnforced() async throws {
        let fixture = try ModelFixture()
        let invalidUsage = [
            try modelUsage(input: 4_097),
            try modelUsage(output: 1_025),
            try modelUsage(cost: 1, currency: "USD"),
        ]
        for usage in invalidUsage {
            let provider = ScriptedModelProvider(
                descriptor: fixture.descriptor,
                capabilities: fixture.capabilities,
                emissions: [ScriptedEmission(.usage(usage))],
                termination: .completion(
                    AgentModelBoundaryCompletion(outcome: .interrupted(usage))
                )
            )
            await assertExecutionError {
                _ = try await AgentModelExecutor().execute(
                    provider: provider,
                    authorized: try await fixture.authorized(provider: provider)
                )
            }
        }

        let first = try ModelFixture.tool(name: "one")
        let second = try ModelFixture.tool(name: "two")
        let toolFixture = try ModelFixture(
            features: AgentModelCapabilitySet([.textToolDialect]),
            toolCallingMode: .textDialect,
            advertisedTools: [first, second],
            offset: 3
        )
        let calls = try [first, second].enumerated().map { index, descriptor in
            ProposedToolCall(
                invocationID: ToolInvocationID(rawValue: ModelFixture.uuid(50 + index)),
                toolID: descriptor.id.logicalID,
                arguments: try CanonicalJSON(.object(["q": .string("x")]))
            )
        }
        let provider = ScriptedModelProvider(
            descriptor: toolFixture.descriptor,
            capabilities: toolFixture.capabilities,
            emissions: [ScriptedEmission(.toolCalls(calls))],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .interrupted(nil))
            )
        )
        await assertExecutionError {
            _ = try await AgentModelExecutor().execute(
                provider: provider,
                authorized: try await toolFixture.authorized(provider: provider)
            )
        }

        let capableFixture = try ModelFixture(
            features: AgentModelCapabilitySet([.textToolDialect, .multipleToolCalls]),
            toolCallingMode: .textDialect,
            advertisedTools: [first, second],
            offset: 4
        )
        let completion = try AgentModelCompletion(
            action: .callTools(calls),
            usage: modelUsage()
        )
        let capableProvider = ScriptedModelProvider(
            descriptor: capableFixture.descriptor,
            capabilities: capableFixture.capabilities,
            emissions: [ScriptedEmission(.completed(completion))],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .completed(completion))
            )
        )
        let capableResult = try await AgentModelExecutor().execute(
            provider: capableProvider,
            authorized: try await capableFixture.authorized(provider: capableProvider)
        )
        XCTAssertEqual(capableResult.outcome, .completed(completion))
    }

    func testLocalModelCannotReportUncertainExternalSideEffects() async throws {
        let fixture = try ModelFixture()
        let uncertain = try modelFailure(
            classification: .potentiallySideEffecting,
            effect: .uncertain
        )
        let terminal = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [ScriptedEmission(.failed(uncertain))],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .failed(uncertain))
            )
        )
        await assertExecutionError {
            _ = try await AgentModelExecutor().execute(
                provider: terminal,
                authorized: try await fixture.authorized(provider: terminal)
            )
        }

        let thrown = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            termination: .providerFailure(uncertain)
        )
        await assertExecutionError {
            _ = try await AgentModelExecutor().execute(
                provider: thrown,
                authorized: try await fixture.authorized(provider: thrown)
            )
        }
    }

    func testTOCTOURevocationAndClockRegressionPreventProviderStart() async throws {
        let fixture = try ModelFixture()
        let policy = TestApprovalPolicyEngine()
        let counter = ScriptedInvocationCounter()
        let provider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            invocationCounter: counter
        )
        let authorized = try await fixture.authorized(provider: provider, policy: policy)
        await policy.revoke()
        do {
            _ = try await AgentModelExecutor().execute(
                provider: provider,
                authorized: authorized
            )
            XCTFail("Expected revoked authorization")
        } catch AgentModelRuntimeError.authorizationRejected(.authorizationDenied) {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let revokedInvocationCount = await counter.count()
        XCTAssertEqual(revokedInvocationCount, 0)

        let clockCounter = ScriptedInvocationCounter()
        let clockProvider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            invocationCounter: clockCounter
        )
        let timeBound = try await fixture.authorized(
            provider: clockProvider,
            clock: FixedAuthorizationClock(999)
        )
        do {
            _ = try await AgentModelExecutor().execute(
                provider: clockProvider,
                authorized: timeBound
            )
            XCTFail("Expected not-yet-valid authorization")
        } catch AgentModelRuntimeError.authorizationRejected(.authorizationExpired) {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let clockInvocationCount = await clockCounter.count()
        XCTAssertEqual(clockInvocationCount, 0)
    }

    func testExecutorRejectsWrongProviderAndResponseByteExpansion() async throws {
        let fixture = try ModelFixture()
        let provider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities
        )
        let authorized = try await fixture.authorized(provider: provider)
        let other = try ModelFixture(offset: 8)
        let wrong = ScriptedModelProvider(
            descriptor: other.descriptor,
            capabilities: other.capabilities
        )
        do {
            _ = try await AgentModelExecutor().execute(
                provider: wrong,
                authorized: authorized
            )
            XCTFail("Expected exact provider pinning")
        } catch {
            XCTAssertEqual(error as? AgentModelRuntimeError, .executingWrongProvider)
        }

        let overflow = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [
                ScriptedEmission(
                    .answerDelta("x"),
                    responseBytes: fixture.context.maximumResponseBytes + 1
                ),
            ],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .interrupted(nil))
            )
        )
        await assertExecutionError {
            _ = try await AgentModelExecutor().execute(
                provider: overflow,
                authorized: try await fixture.authorized(provider: overflow)
            )
        }
    }
}

private func assertExecutionError(operation: () async throws -> Void) async {
    do {
        try await operation()
        XCTFail("Expected provider contract violation")
    } catch AgentModelRuntimeError.providerContractViolation {
        // Expected.
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}
