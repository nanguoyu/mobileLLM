// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import AgentContracts

final class ContractFreezeBoundaryTests: XCTestCase {
    func testCommandApprovalScopeAndQuiescenceWireContracts() throws {
        let commandID = TestValues.id(AgentCommandIDDomain.self, 390)
        let runID = TestValues.id(AgentRunIDDomain.self, 391)
        let approvalID = TestValues.id(ApprovalIDDomain.self, 392)

        var pauseWires = Set<Data>()
        for (index, reason) in AgentQuiescenceReason.allCases.enumerated() {
            let command = try AgentCommand(
                commandID: commandID,
                runID: runID,
                expectedRunStateVersion: UInt64(index + 1),
                action: .pause(reason: reason),
                issuedAt: AgentTimestamp(rawValue: 10)
            )
            try assertContractRoundTrip(command)
            pauseWires.insert(try encodedJSON(command.action))
        }
        XCTAssertEqual(pauseWires.count, AgentQuiescenceReason.allCases.count)
        XCTAssertEqual(
            String(decoding: try encodedJSON(
                AgentCommandAction.pause(reason: .resourcePressure)
            ), as: UTF8.self),
            #"{"pause":{"reason":"resourcePressure"}}"#
        )

        let scopes: [ApprovalScope?] = [nil, .exactInvocation, .conversation]
        for decision in ApprovalDecision.allCases {
            for scope in scopes {
                let shouldAccept = decision == .approved ? scope != nil : scope == nil
                let result = try? AgentCommand(
                    commandID: commandID,
                    runID: runID,
                    expectedRunStateVersion: 1,
                    action: .decideApproval(
                        approvalID: approvalID,
                        decision: decision,
                        approvedScope: scope
                    ),
                    issuedAt: AgentTimestamp(rawValue: 10)
                )
                XCTAssertEqual(
                    result != nil,
                    shouldAccept,
                    "unexpected command acceptance for \(decision.rawValue)/\(scope?.rawValue ?? "nil")"
                )
                if let result { try assertContractRoundTrip(result) }
            }
        }

        let exact = try AgentCommand(
            commandID: commandID,
            runID: runID,
            expectedRunStateVersion: 1,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 10)
        )
        let conversation = try AgentCommand(
            commandID: commandID,
            runID: runID,
            expectedRunStateVersion: 1,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .conversation
            ),
            issuedAt: AgentTimestamp(rawValue: 10)
        )
        XCTAssertNotEqual(
            StableDigest.sha256(try encodedJSON(exact)),
            StableDigest.sha256(try encodedJSON(conversation))
        )
        XCTAssertEqual(
            String(decoding: try encodedJSON(exact.action), as: UTF8.self),
            #"{"decideApproval":{"approvalID":"00000000-0000-4000-8000-000000000188","approvedScope":"exactInvocation","decision":"approved"}}"#
        )

        let forgedDeniedWithScope = try replacingJSONField(
            in: encodedJSON(exact),
            path: ["action", "decideApproval", "decision"],
            with: ApprovalDecision.denied.rawValue
        )
        XCTAssertThrowsError(try AgentWireDecoder.decode(
            AgentCommand.self,
            from: forgedDeniedWithScope
        ))
    }

    func testApprovalRequestCarriesOneIdentityAcrossEventStatusCommandAndReceipt() throws {
        let prepared = try TestValues.preparedRead()
        let approvalID = TestValues.id(ApprovalIDDomain.self, 400)
        let request = try AgentApprovalRequest(
            id: approvalID,
            prepared: prepared,
            policyVersion: 7,
            createdAt: AgentTimestamp(rawValue: 100),
            expiresAt: AgentTimestamp(rawValue: 200)
        )
        try assertContractRoundTrip(request)
        let envelope = try AgentApprovalRequestEnvelope(payload: request)
        try assertContractRoundTrip(envelope)
        XCTAssertFalse(request.acceptsDecision(at: AgentTimestamp(rawValue: 99)))
        XCTAssertTrue(request.acceptsDecision(at: AgentTimestamp(rawValue: 100)))
        XCTAssertTrue(request.acceptsDecision(at: AgentTimestamp(rawValue: 200)))
        XCTAssertFalse(request.acceptsDecision(at: AgentTimestamp(rawValue: 201)))

        let status = try AgentRunStatus(
            state: .waitingForApproval,
            stateVersion: 2,
            blockingReason: .approval(approvalID: approvalID)
        )
        let command = try AgentCommand(
            commandID: TestValues.id(AgentCommandIDDomain.self, 401),
            runID: prepared.runID,
            expectedRunStateVersion: 2,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 150)
        )
        let receipt = try ApprovalReceipt(
            request: request,
            decision: .approved,
            scope: .exactInvocation,
            decidedAt: command.issuedAt,
            receiptExpiresAt: AgentTimestamp(rawValue: 250)
        )
        let event = try AgentEventRecord(
            eventID: TestValues.id(AgentEventIDDomain.self, 402),
            requestID: prepared.requestID,
            executionHandleID: TestValues.id(AgentExecutionHandleIDDomain.self, 403),
            runID: prepared.runID,
            sequence: 1,
            runStateVersion: status.stateVersion,
            runState: status.state,
            timestamp: request.createdAt,
            event: .approvalRequested(request),
            redaction: TestValues.redaction(),
            cumulativeUsage: .zero,
            previousRecordDigest: nil
        )

        guard case .approval(let blockingID) = status.blockingReason else {
            return XCTFail("Expected approval blocking reason")
        }
        guard case .decideApproval(let commandID, let decision, let scope) = command.action else {
            return XCTFail("Expected approval command")
        }
        guard case .approvalRequested(let eventRequest) = event.event else {
            return XCTFail("Expected approval request event")
        }
        XCTAssertEqual(blockingID, approvalID)
        XCTAssertEqual(commandID, approvalID)
        XCTAssertEqual(decision, .approved)
        XCTAssertEqual(scope, .exactInvocation)
        XCTAssertEqual(eventRequest.id, approvalID)
        XCTAssertEqual(receipt.id, approvalID)
        XCTAssertEqual(receipt.policyVersion, request.policyVersion)
        XCTAssertEqual(receipt.preparedRequestFingerprint, prepared.fingerprint)
    }

    func testApprovalRequestRejectsInvalidPolicyExpiryLateDecisionAndWrongEventOwner() throws {
        let prepared = try TestValues.preparedRead()
        let approvalID = TestValues.id(ApprovalIDDomain.self, 410)
        XCTAssertThrowsError(try AgentApprovalRequest(
            id: approvalID,
            prepared: prepared,
            policyVersion: 0,
            createdAt: AgentTimestamp(rawValue: 100)
        ))
        XCTAssertThrowsError(try AgentApprovalRequest(
            id: approvalID,
            prepared: prepared,
            policyVersion: 1,
            createdAt: AgentTimestamp(rawValue: 100),
            expiresAt: AgentTimestamp(rawValue: 99)
        ))

        let request = try AgentApprovalRequest(
            id: approvalID,
            prepared: prepared,
            policyVersion: 1,
            createdAt: AgentTimestamp(rawValue: 100),
            expiresAt: AgentTimestamp(rawValue: 200)
        )
        XCTAssertThrowsError(try ApprovalReceipt(
            request: request,
            decision: .approved,
            scope: .exactInvocation,
            decidedAt: AgentTimestamp(rawValue: 201)
        ))

        let forgedPolicy = try replacingJSONField(
            in: encodedJSON(request),
            path: ["policyVersion"],
            with: 0
        )
        XCTAssertThrowsError(try JSONDecoder().decode(AgentApprovalRequest.self, from: forgedPolicy))

        XCTAssertThrowsError(try AgentEventRecord(
            eventID: TestValues.id(AgentEventIDDomain.self, 411),
            requestID: TestValues.id(AgentRequestIDDomain.self, 412),
            executionHandleID: TestValues.id(AgentExecutionHandleIDDomain.self, 413),
            runID: prepared.runID,
            sequence: 1,
            runStateVersion: 1,
            runState: .waitingForApproval,
            timestamp: request.createdAt,
            event: .approvalRequested(request),
            redaction: TestValues.redaction(),
            cumulativeUsage: .zero,
            previousRecordDigest: nil
        ))
    }

    func testDurableStableBoundaryEventsCarryOnlyVersionedDigestReferences() throws {
        let runID = TestValues.id(AgentRunIDDomain.self, 420)
        let requestID = TestValues.id(AgentRequestIDDomain.self, 421)
        let handleID = TestValues.id(AgentExecutionHandleIDDomain.self, 422)
        let stepID = TestValues.id(AgentStepIDDomain.self, 423)
        let interactionID = TestValues.id(InteractionRequestIDDomain.self, 424)
        let reference = try AgentStableBoundaryReference(
            formatVersion: 2,
            digest: TestValues.digest("8"),
            artifactID: TestValues.id(ArtifactIDDomain.self, 425)
        )
        try assertContractRoundTrip(reference)
        try assertContractRoundTrip(try AgentEnvelope(payload: reference))
        XCTAssertThrowsError(try AgentStableBoundaryReference(
            formatVersion: 0,
            digest: reference.digest
        ))

        let events: [AgentEvent] = [
            .runInputSnapshotCommitted(reference),
            .compiledManifestCommitted(stepID: stepID, reference: reference),
            .validatedActionCommitted(stepID: stepID, reference: reference),
            .userInputResponseCommitted(requestID: interactionID, reference: reference),
        ]
        let encodedEvents = try encodedJSON(events)
        XCTAssertFalse(String(decoding: encodedEvents, as: UTF8.self).contains("sensitive-body"))
        XCTAssertTrue(String(decoding: encodedEvents, as: UTF8.self).contains(reference.digest.rawValue))
        XCTAssertEqual(
            try AgentWireDecoder.decode([AgentEvent].self, from: encodedEvents),
            events
        )

        var records: [AgentEventRecord] = []
        for (index, event) in events.enumerated() {
            records.append(try AgentEventRecord(
                eventID: TestValues.id(AgentEventIDDomain.self, UInt16(430 + index)),
                requestID: requestID,
                executionHandleID: handleID,
                runID: runID,
                sequence: UInt64(index + 1),
                runStateVersion: 1,
                runState: .preparing,
                timestamp: AgentTimestamp(rawValue: Int64(1_000 + index)),
                event: event,
                redaction: TestValues.redaction(),
                cumulativeUsage: .zero,
                previousRecordDigest: records.last?.recordDigest
            ))
        }
        try AgentEventSequenceValidator.validate(
            records.map { try AgentEventEnvelope(payload: $0) },
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID
        )
    }
}
