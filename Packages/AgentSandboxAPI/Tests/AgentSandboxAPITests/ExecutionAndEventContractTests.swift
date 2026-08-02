// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) import AgentContracts
@testable import AgentSandboxAPI

final class ExecutionAndEventContractTests: XCTestCase {
    func testRequestRoundTripAndImmutableAuthorityBudgetBindings() throws {
        let request = try SandboxTestValues.request()
        XCTAssertEqual(
            try decoded(SandboxExecutionRequest.self, from: request),
            request
        )
        XCTAssertTrue(request.requirement.authority.isSubset(of: request.stepGrant.authority))
        XCTAssertEqual(request.protocolVersion, request.negotiatedCapabilities.selectedProtocolVersion)
        XCTAssertNoThrow(try request.parentBudget.attenuating(to: request.requirement.budget))
        XCTAssertNoThrow(
            try request.negotiatedCapabilities.maximumBudget.attenuating(to: request.requirement.budget)
        )
        let key = SandboxStartIdempotencyKey(
            requestFingerprint: request.fingerprint,
            callerScope: SandboxTestValues.digest("d")
        )
        XCTAssertEqual(try decoded(SandboxStartIdempotencyKey.self, from: key), key)
        XCTAssertEqual(
            try decoded(SandboxAuthorizationReference.self, from: request.authorization),
            request.authorization
        )

        let descriptor = try SandboxTestValues.descriptor()
        let report = try SandboxTestValues.capabilities(
            descriptor: descriptor,
            features: [.cancellation, .codeExecution]
        )
        let policy = try SandboxTestValues.policy(descriptor: descriptor)
        let narrowNegotiation = try policy.negotiate(
            descriptor: descriptor,
            capabilities: report
        )
        XCTAssertThrowsError(
            try SandboxTestValues.request(
                negotiated: narrowNegotiation,
                requiredFeatures: [.networkAccess]
            )
        )

        let forged = try replacingJSONField(
            in: encodedJSON(request),
            path: ["fingerprint"],
            with: SandboxTestValues.digest("9").rawValue
        )
        XCTAssertThrowsError(try JSONDecoder().decode(SandboxExecutionRequest.self, from: forged))
    }

    func testRequestRejectsCapabilityAndBudgetExpansion() throws {
        let descriptor = try SandboxTestValues.descriptor()
        let narrowAuthority = SandboxTestValues.authority(capabilities: [.codeExecution])
        let report = try SandboxTestValues.capabilities(
            descriptor: descriptor,
            authority: narrowAuthority,
            budget: SandboxTestValues.budget(limit: 100)
        )
        let policy = try SandboxTestValues.policy(
            descriptor: descriptor,
            authority: narrowAuthority,
            budget: SandboxTestValues.budget(limit: 100)
        )
        let negotiated = try policy.negotiate(
            descriptor: descriptor,
            capabilities: report
        )
        let widenedAuthority = SandboxTestValues.authority(
            capabilities: [.codeExecution, .localRead]
        )
        XCTAssertThrowsError(
            try SandboxTestValues.request(
                negotiated: negotiated,
                authority: widenedAuthority,
                budget: SandboxTestValues.budget(limit: 100)
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .authorityOrBudgetExpansion) }

        XCTAssertThrowsError(
            try SandboxTestValues.request(
                negotiated: negotiated,
                authority: narrowAuthority,
                budget: SandboxTestValues.budget(limit: 101)
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .authorityOrBudgetExpansion) }
    }

