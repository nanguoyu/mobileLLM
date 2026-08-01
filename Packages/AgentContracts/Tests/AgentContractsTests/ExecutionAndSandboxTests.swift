// SPDX-License-Identifier: MIT

import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

final class ExecutionAndSandboxTests: XCTestCase {
    func testRunStatusMatrixRequiresTypedBlockingAndTerminalFailures() throws {
        XCTAssertThrowsError(try AgentRunStatus(state: .created, stateVersion: 0))
        XCTAssertNoThrow(try AgentRunStatus(state: .created, stateVersion: 1))
        XCTAssertNoThrow(
            try AgentRunStatus(
                state: .waitingForApproval,
                stateVersion: 2,
                blockingReason: .approval(approvalID: TestValues.id(ApprovalIDDomain.self, 1))
            )
        )
        XCTAssertThrowsError(try AgentRunStatus(state: .waitingForApproval, stateVersion: 2))
        XCTAssertThrowsError(
            try AgentRunStatus(state: .failed, stateVersion: 3, terminalReason: .internalFailure)
        )
        let uncertain = TestValues.failure(
            classification: .potentiallySideEffecting,
            externalEffect: .uncertain,
            action: .reconcile
        )
        XCTAssertNoThrow(
            try AgentRunStatus(
                state: .waitingForReconciliation,
                stateVersion: 3,
                failure: uncertain,
                blockingReason: .reconciliation(
                    invocationID: TestValues.id(ToolInvocationIDDomain.self, 2)
                )
            )
        )
        XCTAssertThrowsError(
            try AgentRunStatus(
                state: .waitingForReconciliation,
                stateVersion: 3,
                failure: TestValues.failure(),
                blockingReason: .reconciliation(
                    invocationID: TestValues.id(ToolInvocationIDDomain.self, 2)
                )
            )
        )
        XCTAssertTrue(AgentRunTransitionMatrix.allows(from: .created, to: .preparing))
        XCTAssertFalse(AgentRunTransitionMatrix.allows(from: .created, to: .completed))
        XCTAssertFalse(AgentRunTransitionMatrix.allows(from: .completed, to: .generating))
    }

