// SPDX-License-Identifier: MIT

import Foundation

/// Resolution of answer text that was streamed before the model's normalized action committed.
public enum AgentProvisionalAnswerResolution: Hashable, Sendable {
    case none
    case committed(String)
    case discarded(String)
}

/// Non-durable model activity suitable for progressive UI rendering.
public enum AgentEphemeralModelEvent: Hashable, Sendable {
    case visibleReasoningDelta(String)
    case provisionalAnswerDelta(String)
    case usage(AgentModelUsage)
    case provisionalAnswerResolved(AgentProvisionalAnswerResolution)
}

/// Non-durable execution activity. Terminal outcomes remain authoritative only in the journal.
public enum AgentEphemeralEvent: Hashable, Sendable {
    case model(AgentEphemeralModelEvent)
    case toolProgress(invocationID: ToolInvocationID, progress: ToolExecutionProgress)
}

/// Identity- and time-bound envelope for one live-only event emitted by an execution handle.
public struct AgentEphemeralEventEnvelope: Hashable, Sendable {
    public let executionHandleID: AgentExecutionHandleID
    public let runID: AgentRunID
    public let stepID: AgentStepID
    public let emittedAt: AgentTimestamp
    public let event: AgentEphemeralEvent

    public init(
        executionHandleID: AgentExecutionHandleID,
        runID: AgentRunID,
        stepID: AgentStepID,
        emittedAt: AgentTimestamp,
        event: AgentEphemeralEvent
    ) {
        self.executionHandleID = executionHandleID
        self.runID = runID
        self.stepID = stepID
        self.emittedAt = emittedAt
        self.event = event
    }
}
