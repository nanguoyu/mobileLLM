// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class AgentExecutorEphemeralIntegrationTests: XCTestCase {
    func testModelEphemeralEventsFanOutDetachFinishAndNeverReplayOrPersist() async throws {
        let offset = 700
        let answer = "Ephemeral final answer"
        let reasoning = "EPHEMERAL_REASONING_ONLY_700"
        let lateReasoning = "EPHEMERAL_LATE_EVENT_MUST_BE_REJECTED_700"
        let model = try ExecutorTestModelDefinition(offset: offset)
        let gate = BlockingModelGate()
        let escapedEmitter = EscapedModelEmitterProbe()
        let provider = try EphemeralCompletionModelProvider(
            model: model,
            answer: answer,
            reasoningDelta: reasoning,
            gate: gate,
            escapedEmitterProbe: escapedEmitter
        )
        let harness = try ExecutorTestHarness(offset: offset, provider: provider, model: model)
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        addTeardownBlock { await gate.release() }
        try await waitForExecutorCondition { await gate.hasEntered() }

        let firstStream = await handle.ephemeralEvents()
        let secondStream = await handle.ephemeralEvents()
        let detachedStream = await handle.ephemeralEvents()
        async let firstEvents = collectEphemeralEvents(firstStream)
        async let secondEvents = collectEphemeralEvents(secondStream)
        async let detachedFirst = consumeFirstEphemeralEvent(detachedStream)

        await gate.release()
        let durableEvents = try await collectTerminalEvents(from: handle)
        let (first, second, detached) = try await (firstEvents, secondEvents, detachedFirst)

        XCTAssertEqual(first, second, "every live subscriber must observe the same ordered events")
        XCTAssertEqual(detached, first.first)
        XCTAssertEqual(first.count, 4)
        XCTAssertTrue(first.allSatisfy {
            $0.executionHandleID == handleID && $0.runID == harness.request.runID
        })
        XCTAssertEqual(Set(first.map(\.stepID)).count, 1)
        guard first.count == 4 else { return }
        guard case .model(.visibleReasoningDelta(let receivedReasoning)) = first[0].event else {
            return XCTFail("expected visible reasoning first")
        }
        XCTAssertEqual(receivedReasoning, reasoning)
        guard case .model(.usage(let usage)) = first[1].event else {
            return XCTFail("expected usage second")
        }
        XCTAssertEqual(usage, provider.completion.usage)
        guard case .model(.provisionalAnswerDelta(let provisional)) = first[2].event else {
            return XCTFail("expected provisional answer third")
        }
        XCTAssertEqual(provisional, answer)
        guard case .model(.provisionalAnswerResolved(.committed(let committed))) = first[3].event else {
            return XCTFail("expected committed provisional-answer resolution last")
        }
        XCTAssertEqual(committed, answer)

        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, answer, "detaching one observer must not cancel execution")
        XCTAssertTrue(durableEvents.last?.payload.event.isRunTerminal == true)
        let durableDescription = durableEvents.map { String(describing: $0.payload.event) }
            .joined(separator: "\n")
        XCTAssertFalse(durableDescription.contains(reasoning), "ephemeral reasoning must not enter journal")

        let acceptedLateEmission = await escapedEmitter.emitLateReasoning(lateReasoning)
        XCTAssertFalse(acceptedLateEmission, "a provider cannot emit after its attempt boundary closes")
        let lateStream = await handle.ephemeralEvents()
        let replayed = try await collectEphemeralEvents(lateStream)
        XCTAssertTrue(replayed.isEmpty, "late attachment must not replay live-only events")
        XCTAssertFalse(durableDescription.contains(lateReasoning))
    }

    func testToolProgressIsLiveOnlyAndTerminalFinishesEverySubscriber() async throws {
        let offset = 701
        let progressMessage = "EPHEMERAL_TOOL_PROGRESS_ONLY_701"
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "progress-tool",
            supportsProgress: true
        )
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Answer after progress",
            script: modelScript
        )
        let gate = BlockingModelGate()
        let progress = try ToolExecutionProgress(
            completedUnits: 1,
            totalUnits: 2,
            message: progressMessage
        )
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .blockedProgressThenComplete(gate, progress, "progress result")
        )
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
        addTeardownBlock { await gate.release() }
        try await waitForExecutorCondition { await gate.hasEntered() }

        let firstStream = await handle.ephemeralEvents()
        let secondStream = await handle.ephemeralEvents()
        async let firstEvents = collectEphemeralEvents(firstStream)
        async let secondEvents = collectEphemeralEvents(secondStream)
        await gate.release()
        let durableEvents = try await collectTerminalEvents(from: handle)
        let (first, second) = try await (firstEvents, secondEvents)

        XCTAssertEqual(first, second)
        let progressEvents = first.compactMap { envelope -> ToolExecutionProgress? in
            guard case .toolProgress(let invocationID, let received) = envelope.event,
                  invocationID == call.invocationID
            else { return nil }
            return received
        }
        XCTAssertEqual(progressEvents, [progress])
        let durableDescription = durableEvents.map { String(describing: $0.payload.event) }
            .joined(separator: "\n")
        XCTAssertFalse(durableDescription.contains(progressMessage), "tool progress must not persist")
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "Answer after progress")

        let lateStream = await handle.ephemeralEvents()
        let lateEvents = try await collectEphemeralEvents(lateStream)
        XCTAssertTrue(lateEvents.isEmpty)
    }
}

private func collectEphemeralEvents(
    _ stream: AsyncThrowingStream<AgentEphemeralEventEnvelope, Error>
) async throws -> [AgentEphemeralEventEnvelope] {
    var events: [AgentEphemeralEventEnvelope] = []
    for try await event in stream { events.append(event) }
    return events
}

private func consumeFirstEphemeralEvent(
    _ stream: AsyncThrowingStream<AgentEphemeralEventEnvelope, Error>
) async throws -> AgentEphemeralEventEnvelope {
    for try await event in stream { return event }
    throw ExecutorIntegrationTestError.streamEndedUnexpectedly
}
