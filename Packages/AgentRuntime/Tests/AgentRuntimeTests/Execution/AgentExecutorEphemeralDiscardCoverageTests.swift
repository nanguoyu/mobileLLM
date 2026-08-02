// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

/// Closes coverage for the controller's ephemeral provisional-answer resolution and the executor's
/// idempotent submission conflict surface.
final class AgentExecutorEphemeralDiscardCoverageTests: XCTestCase {
    func testProvisionalAnswerDiscardIsEphemeralWhenModelSwitchesToTools() async throws {
        let offset = 730
        let model = try ExecutorTestModelDefinition(
            offset: offset,
            additionalCapabilities: [.multipleToolCalls]
        )
        let definition = try ExecutorTestToolDefinition(name: "discard-tool")
        let call = try definition.call(offset: offset)
        let provider = try ProvisionalThenToolModelProvider(
            model: model,
            call: call,
            answer: "Answer after tools"
        )
        let tool = ExecutorTestTool(definition: definition, behavior: .complete("tool result"))
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let stream = await handle.ephemeralEvents()
        async let ephemeral = collectEphemeralEvents(stream)
        let result = try await collectTerminalEvents(from: handle)
        let events = try await ephemeral

        XCTAssertEqual(result.last?.payload.event.isRunTerminal, true)
        let discarded = events.compactMap { event -> String? in
            guard case .model(.provisionalAnswerResolved(let resolution)) = event.event else {
                return nil
            }
            guard case .discarded(let text) = resolution else { return nil }
            return text
        }
        XCTAssertEqual(discarded, ["PROVISIONAL_TEXT_730"])
        let durableDescription = result.map { String(describing: $0.payload.event) }
            .joined(separator: "\n")
        XCTAssertFalse(durableDescription.contains("PROVISIONAL_TEXT_730"))
    }

    func testSubmissionConflictRejectsADifferentRequestForTheSameCommand() async throws {
        let offset = 731
        let model = try ExecutorTestModelDefinition(offset: offset)
        let provider = try FixedCompletionModelProvider(model: model, answer: "first")
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model
        )
        let firstHandle = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(offset)
        )

        let divergent = try AgentRequest(
            id: ExecutorTestID.request(offset),
            runID: ExecutorTestID.run(offset),
            conversationID: ExecutorTestID.conversation(offset),
            userTurnID: ExecutorTestID.turn(offset),
            role: "assistant",
            instruction: "A different instruction for the same command identity",
            outputRequirement: .text,
            modelPolicy: AgentModelPolicy(
                localOnly: true,
                allowedSelections: [model.selection],
                strategy: .pinned,
                requiredCapabilities: .init([])
            ),
            capabilityCeiling: .init(authority: .empty),
            budget: try AgentBudget.firstReleaseDefaults(
                contextTokensPerAttempt: 4_096,
                outputTokens: 6_144,
                peakMemoryBytes: 1_073_741_824
            ),
            provenance: AgentRequestProvenance(source: .user)
        )
        do {
            _ = try await harness.executor.submit(
                divergent,
                commandID: ExecutorTestID.command(offset)
            )
            XCTFail("Expected a submission conflict for a different request")
        } catch let error as AgentExecutionError {
            XCTAssertEqual(error, .submissionCommandConflict(ExecutorTestID.command(offset)))
        }

        let handle = try await harness.executor.attach(to: firstHandle)
        _ = try await collectTerminalEvents(from: handle)
        let loaded = try await handle.result()
        XCTAssertEqual(loaded?.answer?.text, "first")
    }
}

private struct ProvisionalThenToolModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let call: ProposedToolCall
    let answer: AgentAnswer
    private let passCounter = ScriptedInvocationCounter()

    init(
        model: ExecutorTestModelDefinition,
        call: ProposedToolCall,
        answer: String
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        self.call = call
        self.answer = try AgentAnswer(text: answer)
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let pass = await passCounter.count() + 1
        await passCounter.increment()
        let completion: AgentModelCompletion
        if pass == 1 {
            completion = try AgentModelCompletion(
                action: .callTools([call]),
                usage: modelUsage(input: 11, output: 2, milliseconds: 6, memory: 80)
            )
            try await emitter.emit(.answerDelta("PROVISIONAL_TEXT_730"), responseBytes: 12)
            try await emitter.emit(.completed(completion), responseBytes: 12)
        } else {
            completion = try AgentModelCompletion(
                action: .finalAnswer(answer),
                usage: modelUsage(input: 11, output: 2, milliseconds: 6, memory: 80)
            )
            try await emitter.emit(.answerDelta(answer.text!), responseBytes: 12)
            try await emitter.emit(.completed(completion), responseBytes: 12)
        }
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

private func collectEphemeralEvents(
    _ stream: AsyncThrowingStream<AgentEphemeralEventEnvelope, Error>
) async throws -> [AgentEphemeralEventEnvelope] {
    var collected: [AgentEphemeralEventEnvelope] = []
    for try await event in stream { collected.append(event) }
    return collected
}
