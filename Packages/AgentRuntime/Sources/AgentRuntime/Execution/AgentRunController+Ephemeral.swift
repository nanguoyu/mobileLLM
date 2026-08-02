// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

struct ControllerModelEventSink: AgentModelRuntimeEventSink, Sendable {
    let controller: AgentRunController
    let executionHandleID: AgentExecutionHandleID
    let runID: AgentRunID
    let stepID: AgentStepID

    func receive(_ event: AgentModelRuntimeEvent) async {
        await controller.publishModelEvent(
            event,
            executionHandleID: executionHandleID,
            runID: runID,
            stepID: stepID
        )
    }
}

struct ControllerToolEventSink: ToolExecutionEventSink, Sendable {
    let controller: AgentRunController
    let executionHandleID: AgentExecutionHandleID
    let runID: AgentRunID
    let stepID: AgentStepID
    let invocationID: ToolInvocationID

    func receive(_ event: ToolExecutionEvent) async {
        guard case .progress(let progress) = event else { return }
        await controller.publishEphemeral(
            .toolProgress(invocationID: invocationID, progress: progress),
            executionHandleID: executionHandleID,
            runID: runID,
            stepID: stepID
        )
    }
}

extension AgentRunController {
    func ephemeralEventStream(
        for handleID: AgentExecutionHandleID
    ) -> AsyncThrowingStream<AgentEphemeralEventEnvelope, Error> {
        let subscriptionID = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            ephemeralSubscriptions[handleID, default: [:]][subscriptionID] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.detachEphemeral(subscriptionID, from: handleID) }
            }
            Task { await self.finishEphemeralIfTerminal(subscriptionID, handleID: handleID) }
        }
    }

    func publishModelEvent(
        _ event: AgentModelRuntimeEvent,
        executionHandleID: AgentExecutionHandleID,
        runID: AgentRunID,
        stepID: AgentStepID
    ) async {
        let normalized: AgentEphemeralModelEvent
        switch event {
        case .visibleReasoningDelta(let value):
            normalized = .visibleReasoningDelta(value)
        case .provisionalAnswerDelta(let value):
            normalized = .provisionalAnswerDelta(value)
        case .usage(let value):
            normalized = .usage(value)
        case .provisionalAnswerResolved(let value):
            let resolution: AgentProvisionalAnswerResolution = switch value {
            case .none: .none
            case .committed(let text): .committed(text)
            case .discarded(let text): .discarded(text)
            }
            normalized = .provisionalAnswerResolved(resolution)
        }
        await publishEphemeral(
            .model(normalized),
            executionHandleID: executionHandleID,
            runID: runID,
            stepID: stepID
        )
    }

    func publishEphemeral(
        _ event: AgentEphemeralEvent,
        executionHandleID: AgentExecutionHandleID,
        runID: AgentRunID,
        stepID: AgentStepID
    ) async {
        guard ephemeralSubscriptions[executionHandleID]?.isEmpty == false,
              let timestamp = try? await clock.now(),
              let subscriptions = ephemeralSubscriptions[executionHandleID],
              !subscriptions.isEmpty
        else { return }
        let envelope = AgentEphemeralEventEnvelope(
            executionHandleID: executionHandleID,
            runID: runID,
            stepID: stepID,
            emittedAt: timestamp,
            event: event
        )
        let subscriptionIDs = Array(subscriptions.keys)
        for subscriptionID in subscriptionIDs {
            guard let continuation = ephemeralSubscriptions[executionHandleID]?[subscriptionID] else {
                continue
            }
            switch continuation.yield(envelope) {
            case .enqueued:
                break
            case .dropped:
                continuation.finish(throwing: AgentExecutionError.ephemeralObserverLagged)
                ephemeralSubscriptions[executionHandleID]?[subscriptionID] = nil
            case .terminated:
                ephemeralSubscriptions[executionHandleID]?[subscriptionID] = nil
            @unknown default:
                continuation.finish(throwing: AgentExecutionError.ephemeralObserverLagged)
                ephemeralSubscriptions[executionHandleID]?[subscriptionID] = nil
            }
        }
        if ephemeralSubscriptions[executionHandleID]?.isEmpty == true {
            ephemeralSubscriptions[executionHandleID] = nil
        }
    }

    func finishEphemeral(handleID: AgentExecutionHandleID) {
        let subscriptions = ephemeralSubscriptions.removeValue(forKey: handleID) ?? [:]
        for continuation in subscriptions.values { continuation.finish() }
    }

    private func finishEphemeralIfTerminal(
        _ subscriptionID: UUID,
        handleID: AgentExecutionHandleID
    ) async {
        do {
            guard let facts = try await repository.loadRunFacts(for: handleID) else {
                ephemeralSubscriptions[handleID]?[subscriptionID]?.finish(
                    throwing: AgentExecutionError.executionNotFound(handleID)
                )
                ephemeralSubscriptions[handleID]?[subscriptionID] = nil
                return
            }
            if facts.projection.isTerminal {
                ephemeralSubscriptions[handleID]?[subscriptionID]?.finish()
                ephemeralSubscriptions[handleID]?[subscriptionID] = nil
            }
        } catch {
            ephemeralSubscriptions[handleID]?[subscriptionID]?.finish(throwing: error)
            ephemeralSubscriptions[handleID]?[subscriptionID] = nil
        }
        if ephemeralSubscriptions[handleID]?.isEmpty == true {
            ephemeralSubscriptions[handleID] = nil
        }
    }

    private func detachEphemeral(_ subscriptionID: UUID, from handleID: AgentExecutionHandleID) {
        ephemeralSubscriptions[handleID]?[subscriptionID] = nil
        if ephemeralSubscriptions[handleID]?.isEmpty == true {
            ephemeralSubscriptions[handleID] = nil
        }
    }
}