    func testRequestRejectsUnscopedArtifactAndSecretReferences() throws {
        let negotiated = try SandboxTestValues.negotiated().negotiated
        let authority = SandboxTestValues.authority(capabilities: [.codeExecution])
        let budget = SandboxTestValues.budget(limit: 10_000)
        let requirement = try SandboxRequirement(
            minimumProtocolVersion: negotiated.selectedProtocolVersion,
            authority: authority,
            budget: budget
        )
        let grant = try StepCapabilityGrant(
            runCeiling: RunCapabilityCeiling(authority: authority),
            authority: authority
        )
        let requestID = SandboxTestValues.id(AgentRequestIDDomain.self, 1)
        let runID = SandboxTestValues.id(AgentRunIDDomain.self, 2)
        let stepID = SandboxTestValues.id(AgentStepIDDomain.self, 3)

        func makeRequest(
            payload: SanitizedCanonicalJSON,
            artifacts: [ArtifactReference]
        ) throws -> SandboxExecutionRequest {
            let authorization = SandboxAuthorizationReference(
                approvalID: SandboxTestValues.id(ApprovalIDDomain.self, 4),
                requestID: requestID,
                runID: runID,
                stepID: stepID,
                sanitizedPayloadFingerprint: payload.fingerprint,
                externalPlanFingerprint: SandboxTestValues.digest("b"),
                executionConstraintDigest: requirement.fingerprint,
                negotiatedCapabilitiesFingerprint: negotiated.fingerprint
            )
            return try SandboxExecutionRequest(
                requestID: requestID,
                runID: runID,
                stepID: stepID,
                requirement: requirement,
                stepGrant: grant,
                parentBudget: SandboxTestValues.budget(),
                negotiatedCapabilities: negotiated,
                requiredFeatures: [.cancellation],
                sanitizedPayload: payload,
                inputArtifacts: artifacts,
                authorization: authorization
            )
        }

        XCTAssertThrowsError(
            try makeRequest(
                payload: SandboxTestValues.sanitizedPayload(),
                artifacts: [SandboxTestValues.artifact()]
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .authorityOrBudgetExpansion) }

        let secretID = SandboxTestValues.id(SecretReferenceIDDomain.self, 90)
        XCTAssertThrowsError(
            try makeRequest(
                payload: SandboxTestValues.sanitizedPayload(secretIDs: [secretID]),
                artifacts: []
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .authorityOrBudgetExpansion) }
    }

    func testAuthorizationReferenceCannotBeRebound() throws {
        let values = try SandboxTestValues.negotiated()
        let authority = SandboxTestValues.authority()
        let requirement = try SandboxRequirement(
            minimumProtocolVersion: values.negotiated.selectedProtocolVersion,
            authority: authority,
            budget: SandboxTestValues.budget(limit: 10_000)
        )
        let grant = try StepCapabilityGrant(
            runCeiling: RunCapabilityCeiling(authority: authority),
            authority: authority
        )
        let payload = try SandboxTestValues.sanitizedPayload()
        let badAuthorization = SandboxAuthorizationReference(
            approvalID: SandboxTestValues.id(ApprovalIDDomain.self, 4),
            requestID: SandboxTestValues.id(AgentRequestIDDomain.self, 1),
            runID: SandboxTestValues.id(AgentRunIDDomain.self, 2),
            stepID: SandboxTestValues.id(AgentStepIDDomain.self, 3),
            sanitizedPayloadFingerprint: SandboxTestValues.digest("1"),
            externalPlanFingerprint: SandboxTestValues.digest("2"),
            executionConstraintDigest: requirement.fingerprint,
            negotiatedCapabilitiesFingerprint: values.negotiated.fingerprint
        )
        XCTAssertThrowsError(
            try SandboxExecutionRequest(
                requestID: SandboxTestValues.id(AgentRequestIDDomain.self, 1),
                runID: SandboxTestValues.id(AgentRunIDDomain.self, 2),
                stepID: SandboxTestValues.id(AgentStepIDDomain.self, 3),
                requirement: requirement,
                stepGrant: grant,
                parentBudget: SandboxTestValues.budget(),
                negotiatedCapabilities: values.negotiated,
                requiredFeatures: [.cancellation],
                sanitizedPayload: payload,
                authorization: badAuthorization
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .requestBindingMismatch) }
    }