    func testCommandsAndReceiptsAreCASBoundAndIdempotentValues() throws {
        let commandID = TestValues.id(AgentCommandIDDomain.self, 10)
        let runID = TestValues.id(AgentRunIDDomain.self, 11)
        let command = try AgentCommand(
            commandID: commandID,
            runID: runID,
            expectedRunStateVersion: 4,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 100)
        )
        XCTAssertEqual(try AgentWireDecoder.decode(AgentCommand.self, from: encodedJSON(command)), command)
        let currentStatus = try AgentRunStatus(
            state: .paused,
            stateVersion: 5,
            blockingReason: .paused
        )
        let receipt = try AgentCommandReceipt(
            commandID: commandID,
            runID: runID,
            disposition: .accepted,
            currentStatus: currentStatus
        )
        let duplicateReceipt = try AgentCommandReceipt(
            commandID: commandID,
            runID: runID,
            disposition: .accepted,
            currentStatus: currentStatus
        )
        XCTAssertEqual(receipt, duplicateReceipt)
        XCTAssertEqual(receipt.currentRunState, .paused)
        XCTAssertEqual(receipt.currentRunStateVersion, 5)
        let receiptWire = try encodedJSON(receipt)
        XCTAssertTrue(String(decoding: receiptWire, as: UTF8.self).contains("\"currentStatus\""))
        XCTAssertFalse(String(decoding: receiptWire, as: UTF8.self).contains("currentRunStateVersion"))
        XCTAssertEqual(
            try AgentWireDecoder.decode(AgentCommandReceipt.self, from: receiptWire),
            receipt
        )
        let forgedStatus = try replacingJSONField(
            in: receiptWire,
            path: ["currentStatus", "stateVersion"],
            with: 0
        )
        XCTAssertThrowsError(try AgentWireDecoder.decode(
            AgentCommandReceipt.self,
            from: forgedStatus
        ))
        XCTAssertThrowsError(
            try AgentCommandReceipt(
                commandID: commandID,
                runID: runID,
                disposition: .accepted,
                currentStatus: currentStatus,
                failure: TestValues.failure()
            )
        )
        XCTAssertThrowsError(
            try AgentCommandReceipt(
                commandID: commandID,
                runID: runID,
                disposition: .stale,
                currentStatus: currentStatus
            )
        )
        XCTAssertThrowsError(
            try UserInputResponse(
                requestID: TestValues.id(InteractionRequestIDDomain.self, 12),
                expectedRunStateVersion: 0,
                value: .string("no")
            )
        )
    }

    func testHashChainedEventPagesBindRequestStateTimeUsageAndTerminal() throws {
        let requestID = TestValues.id(AgentRequestIDDomain.self, 20)
        let handleID = TestValues.id(AgentExecutionHandleIDDomain.self, 21)
        let runID = TestValues.id(AgentRunIDDomain.self, 22)
        let records = try eventChain(requestID: requestID, handleID: handleID, runID: runID)
        let firstPage = try records.prefix(3).map { try AgentEnvelope(payload: $0) }
        try AgentEventSequenceValidator.validate(
            firstPage,
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID
        )
        let trusted = TrustedAgentEventCursor(cursor: records[2].cursor)
        let secondPage = try records.dropFirst(3).map { try AgentEnvelope(payload: $0) }
        try AgentEventSequenceValidator.validate(
            secondPage,
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID,
            after: trusted,
            requireTerminal: true
        )

        let terminalCursor = TrustedAgentEventCursor(cursor: records.last!.cursor)
        XCTAssertThrowsError(
            try AgentEventSequenceValidator.validate(
                [try AgentEnvelope(payload: records.last!)],
                requestID: requestID,
                executionHandleID: handleID,
                runID: runID,
                after: terminalCursor
            )
        )
        let tampered = try replacingJSONField(
            in: encodedJSON(records[1]),
            path: ["recordDigest"],
            with: TestValues.digest("9").rawValue
        )
        XCTAssertThrowsError(try AgentWireDecoder.decode(AgentEventRecord.self, from: tampered))
    }

    func testEventValidatorRejectsIllegalTransitionAndTimestampRegression() throws {
        let requestID = TestValues.id(AgentRequestIDDomain.self, 30)
        let handleID = TestValues.id(AgentExecutionHandleIDDomain.self, 31)
        let runID = TestValues.id(AgentRunIDDomain.self, 32)
        let firstStatus = try AgentRunStatus(state: .created, stateVersion: 1)
        let first = try AgentEventRecord(
            eventID: TestValues.id(AgentEventIDDomain.self, 33),
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID,
            sequence: 1,
            runStateVersion: 1,
            runState: .created,
            timestamp: AgentTimestamp(rawValue: 100),
            event: .statusChanged(firstStatus),
            redaction: TestValues.redaction(),
            cumulativeUsage: .zero,
            previousRecordDigest: nil
        )
        let completedStatus = try AgentRunStatus(
            state: .completed,
            stateVersion: 2,
            terminalReason: .completed
        )
        let result = try AgentResult(
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID,
            status: completedStatus,
            answer: AgentAnswer(text: "done"),
            usage: .zero
        )
        let illegal = try AgentEventRecord(
            eventID: TestValues.id(AgentEventIDDomain.self, 34),
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID,
            sequence: 2,
            runStateVersion: 2,
            runState: .completed,
            timestamp: AgentTimestamp(rawValue: 99),
            event: .terminal(result),
            redaction: TestValues.redaction(),
            cumulativeUsage: .zero,
            previousRecordDigest: first.recordDigest
        )
        XCTAssertThrowsError(
            try AgentEventSequenceValidator.validate(
                [try AgentEnvelope(payload: first), try AgentEnvelope(payload: illegal)],
                requestID: requestID,
                executionHandleID: handleID,
                runID: runID,
                requireTerminal: true
            )
        )
    }

    // TEST-ID: AHT-SUBAGENT-001
    func testExecutorContractValuesAndChildAttenuation() throws {
        let parentScope = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.localRead, .localWrite, .codeExecution]),
            artifactIDs: [TestValues.id(ArtifactIDDomain.self, 40)]
        )
        let childScope = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.localRead]),
            artifactIDs: [TestValues.id(ArtifactIDDomain.self, 40)]
        )
        let parentCeiling = RunCapabilityCeiling(authority: parentScope)
        let childCeiling = try parentCeiling.attenuating(to: childScope)
        let budget = TestValues.budget(limit: 100)
        let request = try AgentRequest(
            id: TestValues.id(AgentRequestIDDomain.self, 41),
            runID: TestValues.id(AgentRunIDDomain.self, 42),
            conversationID: TestValues.id(ConversationIDDomain.self, 43),
            userTurnID: TestValues.id(UserTurnIDDomain.self, 44),
            parent: ParentAgentContext(
                runID: TestValues.id(AgentRunIDDomain.self, 45),
                requestingStepID: TestValues.id(AgentStepIDDomain.self, 46),
                capabilityCeiling: parentCeiling
            ),
            role: "researcher",
            instruction: "Read the supplied local artifact.",
            outputRequirement: .text,
            modelPolicy: try localModelPolicy(),
            capabilityCeiling: childCeiling,
            budget: budget,
            provenance: AgentRequestProvenance(
                source: .parentAgent,
                parentRequestID: TestValues.id(AgentRequestIDDomain.self, 47)
            )
        )
        XCTAssertEqual(request.capabilityCeiling, childCeiling)
        XCTAssertThrowsError(
            try AgentRequest(
                id: TestValues.id(AgentRequestIDDomain.self, 48),
                runID: TestValues.id(AgentRunIDDomain.self, 49),
                conversationID: TestValues.id(ConversationIDDomain.self, 50),
                userTurnID: TestValues.id(UserTurnIDDomain.self, 51),
                parent: request.parent,
                role: "peer",
                instruction: "Do not attenuate.",
                outputRequirement: .text,
                modelPolicy: localModelPolicy(),
                capabilityCeiling: parentCeiling,
                budget: budget,
                provenance: AgentRequestProvenance(
                    source: .parentAgent,
                    parentRequestID: request.id
                )
            )
        )
    }

    func testSandboxRequirementFingerprintAndTrustedExecutionProof() throws {
        let artifact = TestValues.id(ArtifactIDDomain.self, 60)
        let workspace = TestValues.id(SandboxWorkspaceHandleIDDomain.self, 61)
        let checkpoint = TestValues.id(SandboxCheckpointHandleIDDomain.self, 62)
        let secret = try SecretReference(
            id: TestValues.id(SecretReferenceIDDomain.self, 63),
            purpose: "package registry",
            providerID: "keychain"
        )
        let authority = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.localRead, .localWrite, .codeExecution]),
            artifactIDs: [artifact],
            secretReferenceIDs: [secret.id],
            workspaceIDs: [workspace],
            checkpointIDs: [checkpoint]
        )
        let budget = TestValues.budget(limit: 10_000)
        let requirement = try SandboxRequirement(
            minimumProtocolVersion: SemanticVersion("1.0.0")!,
            workspaceID: workspace,
            checkpointID: checkpoint,
            authority: authority,
            budget: budget,
            filesystem: [SandboxFilesystemRequirement(
                logicalRoot: "workspace.root",
                access: .readWrite,
                artifactIDs: [artifact],
                maximumWrittenBytes: 100
            )],
            process: SandboxProcessRequirement(
                maximumConcurrentProcesses: 1,
                maximumProcessLaunches: 2,
                allowedRuntimeIDs: ["runtime.swift"]
            ),
            secretReferences: [secret]
        )
        let grant = try StepCapabilityGrant(
            runCeiling: RunCapabilityCeiling(authority: authority),
            authority: authority
        )
        let trusted = try TrustedRunAuthority(
            runID: TestValues.id(AgentRunIDDomain.self, 64),
            ceiling: grant.runCeiling,
            policyRevision: 1
        )
        XCTAssertNoThrow(
            try requirement.validateForExecution(
                runID: trusted.runID,
                stepGrant: grant,
                parentBudget: budget,
                trustedRunAuthority: trusted
            )
        )
        XCTAssertThrowsError(
            try requirement.validateForExecution(
                runID: TestValues.id(AgentRunIDDomain.self, 67),
                stepGrant: grant,
                parentBudget: budget,
                trustedRunAuthority: trusted
            )
        )
        let withoutCheckpoint = try SandboxRequirement(
            minimumProtocolVersion: SemanticVersion("1.0.0")!,
            workspaceID: workspace,
            authority: authority,
            budget: budget,
            filesystem: requirement.filesystem,
            process: requirement.process,
            secretReferences: requirement.secretReferences
        )
        XCTAssertNotEqual(requirement.fingerprint, withoutCheckpoint.fingerprint)

        let sandboxCursor = try SandboxEventCursor(
            executionHandleID: TestValues.id(SandboxExecutionHandleIDDomain.self, 65),
            eventID: TestValues.id(SandboxEventIDDomain.self, 66),
            sequence: 1
        )
        XCTAssertEqual(
            try AgentWireDecoder.decode(SandboxEventCursor.self, from: encodedJSON(sandboxCursor)),
            sandboxCursor
        )
        let forgedZero = try replacingJSONField(
            in: encodedJSON(sandboxCursor),
            path: ["sequence"],
            with: 0
        )
        XCTAssertThrowsError(try AgentWireDecoder.decode(SandboxEventCursor.self, from: forgedZero))
    }
}

