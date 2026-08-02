// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class RunJournalContractTests: XCTestCase {
    func testValidAppendRequestFreezesAtomicCASInputs() throws {
        let e1 = try RuntimeTestFixtures.envelope(
            eventNumber: 70,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        let e2 = try RuntimeTestFixtures.envelope(
            eventNumber: 71,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        let request = try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(1)),
            runID: e1.payload.runID,
            expectedRunStateVersion: 1,
            events: [e1, e2]
        )
        XCTAssertEqual(request.runID, e1.payload.runID)
        XCTAssertEqual(request.expectedRunStateVersion, 1)
        XCTAssertEqual(request.events.count, 2)
    }

    func testAppendBatchAllowsStableFactsAndRegisteredSelfTransitions() throws {
        let stable1 = try RuntimeTestFixtures.envelope(
            eventNumber: 72,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        let stable2 = try RuntimeTestFixtures.envelope(
            eventNumber: 73,
            sequence: 2,
            stateVersion: 1,
            state: .created,
            timestamp: 2,
            previousDigest: stable1.payload.recordDigest
        )
        XCTAssertNoThrow(
            try RunJournalAppendRequest(
                mutationIdentity: .command(RuntimeTestFixtures.commandID(3)),
                runID: stable1.payload.runID,
                expectedRunStateVersion: 1,
                events: [stable1, stable2]
            )
        )

        let waiting1 = try RuntimeTestFixtures.envelope(
            eventNumber: 74,
            sequence: 1,
            stateVersion: 1,
            state: .waitingForApproval,
            timestamp: 1,
            previousDigest: nil
        )
        let waiting2 = try RuntimeTestFixtures.envelope(
            eventNumber: 75,
            sequence: 2,
            stateVersion: 2,
            state: .waitingForApproval,
            timestamp: 2,
            previousDigest: waiting1.payload.recordDigest
        )
        XCTAssertNoThrow(
            try RunJournalAppendRequest(
                mutationIdentity: .command(RuntimeTestFixtures.commandID(4)),
                runID: waiting1.payload.runID,
                expectedRunStateVersion: 1,
                events: [waiting1, waiting2]
            )
        )
    }

    func testAppendRequestRejectsMalformedBatches() throws {
        let stream = RuntimeTestFixtures.Stream()
        let e1 = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: 80,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        let identity = RunJournalMutationIdentity.outcome(e1.payload.eventID)

        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: identity,
                runID: stream.runID,
                expectedRunStateVersion: 0,
                events: [e1]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .invalidExpectedStateVersion) }
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: identity,
                runID: stream.runID,
                expectedRunStateVersion: 1,
                events: []
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .emptyEventBatch) }
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: identity,
                runID: RuntimeTestFixtures.Stream(offset: 50).runID,
                expectedRunStateVersion: 1,
                events: [e1]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .eventOwnershipMismatch) }
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: identity,
                runID: stream.runID,
                expectedRunStateVersion: 2,
                events: [e1]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .eventStateVersionPrecedesExpectation) }
        let firstVersionGap = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: 84,
            sequence: 1,
            stateVersion: 3,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: .command(RuntimeTestFixtures.commandID(9)),
                runID: stream.runID,
                expectedRunStateVersion: 1,
                events: [firstVersionGap]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .eventStateVersionGap) }
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: identity,
                runID: stream.runID,
                expectedRunStateVersion: 1,
                events: [e1, e1]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .duplicateEventIdentity) }

        let gap = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: 81,
            sequence: 3,
            stateVersion: 2,
            state: .preparing,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: identity,
                runID: stream.runID,
                expectedRunStateVersion: 1,
                events: [e1, gap]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .noncontiguousEventBatch) }

        let broken = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: 82,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 2,
            previousDigest: StableDigest.sha256(Data("broken".utf8))
        )
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: identity,
                runID: stream.runID,
                expectedRunStateVersion: 1,
                events: [e1, broken]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .discontinuousEventBatch) }

        let otherOwner = try RuntimeTestFixtures.envelope(
            stream: .init(offset: 60),
            eventNumber: 83,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: identity,
                runID: stream.runID,
                expectedRunStateVersion: 1,
                events: [e1, otherOwner]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .eventOwnershipMismatch) }

        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: .outcome(RuntimeTestFixtures.eventID(999)),
                runID: stream.runID,
                expectedRunStateVersion: 1,
                events: [e1]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .outcomeIdentityMissingFromBatch) }
    }

    func testAppendRequestRejectsRegressionsIllegalEdgesAndEventsAfterTerminal() throws {
        let e1 = try RuntimeTestFixtures.envelope(
            eventNumber: 120,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 10,
            usage: RuntimeTestFixtures.usage(10),
            previousDigest: nil
        )
        func request(_ event: AgentEventEnvelope) throws -> RunJournalAppendRequest {
            try RunJournalAppendRequest(
                mutationIdentity: .command(RuntimeTestFixtures.commandID(8)),
                runID: e1.payload.runID,
                expectedRunStateVersion: 1,
                events: [e1, event]
            )
        }

        let timestamp = try RuntimeTestFixtures.envelope(
            eventNumber: 121,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 9,
            usage: RuntimeTestFixtures.usage(10),
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try request(timestamp)) {
            XCTAssertEqual($0 as? RunJournalContractError, .eventTimestampRegression)
        }

        let usage = try RuntimeTestFixtures.envelope(
            eventNumber: 122,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 11,
            usage: RuntimeTestFixtures.usage(9),
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try request(usage)) {
            XCTAssertEqual($0 as? RunJournalContractError, .eventUsageRegression)
        }

        let illegal = try RuntimeTestFixtures.envelope(
            eventNumber: 123,
            sequence: 2,
            stateVersion: 2,
            state: .generating,
            timestamp: 11,
            usage: RuntimeTestFixtures.usage(10),
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try request(illegal)) {
            XCTAssertEqual($0 as? RunJournalContractError, .illegalEventTransition)
        }

        let terminal = try RuntimeTestFixtures.completedEnvelope(
            eventNumber: 124,
            sequence: 1,
            stateVersion: 1,
            timestamp: 1,
            usage: .zero,
            previousDigest: nil
        )
        let secondTerminal = try RuntimeTestFixtures.completedEnvelope(
            eventNumber: 125,
            sequence: 2,
            stateVersion: 1,
            timestamp: 2,
            usage: .zero,
            previousDigest: terminal.payload.recordDigest
        )
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: .command(RuntimeTestFixtures.commandID(10)),
                runID: terminal.payload.runID,
                expectedRunStateVersion: 1,
                events: [terminal, secondTerminal]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .eventAfterTerminal) }
    }

    func testSelfTransitionVersionBumpOutsideApprovalOrPauseIsIllegal() throws {
        let e1 = try RuntimeTestFixtures.envelope(
            eventNumber: 150,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 10,
            usage: .zero,
            previousDigest: nil
        )
        let bumped = try RuntimeTestFixtures.envelope(
            eventNumber: 151,
            sequence: 2,
            stateVersion: 2,
            state: .created,
            timestamp: 11,
            usage: .zero,
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(
            try RunJournalAppendRequest(
                mutationIdentity: .command(RuntimeTestFixtures.commandID(150)),
                runID: e1.payload.runID,
                expectedRunStateVersion: 1,
                events: [e1, bumped]
            )
        ) { XCTAssertEqual($0 as? RunJournalContractError, .illegalEventTransition) }
    }

    func testAppendReceiptEnforcesDispositionShape() throws {
        let event = try RuntimeTestFixtures.envelope(
            eventNumber: 90,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        let projection = try XCTUnwrap(AgentRunProjection.replay([event]))
        let identity = RunJournalMutationIdentity.command(RuntimeTestFixtures.commandID(2))

        let appended = try RunJournalAppendReceipt(
            mutationIdentity: identity,
            disposition: .appended,
            projection: projection,
            eventIDs: [event.payload.eventID]
        )
        XCTAssertEqual(appended.disposition, .appended)
        XCTAssertEqual(appended.projection, projection)
        XCTAssertNoThrow(
            try RunJournalAppendReceipt(
                mutationIdentity: identity,
                disposition: .replayed,
                projection: projection,
                eventIDs: [event.payload.eventID]
            )
        )
        XCTAssertNoThrow(
            try RunJournalAppendReceipt(
                mutationIdentity: identity,
                disposition: .stale,
                projection: projection,
                diagnostic: .staleExpectedVersion
            )
        )
        XCTAssertNoThrow(
            try RunJournalAppendReceipt(
                mutationIdentity: identity,
                disposition: .rejected,
                projection: projection,
                diagnostic: .terminalRunImmutable
            )
        )

        for invalid in [
            { try RunJournalAppendReceipt(
                mutationIdentity: identity,
                disposition: .appended,
                projection: projection
            ) },
            { try RunJournalAppendReceipt(
                mutationIdentity: identity,
                disposition: .replayed,
                projection: projection,
                eventIDs: [event.payload.eventID, event.payload.eventID]
            ) },
            { try RunJournalAppendReceipt(
                mutationIdentity: identity,
                disposition: .stale,
                projection: projection,
                diagnostic: .runNotFound
            ) },
            { try RunJournalAppendReceipt(
                mutationIdentity: identity,
                disposition: .rejected,
                projection: projection
            ) },
        ] {
            XCTAssertThrowsError(try invalid())
        }
    }

    func testReadRequestAndPageEnforceBoundsAndCursor() throws {
        let event = try RuntimeTestFixtures.envelope(
            eventNumber: 100,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        XCTAssertNoThrow(try RunJournalReadRequest(runID: event.payload.runID, limit: 1))
        XCTAssertNoThrow(try RunJournalReadRequest(runID: event.payload.runID, limit: 1_024))
        XCTAssertThrowsError(try RunJournalReadRequest(runID: event.payload.runID, limit: 0))
        XCTAssertThrowsError(try RunJournalReadRequest(runID: event.payload.runID, limit: 1_025))

        let page = try RunJournalEventPage(
            events: [event],
            nextCursor: event.payload.cursor,
            reachedEnd: true
        )
        XCTAssertEqual(page.events.count, 1)
        XCTAssertEqual(page.nextCursor, event.payload.cursor)
        XCTAssertTrue(page.reachedEnd)
        XCTAssertNoThrow(
            try RunJournalEventPage(events: [], nextCursor: nil, reachedEnd: true)
        )
        XCTAssertThrowsError(
            try RunJournalEventPage(events: [event], nextCursor: nil, reachedEnd: false)
        )
        XCTAssertThrowsError(
            try RunJournalEventPage(events: [], nextCursor: event.payload.cursor, reachedEnd: false)
        )
    }

    func testProtocolSurfaceSupportsActorImplementations() async throws {
        let event = try RuntimeTestFixtures.envelope(
            eventNumber: 110,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        let projection = try XCTUnwrap(AgentRunProjection.replay([event]))
        let journal: any RunJournal = StubJournal(projection: projection, event: event)
        let loaded = try await journal.loadProjection(for: event.payload.runID)
        XCTAssertEqual(loaded, projection)
        let page = try await journal.readEvents(
            RunJournalReadRequest(runID: event.payload.runID)
        )
        XCTAssertEqual(page.nextCursor, event.payload.cursor)
    }
}

private actor StubJournal: RunJournal {
    let projection: AgentRunProjection
    let event: AgentEventEnvelope

    init(projection: AgentRunProjection, event: AgentEventEnvelope) {
        self.projection = projection
        self.event = event
    }

    func loadProjection(for runID: AgentRunID) async throws -> AgentRunProjection? {
        runID == projection.runID ? projection : nil
    }

    func append(_ request: RunJournalAppendRequest) async throws -> RunJournalAppendReceipt {
        try RunJournalAppendReceipt(
            mutationIdentity: request.mutationIdentity,
            disposition: .appended,
            projection: projection,
            eventIDs: request.events.map(\.payload.eventID)
        )
    }

    func readEvents(_ request: RunJournalReadRequest) async throws -> RunJournalEventPage {
        try RunJournalEventPage(events: [event], nextCursor: event.payload.cursor, reachedEnd: true)
    }
}
