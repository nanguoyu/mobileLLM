// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

final class ProjectionReplayTests: XCTestCase {
    func testFullReplayEqualsSnapshotPlusTailAndIsDeterministic() throws {
        let e1 = try RuntimeTestFixtures.envelope(
            eventNumber: 1,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        let e2 = try RuntimeTestFixtures.envelope(
            eventNumber: 2,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 2,
            usage: RuntimeTestFixtures.usage(4),
            previousDigest: e1.payload.recordDigest
        )
        let e3 = try RuntimeTestFixtures.envelope(
            eventNumber: 3,
            sequence: 3,
            stateVersion: 3,
            state: .waitingForModel,
            timestamp: 3,
            usage: RuntimeTestFixtures.usage(8),
            previousDigest: e2.payload.recordDigest
        )

        let full = try XCTUnwrap(AgentRunProjection.replay([e1, e2, e3]))
        let repeated = try XCTUnwrap(AgentRunProjection.replay([e1, e2, e3]))
        let prefix = try XCTUnwrap(AgentRunProjection.replay([e1]))
        let fromTail = try prefix.applying([e2, e3])

        XCTAssertEqual(full, repeated)
        XCTAssertEqual(full, fromTail)
        XCTAssertEqual(full.state, .waitingForModel)
        XCTAssertEqual(full.stateVersion, 3)
        XCTAssertEqual(full.eventCount, 3)
        XCTAssertEqual(full.cumulativeUsage, RuntimeTestFixtures.usage(8))
        XCTAssertFalse(full.isTerminal)
        XCTAssertEqual(full.observedEventIDs.count, 3)
        XCTAssertEqual(try full.applying([]), full)
        XCTAssertNil(try AgentRunProjection.replay([]))
    }

    func testDuplicateOutOfOrderAndBrokenHashChainAreRejected() throws {
        let e1 = try RuntimeTestFixtures.envelope(
            eventNumber: 10,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        let projection = try XCTUnwrap(AgentRunProjection.replay([e1]))
        XCTAssertThrowsError(try projection.applying(e1)) { error in
            XCTAssertEqual(
                error as? AgentRunProjectionReplayError,
                .duplicateEventIdentity(e1.payload.eventID)
            )
        }

        let outOfOrder = try RuntimeTestFixtures.envelope(
            eventNumber: 11,
            sequence: 3,
            stateVersion: 2,
            state: .preparing,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try projection.applying(outOfOrder)) { error in
            XCTAssertEqual(
                error as? AgentRunProjectionReplayError,
                .noncontiguousSequence(expected: 2, actual: 3)
            )
        }

        let wrongDigest = StableDigest.sha256(Data("wrong".utf8))
        let broken = try RuntimeTestFixtures.envelope(
            eventNumber: 12,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 2,
            previousDigest: wrongDigest
        )
        XCTAssertThrowsError(try projection.applying(broken)) { error in
            XCTAssertEqual(error as? AgentRunProjectionReplayError, .hashChainMismatch)
        }

        XCTAssertThrowsError(try AgentRunProjection.replay([outOfOrder])) { error in
            XCTAssertEqual(error as? AgentRunProjectionReplayError, .initialSequenceMustBeOne)
        }
    }

    func testIdentityTimestampUsageAndVersionRegressionsAreRejected() throws {
        let e1 = try RuntimeTestFixtures.envelope(
            eventNumber: 20,
            sequence: 1,
            stateVersion: 2,
            state: .created,
            timestamp: 20,
            usage: RuntimeTestFixtures.usage(10),
            previousDigest: nil
        )
        let projection = try XCTUnwrap(AgentRunProjection.replay([e1]))

        let wrongStream = try RuntimeTestFixtures.envelope(
            stream: .init(offset: 20),
            eventNumber: 21,
            sequence: 2,
            stateVersion: 3,
            state: .preparing,
            timestamp: 21,
            usage: RuntimeTestFixtures.usage(11),
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try projection.applying(wrongStream)) { error in
            XCTAssertEqual(error as? AgentRunProjectionReplayError, .streamIdentityMismatch)
        }

        let timestampRegression = try RuntimeTestFixtures.envelope(
            eventNumber: 22,
            sequence: 2,
            stateVersion: 3,
            state: .preparing,
            timestamp: 19,
            usage: RuntimeTestFixtures.usage(11),
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try projection.applying(timestampRegression)) { error in
            XCTAssertEqual(error as? AgentRunProjectionReplayError, .timestampRegression)
        }

        let usageRegression = try RuntimeTestFixtures.envelope(
            eventNumber: 23,
            sequence: 2,
            stateVersion: 3,
            state: .preparing,
            timestamp: 21,
            usage: RuntimeTestFixtures.usage(9),
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try projection.applying(usageRegression)) { error in
            XCTAssertEqual(error as? AgentRunProjectionReplayError, .usageRegression)
        }

        let versionRegression = try RuntimeTestFixtures.envelope(
            eventNumber: 24,
            sequence: 2,
            stateVersion: 1,
            state: .created,
            timestamp: 21,
            usage: RuntimeTestFixtures.usage(11),
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try projection.applying(versionRegression)) { error in
            XCTAssertEqual(error as? AgentRunProjectionReplayError, .stateVersionRegression)
        }
    }

    func testIllegalEdgesVersionGapsAndUnregisteredSelfTransitionsAreRejected() throws {
        let e1 = try RuntimeTestFixtures.envelope(
            eventNumber: 30,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        let projection = try XCTUnwrap(AgentRunProjection.replay([e1]))

        let illegalEdge = try RuntimeTestFixtures.envelope(
            eventNumber: 31,
            sequence: 2,
            stateVersion: 2,
            state: .generating,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try projection.applying(illegalEdge)) { error in
            XCTAssertEqual(
                error as? AgentRunProjectionReplayError,
                .illegalStateTransition(from: .created, to: .generating)
            )
        }

        let versionGap = try RuntimeTestFixtures.envelope(
            eventNumber: 32,
            sequence: 2,
            stateVersion: 3,
            state: .preparing,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try projection.applying(versionGap)) { error in
            XCTAssertEqual(error as? AgentRunProjectionReplayError, .stateVersionGap)
        }

        let illegalSelf = try RuntimeTestFixtures.envelope(
            eventNumber: 33,
            sequence: 2,
            stateVersion: 2,
            state: .created,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertThrowsError(try projection.applying(illegalSelf)) { error in
            XCTAssertEqual(
                error as? AgentRunProjectionReplayError,
                .illegalSelfTransition(state: .created)
            )
        }

        let stableFact = try RuntimeTestFixtures.envelope(
            eventNumber: 34,
            sequence: 2,
            stateVersion: 1,
            state: .created,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        XCTAssertNoThrow(try projection.applying(stableFact))
    }

    func testRegisteredSelfTransitionsReplayAndTerminalStreamsCannotAdvance() throws {
        let e1 = try RuntimeTestFixtures.envelope(
            eventNumber: 40,
            sequence: 1,
            stateVersion: 1,
            state: .waitingForApproval,
            timestamp: 1,
            previousDigest: nil
        )
        let selfTransition = try RuntimeTestFixtures.envelope(
            eventNumber: 41,
            sequence: 2,
            stateVersion: 2,
            state: .waitingForApproval,
            timestamp: 2,
            previousDigest: e1.payload.recordDigest
        )
        let replayedSelf = try XCTUnwrap(AgentRunProjection.replay([e1, selfTransition]))
        XCTAssertEqual(replayedSelf.stateVersion, 2)

        let chain = try completedChain()
        let terminalProjection = try XCTUnwrap(AgentRunProjection.replay(chain))
        XCTAssertTrue(terminalProjection.isTerminal)
        XCTAssertEqual(terminalProjection.state, .completed)

        let last = try XCTUnwrap(chain.last)
        let anotherTerminal = try RuntimeTestFixtures.completedEnvelope(
            eventNumber: 60,
            sequence: last.payload.sequence + 1,
            stateVersion: last.payload.runStateVersion,
            timestamp: last.payload.timestamp.rawValue + 1,
            usage: last.payload.cumulativeUsage,
            previousDigest: last.payload.recordDigest
        )
        XCTAssertThrowsError(try terminalProjection.applying(anotherTerminal)) { error in
            XCTAssertEqual(error as? AgentRunProjectionReplayError, .eventAfterTerminal)
        }
    }

    private func completedChain() throws -> [AgentEventEnvelope] {
        let states: [AgentRunState] = [
            .created, .preparing, .waitingForModel, .generating, .validatingAction,
        ]
        var result: [AgentEventEnvelope] = []
        var previousDigest: StableDigest?
        for (offset, state) in states.enumerated() {
            let event = try RuntimeTestFixtures.envelope(
                eventNumber: 50 + offset,
                sequence: UInt64(offset + 1),
                stateVersion: UInt64(offset + 1),
                state: state,
                timestamp: Int64(offset + 1),
                usage: RuntimeTestFixtures.usage(UInt64(offset)),
                previousDigest: previousDigest
            )
            result.append(event)
            previousDigest = event.payload.recordDigest
        }
        result.append(
            try RuntimeTestFixtures.completedEnvelope(
                eventNumber: 55,
                sequence: 6,
                stateVersion: 6,
                timestamp: 6,
                usage: RuntimeTestFixtures.usage(5),
                previousDigest: previousDigest
            )
        )
        return result
    }
}
