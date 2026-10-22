// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-RUN-002
// TEST-ID: AHT-CHAT-001
// TEST-ID: AHT-OUTBOX-001
final class AgentExecutorCoreIntegrationTests: XCTestCase {
    func testEraseSuspendsAdmissionAndArtifactStoreCanStartFresh() async throws {
        let model = try ExecutorTestModelDefinition(offset: 950)
        let harness = try ExecutorTestHarness(offset: 950,
            provider: FixedCompletionModelProvider(model: model, answer: "private answer"), model: model)
        let handle = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(950))
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: handle))
        try await harness.executor.controller.suspendForDataErase()
        do {
            _ = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(950))
            XCTFail("erase gate must reject submissions even when idempotent")
        } catch AgentExecutionError.internalInvariant { }
        let files = harness.payloadStore.store
        try await files.eraseAllData()
        let content = Data("after erase".utf8)
        let record = try await harness.payloadStore.commit(data: content, mimeType: "text/plain", semanticType: "fixture",
            runID: harness.request.runID, stepID: nil, invocationID: nil, owner: .run(harness.request.runID), sensitivity: .personalData)
        let loaded = try await files.data(for: record.id)
        XCTAssertEqual(loaded, content)
        await harness.executor.controller.resumeAfterDataErase()
    }

    func testInternalWorkflowRunsSharingOneOriginStayRunScopedAndOutOfChat() async throws {
        let model = try ExecutorTestModelDefinition(offset: 92)
        let originMessageID = MessageID(rawValue: ExecutorTestID.uuid(92_001))
        let provenance = AgentRequestProvenance(
            source: .workflow,
            sourceMessageID: originMessageID
        )
        let harness = try ExecutorTestHarness(
            offset: 92,
            provider: try FixedCompletionModelProvider(model: model, answer: "internal result"),
            model: model,
            provenance: provenance
        )

        let firstHandleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(92)
        )
        _ = try await collectTerminalEvents(
            from: harness.executor.attach(to: firstHandleID)
        )

        let second = try AgentRequest(
            id: ExecutorTestID.request(93),
            runID: ExecutorTestID.run(93),
            conversationID: harness.request.conversationID,
            userTurnID: harness.request.userTurnID,
            role: "workflow-generator",
            instruction: "Repair the internal workflow candidate.",
            outputRequirement: harness.request.outputRequirement,
            modelPolicy: harness.request.modelPolicy,
            capabilityCeiling: harness.request.capabilityCeiling,
            budget: harness.request.budget,
            provenance: provenance,
            approvalMode: harness.request.approvalMode
        )
        let secondHandleID = try await harness.executor.submit(
            second,
            commandID: ExecutorTestID.command(93)
        )
        _ = try await collectTerminalEvents(
            from: harness.executor.attach(to: secondHandleID)
        )

        let database = try SQLiteConnection(url: harness.databaseURL, create: false, readOnly: true)
        defer { database.close() }
        let rows = try database.rows(
            "SELECT run_id, role, message_id FROM messages ORDER BY run_id, role"
        )
        XCTAssertEqual(rows.count, 4)
        XCTAssertFalse(rows.contains { $0[2].text == originMessageID.description })
        XCTAssertEqual(Set(try database.rows(
            "SELECT kind FROM projection_outbox ORDER BY idempotency_key"
        ).compactMap { $0[0].text }), [
            ProjectionOutboxItem.Kind.internalRunAccepted.rawValue,
            ProjectionOutboxItem.Kind.internalRunFinalized.rawValue,
        ])
        XCTAssertEqual(try database.scalarInt(
            "SELECT COUNT(*) FROM projection_outbox WHERE kind IN ('acceptedUserMessage', 'finalAnswer')"
        ), 0)
    }

    func testCallerOwnedMessageIdentitiesFlowThroughBothJournalOutboxRows() async throws {
        let model = try ExecutorTestModelDefinition(offset: 91)
        let userMessageID = MessageID(rawValue: ExecutorTestID.uuid(91_001))
        let assistantMessageID = MessageID(rawValue: ExecutorTestID.uuid(91_002))
        let harness = try ExecutorTestHarness(
            offset: 91,
            provider: try FixedCompletionModelProvider(model: model, answer: "Bound answer"),
            model: model,
            provenance: AgentRequestProvenance(
                source: .user,
                sourceMessageID: userMessageID,
                responseMessageID: assistantMessageID
            )
        )

        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(91)
        )
        let handle = try await harness.executor.attach(to: handleID)
        _ = try await collectTerminalEvents(from: handle)

        let database = try SQLiteConnection(url: harness.databaseURL, create: false, readOnly: true)
        let storedUserID = try XCTUnwrap(database.scalarText(
            "SELECT message_id FROM messages WHERE run_id = ? AND role = 'user'",
            [.text(harness.request.runID.description)]
        ))
        let storedAssistantID = try XCTUnwrap(database.scalarText(
            "SELECT message_id FROM messages WHERE run_id = ? AND role = 'assistant'",
            [.text(harness.request.runID.description)]
        ))
        XCTAssertEqual(storedUserID, userMessageID.description)
        XCTAssertEqual(storedAssistantID, assistantMessageID.description)

        let pendingOutbox = try database.rows(
            "SELECT kind, message_id FROM projection_outbox WHERE run_id = ? ORDER BY kind",
            [.text(harness.request.runID.description)]
        )
        XCTAssertEqual(pendingOutbox.count, 2)
        XCTAssertEqual(Set(pendingOutbox.compactMap { $0.dropFirst().first?.text }), [
            userMessageID.description, assistantMessageID.description,
        ])
    }

    func testCompletedExecutionReattachesAfterRepositoryReopenWithoutRestartingWork() async throws {
        let model = try ExecutorTestModelDefinition(offset: 0)
        let counter = ScriptedInvocationCounter()
        let provider = try FixedCompletionModelProvider(
            model: model,
            answer: "Durable across restart",
            invocationCounter: counter
        )
        let harness = try ExecutorTestHarness(
            offset: 0,
            provider: provider,
            model: model
        )
        let commandID = ExecutorTestID.command(0)
        let handleID = try await harness.executor.submit(harness.request, commandID: commandID)
        let original = try await harness.executor.attach(to: handleID)
        let originalEvents = try await collectTerminalEvents(from: original)
        try await waitForWorkerToStop(harness.request.runID, controller: harness.executor.controller)
        await harness.repository.close()

        let reopenedRepository = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = DurableAgentExecutor(
            repository: reopenedRepository,
            payloadStore: harness.payloadStore,
            inputFreezer: StaticAgentRunInputFreezer(inputs: harness.frozenInputs),
            modelProviders: try StaticAgentModelProviderCatalog(providers: [provider]),
            policyEngine: try DefaultApprovalPolicyEngine(
                policyVersion: 1,
                sanitizationValidator: harness.attestor
            ),
            sanitizer: harness.attestor,
            residencyDriver: ScriptedModelResidencyDriver(),
            clock: FixedExecutorClock()
        )
        let reattached = try await restarted.attach(to: handleID)
        let replayedEvents = try await collectTerminalEvents(from: reattached)
        XCTAssertEqual(replayedEvents, originalEvents)
        let result = try await reattached.result()
        XCTAssertEqual(result?.answer?.text, "Durable across restart")
        let terminalStatus = try await reattached.status()
        let resumeTerminal = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(90_000),
            runID: harness.request.runID,
            expectedRunStateVersion: terminalStatus.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let rejected = try await reattached.send(resumeTerminal)
        XCTAssertEqual(rejected.disposition, .rejected)
        XCTAssertEqual(rejected.failure?.code, "execution.command-terminal")
        XCTAssertEqual(rejected.currentStatus, terminalStatus)
        let replayedRejection = try await reattached.send(resumeTerminal)
        XCTAssertEqual(replayedRejection, rejected)
        let eventsAfterRejectedMutation = try await collectTerminalEvents(from: reattached)
        XCTAssertEqual(eventsAfterRejectedMutation, originalEvents)
        let replayedHandle = try await restarted.submit(harness.request, commandID: commandID)
        XCTAssertEqual(replayedHandle, handleID)
        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 1)
    }

    func testSubmitAttachAndSubmissionIdempotencyAreDurableAndConflictClosed() async throws {
        let model = try ExecutorTestModelDefinition(offset: 1)
        let counter = ScriptedInvocationCounter()
        let provider = try FixedCompletionModelProvider(
            model: model,
            answer: "Idempotent answer",
            invocationCounter: counter
        )
        let harness = try ExecutorTestHarness(
            offset: 1,
            provider: provider,
            model: model
        )
        let commandID = ExecutorTestID.command(1)

        async let firstSubmission = harness.executor.submit(harness.request, commandID: commandID)
        async let racingReplay = harness.executor.submit(harness.request, commandID: commandID)
        let handles = try await [firstSubmission, racingReplay]
        XCTAssertEqual(handles[0], handles[1])

        let handle = try await harness.executor.attach(to: handles[0])
        let events = try await collectTerminalEvents(from: handle)
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
        let invocationCountAfterCompletion = await counter.count()
        XCTAssertEqual(
            invocationCountAfterCompletion,
            1,
            "submission replay must not schedule a second worker"
        )

        let exactReplay = try await harness.executor.submit(harness.request, commandID: commandID)
        XCTAssertEqual(exactReplay, handles[0])
        let invocationCountAfterReplay = await counter.count()
        XCTAssertEqual(invocationCountAfterReplay, 1)

        let changed = try requestByChangingInstruction(
            harness.request,
            to: "A different immutable request body."
        )
        await assertExecutorError(.submissionCommandConflict(commandID)) {
            _ = try await harness.executor.submit(changed, commandID: commandID)
        }
        let otherCommand = ExecutorTestID.command(2)
        await assertExecutorError(.requestRunAlreadyExists(harness.request.runID)) {
            _ = try await harness.executor.submit(harness.request, commandID: otherCommand)
        }
        let missing = AgentExecutionHandleID(rawValue: ExecutorTestID.uuid(99_001))
        await assertExecutorError(.executionNotFound(missing)) {
            _ = try await harness.executor.attach(to: missing)
        }

        let submissionRows = try await harness.repository.rowCount(table: "run_submissions")
        let messageRows = try await harness.repository.rowCount(table: "messages")
        XCTAssertEqual(submissionRows, 1)
        XCTAssertEqual(messageRows, 2, "one accepted user message and one final assistant message")
    }

    func testPureChatUsesOneModelPassCommitsOneTerminalAndDrainsEveryLease() async throws {
        let model = try ExecutorTestModelDefinition(offset: 2)
        let counter = ScriptedInvocationCounter()
        let provider = try FixedCompletionModelProvider(
            model: model,
            answer: "One pass only.",
            invocationCounter: counter
        )
        let harness = try ExecutorTestHarness(
            offset: 2,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(20)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)
        let eventDiagnostics = events.map { String(describing: $0.payload.event) }.joined(separator: "\n")

        let invocationCount = await counter.count()
        let lifecycle = await provider.lifecycle.snapshot()
        let logEntries = await harness.logger.snapshot()
        let executionDiagnostics = eventDiagnostics + "\nlifecycle=\(lifecycle) logs="
            + logEntries.map { "\($0.code):\($0.metadata)" }.joined(separator: " | ")
        XCTAssertEqual(invocationCount, 1, executionDiagnostics)
        XCTAssertEqual(events.map(\.payload.sequence), Array(1 ... UInt64(events.count)))
        XCTAssertEqual(events.first?.payload.previousRecordDigest, nil)
        for (previous, current) in zip(events, events.dropFirst()) {
            XCTAssertEqual(current.payload.previousRecordDigest, previous.payload.recordDigest)
        }
        XCTAssertEqual(events.filter { event in
            if case .modelAttemptOutcome = event.payload.event { return true }
            return false
        }.count, 1)
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)

        let status = try await handle.status()
        let loadedResult = try await handle.result()
        let result = try XCTUnwrap(loadedResult)
        XCTAssertEqual(status.state, .completed, eventDiagnostics)
        XCTAssertEqual(status.terminalReason, .completed)
        XCTAssertEqual(result.answer?.text, "One pass only.")
        XCTAssertEqual(result.usage.quantities[.modelAttempts], 1)
        XCTAssertEqual(result.usage.quantities[.inputTokens], 12)
        XCTAssertEqual(result.usage.quantities[.outputTokens], 3)

        let loadedFacts = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let facts = try XCTUnwrap(loadedFacts)
        XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
        XCTAssertEqual(facts.budgetLedger?.consumed, result.usage)

        let inputArtifactID = try XCTUnwrap(facts.submission?.inputSnapshot.artifactID)
        let loadedInputArtifact = await harness.payloadStore.reference(for: inputArtifactID)
        let inputArtifact = try XCTUnwrap(loadedInputArtifact)
        XCTAssertEqual(inputArtifact.mimeType, "application/json")
        XCTAssertEqual(inputArtifact.semanticType, "agent-run-input.v1")

        let database = try SQLiteConnection(
            url: harness.databaseURL,
            create: false,
            readOnly: true
        )
        let userArtifactIDValue = try XCTUnwrap(database.scalarText(
            "SELECT body_artifact_id FROM messages WHERE run_id = ? AND role = 'user'",
            [.text(harness.request.runID.description)]
        ))
        let userArtifactID = try XCTUnwrap(ArtifactID(userArtifactIDValue))
        let loadedUserArtifact = await harness.payloadStore.reference(for: userArtifactID)
        let userArtifact = try XCTUnwrap(loadedUserArtifact)
        XCTAssertEqual(userArtifact.mimeType, "application/octet-stream")
        XCTAssertEqual(userArtifact.semanticType, "agent-user-message.v2")
        let userBytes = try await harness.payloadStore.load(
            userArtifact,
            maximumBytes: userArtifact.byteCount
        )
        let acceptedMessage = try AcceptedUserMessagePayload.decode(userBytes)
        XCTAssertEqual(acceptedMessage.text, harness.frozenInputs.currentUser.frozen.content)
        XCTAssertEqual(acceptedMessage.attachments, harness.frozenInputs.currentUser.artifacts)

        let structuredArtifacts = events.compactMap { event -> ArtifactReference? in
            if case .artifactCommitted(let reference) = event.payload.event { return reference }
            return nil
        }
        let expectedStructuredSemanticTypes = [
            "agent-compiled-context.standard.v1",
            "agent-action.v1",
            "agent-final-answer.v1",
        ]
        for semanticType in expectedStructuredSemanticTypes {
            let artifact = try XCTUnwrap(
                structuredArtifacts.first { $0.semanticType == semanticType },
                "missing \(semanticType) artifact"
            )
            XCTAssertEqual(artifact.mimeType, "application/json", semanticType)
            let bytes = try await harness.payloadStore.load(
                artifact,
                maximumBytes: artifact.byteCount
            )
            XCTAssertEqual(artifact.contentDigest, StableDigest.sha256(bytes), semanticType)
        }

        let arbiter = await harness.executor.controller.arbiter.snapshot()
        XCTAssertNil(arbiter.rootOwner)
        XCTAssertNil(arbiter.decodeOwner)
        XCTAssertNil(arbiter.residencyTransition)
        XCTAssertEqual(arbiter.metrics.maxRootOwners, 1)
        XCTAssertEqual(arbiter.metrics.maxDecodeOwners, 1)
        let driver = await harness.residencyDriver.snapshot()
        XCTAssertEqual(driver.lifecycleViolations, 0)
        XCTAssertEqual(driver.calls.map(\.operation), [.load])
    }

    func testCursorReplayReturnsOnlyTailAndRejectsForeignOrForgedAnchors() async throws {
        let model = try ExecutorTestModelDefinition(offset: 3)
        let provider = try FixedCompletionModelProvider(model: model, answer: "Replay answer")
        let harness = try ExecutorTestHarness(
            offset: 3,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(30)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let all = try await collectTerminalEvents(from: handle)
        guard all.count > 5 else {
            return XCTFail("expected a replayable event chain, got \(all.count) events")
        }
        let anchor = all[all.count / 2]

        let tail = try await collectTerminalEvents(from: handle, after: anchor.payload.cursor)
        XCTAssertEqual(tail, Array(all.dropFirst(Int(anchor.payload.sequence))))

        let foreignHandle = AgentExecutionHandleID(rawValue: ExecutorTestID.uuid(99_030))
        let foreign = try AgentEventCursor(
            executionHandleID: foreignHandle,
            eventID: anchor.payload.eventID,
            sequence: anchor.payload.sequence,
            runStateVersion: anchor.payload.runStateVersion,
            runState: anchor.payload.runState,
            timestamp: anchor.payload.timestamp,
            cumulativeUsage: anchor.payload.cumulativeUsage,
            recordDigest: anchor.payload.recordDigest,
            isTerminal: false
        )
        await assertExecutorError(.cursorBelongsToAnotherExecution) {
            _ = try await collectTerminalEvents(from: handle, after: foreign)
        }

        let forged = try AgentEventCursor(
            executionHandleID: handleID,
            eventID: anchor.payload.eventID,
            sequence: anchor.payload.sequence,
            runStateVersion: anchor.payload.runStateVersion,
            runState: anchor.payload.runState,
            timestamp: anchor.payload.timestamp,
            cumulativeUsage: anchor.payload.cumulativeUsage,
            recordDigest: StableDigest.sha256(Data("forged-cursor".utf8)),
            isTerminal: false
        )
        await assertExecutorError(.cursorIntegrityMismatch) {
            _ = try await collectTerminalEvents(from: handle, after: forged)
        }
    }

    func testEndingSubscriptionDetachesObserverWithoutCancellingBlockedExecution() async throws {
        let model = try ExecutorTestModelDefinition(offset: 4)
        let gate = BlockingModelGate()
        let counter = ScriptedInvocationCounter()
        let provider = try BlockingCompletionModelProvider(
            model: model,
            answer: "Completed after observer detached.",
            gate: gate,
            invocationCounter: counter
        )
        let harness = try ExecutorTestHarness(
            offset: 4,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(40)
        )
        let handle = try await harness.executor.attach(to: handleID)
        addTeardownBlock { await gate.release() }

        try await waitForExecutorCondition { await gate.hasEntered() }
        let first = try await consumeFirstReplayedEvent(from: handle)
        XCTAssertEqual(first.payload.sequence, 1)
        let generatingStatus = try await handle.status()
        XCTAssertEqual(generatingStatus.state, .generating)

        await gate.release()
        let replayed = try await collectTerminalEvents(from: handle)
        let completedResult = try await handle.result()
        XCTAssertEqual(completedResult?.answer?.text, "Completed after observer detached.")
        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(replayed.first?.payload.sequence, 1)
        XCTAssertTrue(replayed.last?.payload.event.isRunTerminal == true)
    }
}

private func consumeFirstReplayedEvent(
    from handle: any AgentExecutionHandle
) async throws -> AgentEventEnvelope {
    for try await event in handle.events(after: nil) { return event }
    throw ExecutorIntegrationTestError.streamEndedUnexpectedly
}

private func requestByChangingInstruction(
    _ request: AgentRequest,
    to instruction: String
) throws -> AgentRequest {
    try AgentRequest(
        id: request.id,
        runID: request.runID,
        conversationID: request.conversationID,
        userTurnID: request.userTurnID,
        parent: request.parent,
        role: request.role,
        instruction: instruction,
        outputRequirement: request.outputRequirement,
        modelPolicy: request.modelPolicy,
        capabilityCeiling: request.capabilityCeiling,
        budget: request.budget,
        contextReferences: request.contextReferences,
        artifactReferences: request.artifactReferences,
        sandboxRequirement: request.sandboxRequirement,
        labels: request.labels,
        provenance: request.provenance
    )
}

private func assertExecutorError(
    _ expected: AgentExecutionError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as AgentExecutionError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
