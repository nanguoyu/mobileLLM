// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

enum RuntimeTestFixtures {
    struct Stream {
        let requestID: AgentRequestID
        let executionHandleID: AgentExecutionHandleID
        let runID: AgentRunID

        init(offset: Int = 0) {
            requestID = AgentRequestID(rawValue: RuntimeTestFixtures.uuid(1 + offset))
            executionHandleID = AgentExecutionHandleID(
                rawValue: RuntimeTestFixtures.uuid(2 + offset)
            )
            runID = AgentRunID(rawValue: RuntimeTestFixtures.uuid(3 + offset))
        }
    }

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
    }

    static func eventID(_ value: Int) -> AgentEventID {
        AgentEventID(rawValue: uuid(100 + value))
    }

    static func commandID(_ value: Int) -> AgentCommandID {
        AgentCommandID(rawValue: uuid(200 + value))
    }

    static func usage(_ inputTokens: UInt64 = 0) -> AgentUsage {
        AgentUsage(quantities: BudgetQuantities([.inputTokens: inputTokens]))
    }

    static func redaction() throws -> RedactionMetadata {
        try RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
    }

    static func failure() throws -> AgentFailure {
        try AgentFailure(
            code: "test.failure",
            classification: .permanent,
            safeMessage: "Test diagnostic",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: redaction()
        )
    }

    static func envelope(
        stream: Stream = Stream(),
        eventNumber: Int,
        sequence: UInt64,
        stateVersion: UInt64,
        state: AgentRunState,
        timestamp: Int64,
        usage: AgentUsage = .zero,
        previousDigest: StableDigest?,
        event: AgentEvent? = nil
    ) throws -> AgentEventEnvelope {
        let record = try AgentEventRecord(
            eventID: eventID(eventNumber),
            requestID: stream.requestID,
            executionHandleID: stream.executionHandleID,
            runID: stream.runID,
            sequence: sequence,
            runStateVersion: stateVersion,
            runState: state,
            timestamp: AgentTimestamp(rawValue: timestamp),
            event: event ?? .diagnostic(failure()),
            redaction: redaction(),
            cumulativeUsage: usage,
            previousRecordDigest: previousDigest
        )
        return try AgentEventEnvelope(payload: record)
    }

    static func completedEnvelope(
        stream: Stream = Stream(),
        eventNumber: Int,
        sequence: UInt64,
        stateVersion: UInt64,
        timestamp: Int64,
        usage: AgentUsage,
        previousDigest: StableDigest?
    ) throws -> AgentEventEnvelope {
        let status = try AgentRunStatus(
            state: .completed,
            stateVersion: stateVersion,
            terminalReason: .completed
        )
        let result = try AgentResult(
            requestID: stream.requestID,
            executionHandleID: stream.executionHandleID,
            runID: stream.runID,
            status: status,
            answer: try AgentAnswer(text: "done"),
            usage: usage
        )
        return try envelope(
            stream: stream,
            eventNumber: eventNumber,
            sequence: sequence,
            stateVersion: stateVersion,
            state: .completed,
            timestamp: timestamp,
            usage: usage,
            previousDigest: previousDigest,
            event: .terminal(result)
        )
    }
}
