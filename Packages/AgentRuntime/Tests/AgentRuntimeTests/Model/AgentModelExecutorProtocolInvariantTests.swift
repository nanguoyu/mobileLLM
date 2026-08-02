// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import XCTest

final class AgentModelExecutorProtocolInvariantTests: XCTestCase {
    func testBoundaryOutcomeMustMatchTheAccumulatorTerminalEvent() async throws {
        let fixture = try ModelFixture(offset: 20)
        let usage = try modelUsage()
        let completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "done")),
            usage: usage
        )
        let failure = try modelFailure()

        let completedThenFailed = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [ScriptedEmission(.completed(completion))],
            termination: .completion(AgentModelBoundaryCompletion(outcome: .failed(failure)))
        )
        await assertModelContractViolation {
            _ = try await AgentModelExecutor().execute(
                provider: completedThenFailed,
                authorized: try await fixture.authorized(provider: completedThenFailed)
            )
        }

        let failedThenCompleted = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [ScriptedEmission(.failed(failure))],
            termination: .completion(AgentModelBoundaryCompletion(outcome: .completed(completion)))
        )
        await assertModelContractViolation {
            _ = try await AgentModelExecutor().execute(
                provider: failedThenCompleted,
                authorized: try await fixture.authorized(provider: failedThenCompleted)
            )
        }
    }

    func testProviderCannotThrowFailureOrInterruptionAfterATerminalEvent() async throws {
        let fixture = try ModelFixture(offset: 21)
        let failure = try modelFailure()

        let failureAfterTerminal = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [ScriptedEmission(.failed(failure))],
            termination: .providerFailure(failure)
        )
        await assertModelContractViolation {
            _ = try await AgentModelExecutor().execute(
                provider: failureAfterTerminal,
                authorized: try await fixture.authorized(provider: failureAfterTerminal)
            )
        }

        let interruptionAfterTerminal = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [ScriptedEmission(.failed(failure))],
            termination: .interruption(.lifecycleQuiescence)
        )
        await assertModelContractViolation {
            _ = try await AgentModelExecutor().execute(
                provider: interruptionAfterTerminal,
                authorized: try await fixture.authorized(provider: interruptionAfterTerminal)
            )
        }
    }

    func testCancellationNormalizesUnknownFailureAndBoundaryInterruption() async throws {
        let fixture = try ModelFixture(offset: 22)
        let authorizingProvider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities
        )
        let usage = try modelUsage(output: 7)

        for termination in SelfCancellationTermination.allCases {
            let authorized = try await fixture.authorized(provider: authorizingProvider)
            let provider = SelfCancellingModelProvider(
                descriptor: fixture.descriptor,
                reportedCapabilities: fixture.capabilities,
                usage: usage,
                termination: termination
            )
            let task = Task {
                try await AgentModelExecutor().execute(
                    provider: provider,
                    authorized: authorized
                )
            }
            let result = try await task.value
            XCTAssertEqual(result.outcome, .interrupted(usage))
            XCTAssertEqual(result.interruption?.reason, .cancelled)
            XCTAssertEqual(result.interruption?.lastUsage, usage)
            XCTAssertEqual(result.interruption?.failure.classification, .cancelled)
            switch termination {
            case .unknownFailure:
                XCTAssertNil(result.responseBytes)
            case .boundaryInterruption:
                XCTAssertEqual(result.responseBytes, 1)
            }
        }
    }

    func testUntrustedStreamCannotOverflowProvisionalAnswerOrEmitMultipleActions() async throws {
        let fixture = try ModelFixture(offset: 23)
        let maximumAnswer = String(repeating: "a", count: 8 * 1_024 * 1_024)
        let oversized = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [
                ScriptedEmission(.answerDelta(maximumAnswer)),
                ScriptedEmission(.answerDelta("b")),
            ],
            termination: .completion(AgentModelBoundaryCompletion(outcome: .interrupted(nil)))
        )
        await assertModelContractViolation {
            _ = try await AgentModelExecutor().execute(
                provider: oversized,
                authorized: try await fixture.authorized(provider: oversized)
            )
        }

        let interaction = try UserInputRequest(
            id: InteractionRequestID(rawValue: ModelFixture.uuid(2_300)),
            runID: fixture.request.runID,
            prompt: "Choose one",
            creationStateVersion: 1
        )
        let duplicateAction = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [
                ScriptedEmission(.requestUserInput(interaction)),
                ScriptedEmission(.requestUserInput(interaction)),
            ],
            termination: .completion(AgentModelBoundaryCompletion(outcome: .interrupted(nil)))
        )
        await assertModelContractViolation {
            _ = try await AgentModelExecutor().execute(
                provider: duplicateAction,
                authorized: try await fixture.authorized(provider: duplicateAction)
            )
        }
    }

    func testEveryUsageDimensionIsMonotonicAndCostShapeCannotChange() async throws {
        let fixture = try ModelFixture(reportsCost: true, offset: 24)
        let acceptedFirst = try modelUsage(
            input: 10,
            output: 1,
            milliseconds: 10,
            memory: 100,
            cost: 0,
            currency: "USD"
        )
        let acceptedSecond = try modelUsage(
            input: 11,
            output: 2,
            milliseconds: 11,
            memory: 101,
            cost: 0,
            currency: "USD"
        )
        let accepted = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            emissions: [
                ScriptedEmission(.usage(acceptedFirst)),
                ScriptedEmission(.usage(acceptedSecond)),
            ],
            termination: .completion(
                AgentModelBoundaryCompletion(outcome: .interrupted(acceptedSecond))
            )
        )
        let acceptedResult = try await AgentModelExecutor().execute(
            provider: accepted,
            authorized: try await fixture.authorized(provider: accepted)
        )
        XCTAssertEqual(acceptedResult.outcome, .interrupted(acceptedSecond))

        let invalidPairs: [(AgentModelUsage, AgentModelUsage)] = [
            (
                try modelUsage(input: 10, output: 2, milliseconds: 20, memory: 200),
                try modelUsage(input: 9, output: 2, milliseconds: 20, memory: 200)
            ),
            (
                try modelUsage(input: 10, output: 2, milliseconds: 20, memory: 200),
                try modelUsage(input: 10, output: 2, milliseconds: 20, memory: 200, cost: 0, currency: "USD")
            ),
            (
                acceptedFirst,
                try modelUsage(input: 11, output: 2, milliseconds: 11, memory: 101, cost: 0, currency: "EUR")
            ),
        ]
        for (index, pair) in invalidPairs.enumerated() {
            let provider = ScriptedModelProvider(
                descriptor: fixture.descriptor,
                capabilities: fixture.capabilities,
                emissions: [ScriptedEmission(.usage(pair.0)), ScriptedEmission(.usage(pair.1))],
                termination: .completion(
                    AgentModelBoundaryCompletion(outcome: .interrupted(pair.1))
                )
            )
            await assertModelContractViolation("invalid usage pair \(index)") {
                _ = try await AgentModelExecutor().execute(
                    provider: provider,
                    authorized: try await fixture.authorized(provider: provider)
                )
            }
        }
    }
}

private enum SelfCancellationTermination: CaseIterable, Sendable {
    case unknownFailure
    case boundaryInterruption
}

private struct SelfCancellingModelProvider: AgentModelProvider {
    let descriptor: AgentModelProviderDescriptor
    let reportedCapabilities: AgentModelCapabilities
    let usage: AgentModelUsage
    let termination: SelfCancellationTermination

    func capabilities(for selection: AgentModelSelection) async throws -> AgentModelCapabilities {
        reportedCapabilities
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(
            request: request,
            context: context,
            provider: descriptor
        )
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        try await emitter.emit(.usage(usage), responseBytes: 1)
        withUnsafeCurrentTask { task in task?.cancel() }
        switch termination {
        case .unknownFailure:
            throw ScriptedModelError()
        case .boundaryInterruption:
            return AgentModelBoundaryCompletion(outcome: .interrupted(usage))
        }
    }
}

private func assertModelContractViolation(
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected provider contract violation \(message)", file: file, line: line)
    } catch AgentModelRuntimeError.providerContractViolation {
        // Expected.
    } catch {
        XCTFail("Expected provider contract violation, got \(error) \(message)", file: file, line: line)
    }
}
