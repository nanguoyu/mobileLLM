// SPDX-License-Identifier: MIT

import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

final class EphemeralExecutionEventTests: XCTestCase {
    func testEveryProvisionalResolutionAndModelEventCaseIsValueSemantic() throws {
        let usage = try AgentModelUsage(
            inputTokens: 3,
            outputTokens: 5,
            activeMilliseconds: 7,
            peakMemoryBytes: 11
        )
        let resolutions: [AgentProvisionalAnswerResolution] = [
            .none,
            .committed("answer"),
            .discarded("draft"),
        ]
        XCTAssertEqual(Set(resolutions).count, resolutions.count)

        let events: [AgentEphemeralModelEvent] = [
            .visibleReasoningDelta("reason"),
            .provisionalAnswerDelta("answer"),
            .usage(usage),
            .provisionalAnswerResolved(.none),
            .provisionalAnswerResolved(.committed("answer")),
            .provisionalAnswerResolved(.discarded("draft")),
        ]
        XCTAssertEqual(Set(events).count, events.count)
        XCTAssertEqual(events, events)
    }

    func testExecutionCasesAndEnvelopePreserveExactLiveIdentity() throws {
        let progress = try ToolExecutionProgress(
            completedUnits: 2,
            totalUnits: 4,
            message: "Halfway"
        )
        let model = AgentEphemeralEvent.model(.provisionalAnswerDelta("delta"))
        let tool = AgentEphemeralEvent.toolProgress(
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 31),
            progress: progress
        )
        XCTAssertNotEqual(model, tool)
        XCTAssertEqual(Set([model, tool]).count, 2)

        let envelope = AgentEphemeralEventEnvelope(
            executionHandleID: TestValues.id(AgentExecutionHandleIDDomain.self, 32),
            runID: TestValues.id(AgentRunIDDomain.self, 33),
            stepID: TestValues.id(AgentStepIDDomain.self, 34),
            emittedAt: AgentTimestamp(rawValue: 35),
            event: tool
        )
        XCTAssertEqual(envelope.executionHandleID, TestValues.id(AgentExecutionHandleIDDomain.self, 32))
        XCTAssertEqual(envelope.runID, TestValues.id(AgentRunIDDomain.self, 33))
        XCTAssertEqual(envelope.stepID, TestValues.id(AgentStepIDDomain.self, 34))
        XCTAssertEqual(envelope.emittedAt, AgentTimestamp(rawValue: 35))
        XCTAssertEqual(envelope.event, tool)
        XCTAssertEqual(envelope, envelope)
        XCTAssertEqual(Set([envelope]).count, 1)
    }
}
