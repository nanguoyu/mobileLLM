// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class PersistenceModelCoverageTests: XCTestCase {
    func testBoundaryClaimScopeRejectsInvalidStatesAndVersions() {
        let runID = AgentRunID()
        XCTAssertThrowsError(
            try RuntimeBoundaryClaimScope(
                runID: runID,
                expectedState: .created,
                expectedStateVersion: 1
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeRepositoryError,
                .durableFactCorrupt("invalid boundary claim scope")
            )
        }
        XCTAssertThrowsError(
            try RuntimeBoundaryClaimScope(
                runID: runID,
                expectedState: .executingTools,
                expectedStateVersion: 0
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeRepositoryError,
                .durableFactCorrupt("invalid boundary claim scope")
            )
        }
    }

    func testDurableCommandLeaseIsNilWithoutCompleteClaimFields() throws {
        let stream = RuntimeTestFixtures.Stream(offset: 60_000)
        let envelope = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: RuntimeTestFixtures.commandID(60_001),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 1)
        ))
        let command = DurableAgentCommand(
            admissionSequence: 1,
            envelope: envelope,
            fingerprint: StableDigest.sha256(Data("command".utf8)),
            state: .pending,
            admittedAt: AgentTimestamp(rawValue: 1),
            claimOwner: nil,
            claimExpiresAt: nil,
            leaseToken: nil,
            leaseGeneration: 0,
            attemptCount: 0,
            receipt: nil,
            completedAt: nil
        )
        XCTAssertNil(command.lease)

        let partial = DurableAgentCommand(
            admissionSequence: 2,
            envelope: envelope,
            fingerprint: command.fingerprint,
            state: .claimed,
            admittedAt: AgentTimestamp(rawValue: 1),
            claimOwner: "worker",
            claimExpiresAt: nil,
            leaseToken: nil,
            leaseGeneration: 1,
            attemptCount: 1,
            receipt: nil,
            completedAt: nil
        )
        XCTAssertNil(partial.lease)

        let complete = DurableAgentCommand(
            admissionSequence: 3,
            envelope: envelope,
            fingerprint: command.fingerprint,
            state: .claimed,
            admittedAt: AgentTimestamp(rawValue: 1),
            claimOwner: "worker",
            claimExpiresAt: AgentTimestamp(rawValue: 10),
            leaseToken: RuntimeTestFixtures.uuid(60_002),
            leaseGeneration: 1,
            attemptCount: 1,
            receipt: nil,
            completedAt: nil
        )
        XCTAssertNotNil(complete.lease)
        XCTAssertEqual(complete.lease?.owner, "worker")
        XCTAssertEqual(complete.lease?.expiresAt, AgentTimestamp(rawValue: 10))
    }
}