private extension ExecutionAndSandboxTests {
    func localModelPolicy() throws -> AgentModelPolicy {
        let selection = AgentModelSelection(
            providerID: try AgentModelProviderID("local"),
            modelID: try AgentModelID("bonsai"),
            variantID: try AgentModelVariantID("8b-1bit"),
            capabilityVersion: SemanticVersion("1.0.0")!
        )
        return try AgentModelPolicy(
            localOnly: true,
            allowedSelections: [selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
    }

    func eventChain(
        requestID: AgentRequestID,
        handleID: AgentExecutionHandleID,
        runID: AgentRunID
    ) throws -> [AgentEventRecord] {
        let states: [AgentRunState] = [
            .created, .preparing, .waitingForModel, .generating, .validatingAction,
        ]
        var records: [AgentEventRecord] = []
        for (index, state) in states.enumerated() {
            let version = UInt64(index + 1)
            let status = try AgentRunStatus(
                state: state,
                stateVersion: version,
                blockingReason: state == .waitingForModel ? .modelResource : nil
            )
            let record = try AgentEventRecord(
                eventID: TestValues.id(AgentEventIDDomain.self, UInt16(100 + index)),
                requestID: requestID,
                executionHandleID: handleID,
                runID: runID,
                sequence: version,
                runStateVersion: version,
                runState: state,
                timestamp: AgentTimestamp(rawValue: Int64(1_000 + index)),
                event: .statusChanged(status),
                redaction: TestValues.redaction(),
                cumulativeUsage: .zero,
                previousRecordDigest: records.last?.recordDigest
            )
            records.append(record)
        }
        let usage = AgentUsage(quantities: BudgetQuantities([.outputTokens: 3]))
        let terminalStatus = try AgentRunStatus(
            state: .completed,
            stateVersion: 6,
            terminalReason: .completed
        )
        let result = try AgentResult(
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID,
            status: terminalStatus,
            answer: AgentAnswer(text: "done"),
            usage: usage
        )
        records.append(try AgentEventRecord(
            eventID: TestValues.id(AgentEventIDDomain.self, 105),
            requestID: requestID,
            executionHandleID: handleID,
            runID: runID,
            sequence: 6,
            runStateVersion: 6,
            runState: .completed,
            timestamp: AgentTimestamp(rawValue: 1_005),
            event: .terminal(result),
            redaction: TestValues.redaction(),
            cumulativeUsage: usage,
            previousRecordDigest: records.last?.recordDigest
        ))
        return records
    }
}