    func testEveryStatusCommandAndReceiptCaseIsValidatedAndRoundTrips() throws {
        let handleID = SandboxTestValues.id(SandboxExecutionHandleIDDomain.self, 20)
        let progress = try AgentExecutionProgress(
            phase: "sandbox.running",
            completedUnits: 1,
            totalUnits: 2,
            safeMessage: "Working"
        )
        let statuses = [
            try SandboxTestValues.status(handleID: handleID, version: 1, state: .accepted),
            try SandboxTestValues.status(
                handleID: handleID,
                version: 2,
                state: .running,
                progress: progress,
                time: 1_010
            ),
            try SandboxTestValues.status(
                handleID: handleID,
                version: 3,
                state: .cancellationRequested,
                progress: progress,
                time: 1_020
            ),
            try SandboxTestValues.status(handleID: handleID, version: 4, state: .completed, time: 1_030),
            try SandboxTestValues.status(
                handleID: handleID,
                version: 4,
                state: .failed,
                failure: SandboxTestValues.failure(),
                time: 1_030
            ),
            try SandboxTestValues.status(
                handleID: handleID,
                version: 4,
                state: .cancelled,
                failure: SandboxTestValues.failure(.cancelled),
                time: 1_030
            ),
        ]
        XCTAssertEqual(Set(statuses.map(\.state)), Set(SandboxExecutionState.allCases))
        for status in statuses {
            XCTAssertEqual(try decoded(SandboxExecutionStatus.self, from: status), status)
            XCTAssertEqual(status.protocolVersion, AgentContractVersion.currentProtocol)
        }
        let forgedStatusDigest = try replacingJSONField(
            in: encodedJSON(statuses[1]),
            path: ["fingerprint"],
            with: SandboxTestValues.digest("4").rawValue
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SandboxExecutionStatus.self, from: forgedStatusDigest)
        )
        let forgedStatusVersion = try replacingJSONField(
            in: encodedJSON(statuses[1]),
            path: ["protocolVersion"],
            with: "2.0.0"
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SandboxExecutionStatus.self, from: forgedStatusVersion)
        )
        XCTAssertThrowsError(
            try SandboxTestValues.status(handleID: handleID, state: .cancelled)
        )
        XCTAssertThrowsError(
            try SandboxTestValues.status(
                handleID: handleID,
                state: .completed,
                failure: SandboxTestValues.failure()
            )
        )

        let command = try SandboxCommand(
            commandID: SandboxTestValues.id(SandboxCommandIDDomain.self, 21),
            handleID: handleID,
            expectedStateVersion: 2,
            action: .cancel,
            issuedAt: AgentTimestamp(rawValue: 1_020)
        )
        XCTAssertEqual(try decoded(SandboxCommand.self, from: command), command)
        XCTAssertEqual(SandboxCommandAction.allCases, [.cancel])

        let failure = try SandboxTestValues.failure()
        let dispositions = SandboxCommandDisposition.allCases
        for disposition in dispositions {
            let receipt = try SandboxCommandReceipt(
                commandID: command.commandID,
                commandFingerprint: command.fingerprint,
                handleID: handleID,
                disposition: disposition,
                currentStatus: statuses[1],
                failure: disposition == .accepted ? nil : failure
            )
            XCTAssertEqual(try decoded(SandboxCommandReceipt.self, from: receipt), receipt)
            XCTAssertEqual(receipt.protocolVersion, receipt.currentStatus.protocolVersion)
        }
        let acceptedReceipt = try SandboxCommandReceipt(
            commandID: command.commandID,
            commandFingerprint: command.fingerprint,
            handleID: handleID,
            disposition: .accepted,
            currentStatus: statuses[1]
        )
        let forgedReceipt = try replacingJSONField(
            in: encodedJSON(acceptedReceipt),
            path: ["fingerprint"],
            with: SandboxTestValues.digest("3").rawValue
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SandboxCommandReceipt.self, from: forgedReceipt)
        )
        XCTAssertThrowsError(
            try SandboxCommandReceipt(
                commandID: command.commandID,
                commandFingerprint: command.fingerprint,
                handleID: handleID,
                disposition: .stale,
                currentStatus: statuses[1]
            )
        )
    }

    func testTerminalResultsAreStatusBoundAndTamperEvident() throws {
        let handleID = SandboxTestValues.id(SandboxExecutionHandleIDDomain.self, 30)
        let completed = try SandboxTestValues.status(
            handleID: handleID,
            version: 4,
            state: .completed,
            time: 1_100
        )
        let result = try SandboxExecutionResult(
            requestID: SandboxTestValues.id(AgentRequestIDDomain.self, 1),
            handleID: handleID,
            terminalStatus: completed,
            structuredOutput: CanonicalJSON(.object(["ok": .bool(true)])),
            artifacts: [SandboxTestValues.artifact()],
            finalWorkspaceID: SandboxTestValues.id(SandboxWorkspaceHandleIDDomain.self, 31),
            checkpointID: SandboxTestValues.id(SandboxCheckpointHandleIDDomain.self, 32),
            usage: AgentUsage(quantities: BudgetQuantities([.activeMilliseconds: 100]))
        )
        XCTAssertEqual(try decoded(SandboxExecutionResult.self, from: result), result)
        XCTAssertEqual(result.protocolVersion, result.terminalStatus.protocolVersion)
        XCTAssertThrowsError(
            try SandboxEventRecord(
                eventID: SandboxTestValues.id(SandboxEventIDDomain.self, 33),
                handleID: handleID,
                sequence: 1,
                timestamp: completed.updatedAt,
                status: completed,
                cumulativeUsage: .zero,
                event: .terminal(result),
                previousRecordDigest: nil
            )
        )
        XCTAssertThrowsError(
            try SandboxExecutionResult(
                requestID: result.requestID,
                handleID: handleID,
                terminalStatus: try SandboxTestValues.status(
                    handleID: handleID,
                    version: 2,
                    state: .running,
                    time: 1_010
                )
            )
        )
        let tampered = try replacingJSONField(
            in: encodedJSON(result),
            path: ["fingerprint"],
            with: SandboxTestValues.digest("7").rawValue
        )
        XCTAssertThrowsError(try JSONDecoder().decode(SandboxExecutionResult.self, from: tampered))
    }

    func testEveryEventCaseBuildsAContinuousHashChainAndReplaysFromCursor() throws {
        let chain = try makeEventChain()
        XCTAssertEqual(chain.count, 8)
        XCTAssertEqual(Set(chain.map { eventCaseName($0.event) }).count, 8)
        let envelopes = try chain.map { try SandboxEventEnvelope(payload: $0) }
        for (record, envelope) in zip(chain, envelopes) {
            XCTAssertEqual(try decoded(SandboxEventRecord.self, from: record), record)
            XCTAssertEqual(
                try SandboxEventEnvelope.decodeUntrusted(from: encodedJSON(envelope)),
                envelope
            )
        }
        let redaction = try RedactionMetadata(
            classification: .personalData,
            redactedFieldPaths: ["event.audit.safeDetails.user"],
            omittedByteCount: 8,
            policyVersion: 1
        )
        let redactedEnvelope = try SandboxEventEnvelope(
            protocolVersion: chain[3].status.protocolVersion,
            payloadVersion: SandboxEventRecord.currentPayloadVersion,
            payload: chain[3],
            redaction: redaction
        )
        XCTAssertEqual(
            try SandboxEventEnvelope.decodeUntrusted(from: encodedJSON(redactedEnvelope)),
            redactedEnvelope
        )
        try SandboxEventPageValidator.validate(envelopes, after: nil)

        let cursor = try chain[2].cursor
        try SandboxEventPageValidator.validate(
            Array(envelopes.dropFirst(3)),
            after: cursor
        )
        let wrongDigestCursor = try AgentEventCursor(
            executionHandleID: cursor.executionHandleID,
            eventID: cursor.eventID,
            sequence: cursor.sequence,
            runStateVersion: cursor.runStateVersion,
            runState: cursor.runState,
            timestamp: cursor.timestamp,
            cumulativeUsage: cursor.cumulativeUsage,
            recordDigest: SandboxTestValues.digest("1"),
            isTerminal: cursor.isTerminal
        )
        XCTAssertThrowsError(
            try SandboxEventPageValidator.validate(
                Array(envelopes.dropFirst(3)),
                after: wrongDigestCursor
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .invalidEventChain) }

        let wrongCursor = try AgentEventCursor(
            executionHandleID: SandboxTestValues.id(AgentExecutionHandleIDDomain.self, 99),
            eventID: cursor.eventID,
            sequence: cursor.sequence,
            runStateVersion: cursor.runStateVersion,
            runState: cursor.runState,
            timestamp: cursor.timestamp,
            cumulativeUsage: cursor.cumulativeUsage,
            recordDigest: cursor.recordDigest,
            isTerminal: cursor.isTerminal
        )
        XCTAssertThrowsError(
            try SandboxEventPageValidator.validate(
                Array(envelopes.dropFirst(3)),
                after: wrongCursor
            )
        )
    }

    func testEventDigestSequenceAndTerminalPlacementFailClosed() throws {
        let chain = try makeEventChain()
        let tampered = try replacingJSONField(
            in: encodedJSON(chain[3]),
            path: ["recordDigest"],
            with: SandboxTestValues.digest("6").rawValue
        )
        XCTAssertThrowsError(try JSONDecoder().decode(SandboxEventRecord.self, from: tampered))

        XCTAssertThrowsError(
            try SandboxEventRecord(
                eventID: SandboxTestValues.id(SandboxEventIDDomain.self, 99),
                handleID: chain[0].handleID,
                sequence: 2,
                timestamp: AgentTimestamp(rawValue: 1_100),
                status: chain[0].status,
                event: .accepted(requestFingerprint: SandboxTestValues.digest()),
                previousRecordDigest: chain[0].recordDigest
            )
        )

        let duplicateTerminal = try SandboxEventEnvelope(
            payload: SandboxEventRecord(
                eventID: SandboxTestValues.id(SandboxEventIDDomain.self, 90),
                handleID: chain.last!.handleID,
                sequence: 9,
                timestamp: AgentTimestamp(rawValue: 1_090),
                status: chain.last!.status,
                event: chain.last!.event,
                previousRecordDigest: chain.last!.recordDigest
            )
        )
        let terminalPage = try [SandboxEventEnvelope(payload: chain.last!), duplicateTerminal]
        XCTAssertThrowsError(
            try SandboxEventPageValidator.validate(
                terminalPage,
                after: try chain[6].cursor
            )
        )

        let alternateProtocol = try SemanticVersion(major: 1, minor: 0, patch: 1)
        let protocolMismatchedEnvelope = try SandboxEventEnvelope(
            protocolVersion: alternateProtocol,
            payloadVersion: SandboxEventRecord.currentPayloadVersion,
            payload: chain[1]
        )
        XCTAssertThrowsError(
            try SandboxEventPageValidator.validate(
                [protocolMismatchedEnvelope],
                after: try chain[0].cursor
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .invalidEventChain) }

        let acceptedWithUsage = try SandboxEventRecord(
            eventID: SandboxTestValues.id(SandboxEventIDDomain.self, 91),
            handleID: chain[0].handleID,
            sequence: 1,
            timestamp: chain[0].timestamp,
            status: chain[0].status,
            cumulativeUsage: AgentUsage(
                quantities: BudgetQuantities([.activeMilliseconds: 2])
            ),
            event: chain[0].event,
            previousRecordDigest: nil
        )
        let decreasingUsage = try SandboxEventRecord(
            eventID: SandboxTestValues.id(SandboxEventIDDomain.self, 92),
            handleID: chain[1].handleID,
            sequence: 2,
            timestamp: chain[1].timestamp,
            status: chain[1].status,
            cumulativeUsage: AgentUsage(
                quantities: BudgetQuantities([.activeMilliseconds: 1])
            ),
            event: chain[1].event,
            previousRecordDigest: acceptedWithUsage.recordDigest
        )
        XCTAssertThrowsError(
            try SandboxEventPageValidator.validate(
                [
                    SandboxEventEnvelope(payload: acceptedWithUsage),
                    SandboxEventEnvelope(payload: decreasingUsage),
                ],
                after: nil
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .invalidEventChain) }

        XCTAssertThrowsError(
            try SandboxEventPageValidator.validate(
                [SandboxEventEnvelope(payload: chain[0])],
                after: try chain.last!.cursor
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .invalidCursor) }
    }

    func testPublicContractInventoryExercisesCollectionAndCursorSemantics() throws {
        let firstArtifact = try SandboxTestValues.artifact(41)
        let secondArtifact = try SandboxTestValues.artifact(42)
        let authority = SandboxTestValues.authority(
            artifactIDs: [firstArtifact.id, secondArtifact.id]
        )
        let descriptor = try SandboxTestValues.descriptor()
        let report = try SandboxTestValues.capabilities(
            descriptor: descriptor,
            authority: authority
        )
        let policy = try SandboxTestValues.policy(
            descriptor: descriptor,
            authority: authority
        )
        let negotiated = try policy.negotiate(
            descriptor: descriptor,
            capabilities: report
        )
        let budget = SandboxTestValues.budget(limit: 10_000)
        let requirement = try SandboxRequirement(
            minimumProtocolVersion: negotiated.selectedProtocolVersion,
            authority: authority,
            budget: budget,
            filesystem: [
                SandboxFilesystemRequirement(
                    logicalRoot: "workspace.root",
                    access: .readWrite,
                    artifactIDs: [secondArtifact.id, firstArtifact.id],
                    maximumWrittenBytes: 100
                ),
            ],
            process: SandboxProcessRequirement(
                maximumConcurrentProcesses: 1,
                maximumProcessLaunches: 2,
                allowedRuntimeIDs: ["test.runtime"]
            )
        )
        let grant = try StepCapabilityGrant(
            runCeiling: RunCapabilityCeiling(authority: authority),
            authority: authority
        )
        let payload = try SandboxTestValues.sanitizedPayload()
        let requestID = SandboxTestValues.id(AgentRequestIDDomain.self, 1)
        let runID = SandboxTestValues.id(AgentRunIDDomain.self, 2)
        let stepID = SandboxTestValues.id(AgentStepIDDomain.self, 3)
        let authorization = SandboxAuthorizationReference(
            approvalID: SandboxTestValues.id(ApprovalIDDomain.self, 4),
            requestID: requestID,
            runID: runID,
            stepID: stepID,
            sanitizedPayloadFingerprint: payload.fingerprint,
            externalPlanFingerprint: SandboxTestValues.digest("b"),
            executionConstraintDigest: requirement.fingerprint,
            negotiatedCapabilitiesFingerprint: negotiated.fingerprint
        )
        let request = try SandboxExecutionRequest(
            requestID: requestID,
            runID: runID,
            stepID: stepID,
            requirement: requirement,
            stepGrant: grant,
            parentBudget: SandboxTestValues.budget(),
            negotiatedCapabilities: negotiated,
            requiredFeatures: [.cancellation],
            sanitizedPayload: payload,
            inputArtifacts: [secondArtifact, firstArtifact],
            authorization: authorization
        )
        XCTAssertEqual(request.inputArtifacts.map(\.id), [firstArtifact.id, secondArtifact.id])
        XCTAssertTrue(request.requiredFeatures.contains(.filesystemRead))
        XCTAssertTrue(request.requiredFeatures.contains(.filesystemWrite))
        XCTAssertTrue(request.requiredFeatures.contains(.processExecution))
        XCTAssertTrue(request.requiredFeatures.contains(.codeExecution))

        let rawKey = SandboxStartIdempotencyKey(rawValue: SandboxTestValues.digest("d"))
        XCTAssertEqual(rawKey.rawValue, SandboxTestValues.digest("d"))

        let handleID = SandboxTestValues.id(SandboxExecutionHandleIDDomain.self, 80)
        let completed = try SandboxTestValues.status(
            handleID: handleID,
            version: 4,
            state: .completed,
            time: 1_030
        )
        let result = try SandboxExecutionResult(
            requestID: requestID,
            handleID: handleID,
            terminalStatus: completed,
            artifacts: [secondArtifact, firstArtifact]
        )
        XCTAssertEqual(result.artifacts.map(\.id), [firstArtifact.id, secondArtifact.id])

        let accepted = try SandboxTestValues.status(handleID: handleID)
        let acceptedRecord = try SandboxEventRecord(
            eventID: SandboxTestValues.id(SandboxEventIDDomain.self, 81),
            handleID: handleID,
            sequence: 1,
            timestamp: accepted.updatedAt,
            status: accepted,
            event: .accepted(requestFingerprint: request.fingerprint),
            previousRecordDigest: nil
        )
        XCTAssertEqual(
            try acceptedRecord.sandboxCursor,
            try SandboxEventCursor(
                executionHandleID: handleID,
                eventID: acceptedRecord.eventID,
                sequence: acceptedRecord.sequence
            )
        )

        let progress = try AgentExecutionProgress(
            phase: "sandbox.cancelling",
            completedUnits: 1,
            totalUnits: 2
        )
        let cancelling = try SandboxTestValues.status(
            handleID: handleID,
            version: 2,
            state: .cancellationRequested,
            progress: progress,
            time: 1_010
        )
        XCTAssertNoThrow(
            try SandboxEventRecord(
                eventID: SandboxTestValues.id(SandboxEventIDDomain.self, 82),
                handleID: handleID,
                sequence: 2,
                timestamp: cancelling.updatedAt,
                status: cancelling,
                event: .progress(progress),
                previousRecordDigest: acceptedRecord.recordDigest
            )
        )

        let audit = try SandboxAuditRecord(
            category: "execution",
            action: "inspect",
            safeDetails: ["source": "contract-test", "result": "ok"]
        )
        XCTAssertEqual(audit.safeDetails.count, 2)
        XCTAssertEqual(try decoded(SandboxAuditRecord.self, from: audit), audit)
    }

    private func makeEventChain() throws -> [SandboxEventRecord] {
        let handleID = SandboxTestValues.id(SandboxExecutionHandleIDDomain.self, 50)
        let requestID = SandboxTestValues.id(AgentRequestIDDomain.self, 1)
        var chain: [SandboxEventRecord] = []
        func append(_ status: SandboxExecutionStatus, _ event: SandboxEvent, time: Int64) throws {
            chain.append(
                try SandboxEventRecord(
                    eventID: SandboxTestValues.id(
                        SandboxEventIDDomain.self,
                        UInt16(60 + chain.count)
                    ),
                    handleID: handleID,
                    sequence: UInt64(chain.count + 1),
                    timestamp: AgentTimestamp(rawValue: time),
                    status: status,
                    event: event,
                    previousRecordDigest: chain.last?.recordDigest
                )
            )
        }

        let accepted = try SandboxTestValues.status(handleID: handleID)
        try append(accepted, .accepted(requestFingerprint: SandboxTestValues.digest()), time: 1_000)
        let running = try SandboxTestValues.status(
            handleID: handleID,
            version: 2,
            state: .running,
            time: 1_010
        )
        try append(running, .started, time: 1_010)
        let progress = try AgentExecutionProgress(
            phase: "sandbox.running",
            completedUnits: 1,
            totalUnits: 2
        )
        let progressing = try SandboxTestValues.status(
            handleID: handleID,
            version: 3,
            state: .running,
            progress: progress,
            time: 1_020
        )
        try append(progressing, .progress(progress), time: 1_020)
        let audited = try SandboxTestValues.status(
            handleID: handleID,
            version: 4,
            state: .running,
            time: 1_030
        )
        try append(
            audited,
            .audit(SandboxAuditRecord(category: "execution", action: "heartbeat")),
            time: 1_030
        )
        let artifactStatus = try SandboxTestValues.status(
            handleID: handleID,
            version: 5,
            state: .running,
            time: 1_040
        )
        try append(artifactStatus, .artifactProduced(SandboxTestValues.artifact()), time: 1_040)
        let checkpointStatus = try SandboxTestValues.status(
            handleID: handleID,
            version: 6,
            state: .running,
            time: 1_050
        )
        try append(
            checkpointStatus,
            .checkpointCreated(SandboxTestValues.id(SandboxCheckpointHandleIDDomain.self, 70)),
            time: 1_050
        )
        let cancellation = try SandboxTestValues.status(
            handleID: handleID,
            version: 7,
            state: .cancellationRequested,
            time: 1_060
        )
        let command = try SandboxCommand(
            commandID: SandboxTestValues.id(SandboxCommandIDDomain.self, 71),
            handleID: handleID,
            expectedStateVersion: 6,
            action: .cancel,
            issuedAt: AgentTimestamp(rawValue: 1_060)
        )
        let receipt = try SandboxCommandReceipt(
            commandID: command.commandID,
            commandFingerprint: command.fingerprint,
            handleID: handleID,
            disposition: .accepted,
            currentStatus: cancellation
        )
        try append(cancellation, .commandProcessed(receipt), time: 1_060)
        let cancelled = try SandboxTestValues.status(
            handleID: handleID,
            version: 8,
            state: .cancelled,
            failure: SandboxTestValues.failure(.cancelled),
            time: 1_070
        )
        let result = try SandboxExecutionResult(
            requestID: requestID,
            handleID: handleID,
            terminalStatus: cancelled
        )
        try append(cancelled, .terminal(result), time: 1_070)
        return chain
    }

    private func eventCaseName(_ event: SandboxEvent) -> String {
        switch event {
        case .accepted: "accepted"
        case .started: "started"
        case .progress: "progress"
        case .audit: "audit"
        case .artifactProduced: "artifactProduced"
        case .checkpointCreated: "checkpointCreated"
        case .commandProcessed: "commandProcessed"
        case .terminal: "terminal"
        }
    }
}
