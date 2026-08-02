// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-RUN-003
// TEST-ID: AHT-LIFECYCLE-001
final class AgentExecutorCommandIntegrationTests: XCTestCase {
    func testUserInputResponseIsSchemaCheckedCASBoundDurableAndIdempotent() async throws {
        let offset = 199
        let model = try ExecutorTestModelDefinition(offset: offset)
        let script = UserInputModelScript()
        let interactionID = InteractionRequestID(rawValue: ExecutorTestID.uuid(77_199))
        let provider = try UserInputThenAnswerModelProvider(
            model: model,
            runID: ExecutorTestID.run(offset),
            interactionID: interactionID,
            answer: "Used option B",
            script: script
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(190)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let waiting = try await waitForStatus(.waitingForUser, handle: handle)
        guard case .userInput(let requestedID) = waiting.blockingReason else {
            return XCTFail("Expected user-input blocking reason")
        }
        XCTAssertEqual(requestedID, interactionID)

        let invalidResponse = try UserInputResponse(
            requestID: interactionID,
            expectedRunStateVersion: waiting.stateVersion,
            value: .string("C")
        )
        let invalidCommand = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(191),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .respond(invalidResponse),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let invalidReceipt = try await handle.send(invalidCommand)
        XCTAssertEqual(invalidReceipt.disposition, .rejected)
        XCTAssertEqual(invalidReceipt.currentStatus.state, .waitingForUser)

        let response = try UserInputResponse(
            requestID: interactionID,
            expectedRunStateVersion: waiting.stateVersion,
            value: .string("B")
        )
        let responseCommand = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(192),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .respond(response),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let responseReceipt = try await handle.send(responseCommand)
        XCTAssertEqual(responseReceipt.disposition, .accepted)
        XCTAssertEqual(responseReceipt.currentStatus.state, .waitingForModel)
        let replayedReceipt = try await handle.send(responseCommand)
        XCTAssertEqual(replayedReceipt, responseReceipt)

        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        let diagnostics = events.map { String(describing: $0.payload.event) }.joined(separator: "\n")
        XCTAssertEqual(result?.answer?.text, "Used option B", diagnostics)
        XCTAssertEqual(result?.status.state, .completed, diagnostics)
        XCTAssertEqual(events.filter { event in
            if case .userInputResponseCommitted = event.payload.event { return true }
            return false
        }.count, 1)
        let requests = await script.capturedRequests()
        guard requests.count == 2 else {
            return XCTFail("expected user-input request plus resumed model pass, got \(requests.count)")
        }
        XCTAssertTrue(requests[1].messages.contains { message in
            message.role == .user && message.content.contains("\"B\"")
        })
    }

    func testPauseQuiescesAndResumeContinuesWithIdempotentCommandReceipts() async throws {
        let model = try ExecutorTestModelDefinition(offset: 200)
        let script = PauseThenAnswerModelScript()
        let provider = try PauseThenAnswerModelProvider(
            model: model,
            answer: "Answer after resume",
            script: script
        )
        let harness = try ExecutorTestHarness(
            offset: 200,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(200)
        )
        let handle = try await harness.executor.attach(to: handleID)
        try await waitForExecutorCondition { await script.hasStartedFirstAttempt() }
        let generating = try await handle.status()
        XCTAssertEqual(generating.state, .generating)

        let pauseCommand = try AgentCommand(
            commandID: ExecutorTestID.command(201),
            runID: harness.request.runID,
            expectedRunStateVersion: generating.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )
        let pauseEnvelope = try AgentCommandEnvelope(payload: pauseCommand)
        let pauseReceipt = try await handle.send(pauseEnvelope)
        XCTAssertEqual(pauseReceipt.disposition, .accepted)
        XCTAssertEqual(pauseReceipt.currentStatus.state, .pausing)
        let exactPauseReplay = try await handle.send(pauseEnvelope)
        XCTAssertEqual(exactPauseReplay, pauseReceipt)

        let paused = try await waitForStatus(.paused, handle: handle)
        XCTAssertEqual(paused.blockingReason?.kind, .paused)
        try await waitForWorkerToStop(harness.request.runID, controller: harness.executor.controller)
        let pausedFactsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let pausedFacts = try XCTUnwrap(pausedFactsValue)
        XCTAssertTrue(pausedFacts.budgetLedger?.reservations.isEmpty == true)
        let pausedArbiter = await harness.executor.controller.arbiter.snapshot()
        XCTAssertNil(pausedArbiter.rootOwner)
        XCTAssertNil(pausedArbiter.decodeOwner)

        let resumeCommand = try AgentCommand(
            commandID: ExecutorTestID.command(202),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )
        let resumeEnvelope = try AgentCommandEnvelope(payload: resumeCommand)
        let resumeReceipt = try await handle.send(resumeEnvelope)
        XCTAssertEqual(resumeReceipt.disposition, .accepted)
        XCTAssertEqual(resumeReceipt.currentStatus.state, .preparing)
        let exactResumeReplay = try await handle.send(resumeEnvelope)
        XCTAssertEqual(exactResumeReplay, resumeReceipt)

        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        let diagnostics = events.map { String(describing: $0.payload.event) }.joined(separator: "\n")
        XCTAssertEqual(result?.answer?.text, "Answer after resume", diagnostics)
        XCTAssertEqual(result?.status.state, .completed, diagnostics)
        let requests = await script.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(events.filter { event in
            if case .modelAttemptOutcome(.interrupted) = event.payload.event { return true }
            return false
        }.count, 1)
        let residency = await harness.residencyDriver.snapshot()
        XCTAssertEqual(residency.calls.map(\.operation), [.load, .cancelAndDrain])
        XCTAssertEqual(residency.lifecycleViolations, 0)
    }

    func testCancelDuringGenerationTerminatesAtSafeBoundaryAndStaleCommandCannotMutate() async throws {
        let model = try ExecutorTestModelDefinition(offset: 201)
        let script = PauseThenAnswerModelScript()
        let provider = try PauseThenAnswerModelProvider(
            model: model,
            answer: "Must not be emitted",
            script: script
        )
        let harness = try ExecutorTestHarness(
            offset: 201,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(210)
        )
        let handle = try await harness.executor.attach(to: handleID)
        try await waitForExecutorCondition { await script.hasStartedFirstAttempt() }
        let generating = try await handle.status()

        let stale = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(211),
            runID: harness.request.runID,
            expectedRunStateVersion: max(1, generating.stateVersion - 1),
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let staleReceipt = try await handle.send(stale)
        XCTAssertEqual(staleReceipt.disposition, .stale)
        XCTAssertEqual(staleReceipt.currentStatus.state, .generating)

        let cancel = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(212),
            runID: harness.request.runID,
            expectedRunStateVersion: generating.stateVersion,
            action: .cancel,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let cancellationReceipt = try await handle.send(cancel)
        XCTAssertEqual(cancellationReceipt.disposition, .accepted)
        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .cancelled)
        XCTAssertEqual(result?.status.terminalReason, .cancelledByUser)
        XCTAssertEqual(result?.status.failure?.code, "execution.cancelled")
        XCTAssertNil(result?.answer)
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
        let attempts = await script.capturedRequests()
        XCTAssertEqual(attempts.count, 1)
        let factsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let facts = try XCTUnwrap(factsValue)
        XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
        let arbiter = await harness.executor.controller.arbiter.snapshot()
        XCTAssertNil(arbiter.rootOwner)
        XCTAssertNil(arbiter.decodeOwner)
        let residency = await harness.residencyDriver.snapshot()
        XCTAssertEqual(residency.calls.map(\.operation), [.load, .cancelAndDrain])
    }

    func testPauseInterruptsLivePureReadToolThenResumeRetriesTheToolAttempt() async throws {
        try await assertSafeToolInterruptionResumes(
            offset: 202,
            effect: .networkRead,
            idempotency: .pureRead,
            behavior: .blockFirstAttemptInsideBoundaryThenComplete("read after resume"),
            expectedBoundaryCount: 2
        )
    }

    func testPauseInterruptsIdempotencyKeyWriteBeforeBoundaryThenResumeReusesIntent() async throws {
        try await assertSafeToolInterruptionResumes(
            offset: 203,
            effect: .externalWrite,
            idempotency: .idempotencyKeyRequired,
            behavior: .blockFirstAttemptBeforeBoundaryThenComplete("write after resume"),
            expectedBoundaryCount: 1
        )
    }

    func testPauseDuringRiskyBoundaryRequiresReconciliationInsteadOfPausing() async throws {
        try await assertRiskyBoundaryInterruptionRequiresReconciliation(
            offset: 204,
            action: .pause(reason: .userRequested)
        )
    }

    func testCancelDuringRiskyBoundaryRequiresReconciliationInsteadOfTerminalizing() async throws {
        try await assertRiskyBoundaryInterruptionRequiresReconciliation(
            offset: 205,
            action: .cancel
        )
    }

    private func assertSafeToolInterruptionResumes(
        offset: Int,
        effect: AgentEffect,
        idempotency: ExternalIdempotency,
        behavior: ExecutorTestToolBehavior,
        expectedBoundaryCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let retry = try ExternalRetryPolicy(
            kind: .boundedExponential,
            maximumAttempts: 2,
            baseDelayMilliseconds: 1,
            maximumDelayMilliseconds: 1,
            allowsJitter: false
        )
        let definition = try ExecutorTestToolDefinition(
            name: "interrupt-safe-\(offset)",
            effect: effect,
            retryPolicy: retry,
            idempotency: idempotency
        )
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Answer after interrupted tool",
            script: modelScript
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: behavior,
            counter: counter
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(1_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        try await approvePendingTool(handle: handle, harness: harness, offset: offset)
        try await waitForExecutorCondition {
            let counts = await counter.snapshot()
            if case .blockFirstAttemptInsideBoundaryThenComplete = behavior {
                return counts.boundaries == 1
            }
            return counts.executions == 1
        }
        let executing = try await handle.status()
        XCTAssertEqual(executing.state, .executingTools, file: file, line: line)

        let pause = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(2_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let pauseReceipt = try await handle.send(pause)
        XCTAssertEqual(pauseReceipt.disposition, .accepted, file: file, line: line)
        XCTAssertEqual(pauseReceipt.currentStatus.state, .pausing, file: file, line: line)
        let replayedPauseReceipt = try await handle.send(pause)
        XCTAssertEqual(replayedPauseReceipt, pauseReceipt, file: file, line: line)

        let paused = try await waitForStatus(.paused, handle: handle)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let pausedFactsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let pausedFacts = try XCTUnwrap(pausedFactsValue)
        XCTAssertTrue(pausedFacts.budgetLedger?.reservations.isEmpty == true, file: file, line: line)

        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(3_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let resumeReceipt = try await handle.send(resume)
        XCTAssertEqual(resumeReceipt.disposition, .accepted, file: file, line: line)
        let replayedResumeReceipt = try await handle.send(resume)
        XCTAssertEqual(replayedResumeReceipt, resumeReceipt, file: file, line: line)

        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        let diagnostics = events.map { String(describing: $0.payload.event) }.joined(separator: "\n")
        XCTAssertEqual(result?.status.state, .completed, diagnostics, file: file, line: line)
        XCTAssertEqual(
            result?.answer?.text,
            "Answer after interrupted tool",
            diagnostics,
            file: file,
            line: line
        )
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 1, file: file, line: line)
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.preparations, 1, file: file, line: line)
        XCTAssertEqual(counts.executions, 2, file: file, line: line)
        XCTAssertEqual(counts.boundaries, expectedBoundaryCount, file: file, line: line)
        XCTAssertEqual(events.filter { event in
            guard case .diagnostic(let failure) = event.payload.event else { return false }
            return failure.code == "execution.tool-attempt-interrupted"
                && failure.details["invocationID"] == call.invocationID.description
        }.count, 1, file: file, line: line)
        XCTAssertEqual(events.filter { event in
            if case .toolOutcomeRecorded(let invocationID, .completed) = event.payload.event {
                return invocationID == call.invocationID
            }
            return false
        }.count, 1, file: file, line: line)
        let durableTools = try await harness.repository.loadToolInvocations(for: harness.request.runID)
        XCTAssertEqual(durableTools.count, 1, file: file, line: line)
        XCTAssertEqual(durableTools.first?.request.plan.idempotencyKey, definition.idempotencyKey)
    }

    private func assertRiskyBoundaryInterruptionRequiresReconciliation(
        offset: Int,
        action: AgentCommandAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "interrupt-risky-\(offset)",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "must await reconciliation"
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .blockFirstAttemptInsideBoundaryThenComplete("ambiguous write"),
            counter: counter
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(1_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        try await approvePendingTool(handle: handle, harness: harness, offset: offset)
        try await waitForExecutorCondition {
            let counts = await counter.snapshot()
            return counts.boundaries == 1
        }
        let executing = try await handle.status()
        XCTAssertEqual(executing.state, .executingTools, file: file, line: line)

        let command = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(2_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: action,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await handle.send(command)
        XCTAssertEqual(receipt.disposition, .accepted, file: file, line: line)
        XCTAssertEqual(receipt.currentStatus.state, .pausing, file: file, line: line)
        let replayedReceipt = try await handle.send(command)
        XCTAssertEqual(replayedReceipt, receipt, file: file, line: line)

        let waiting = try await waitForStatus(.waitingForReconciliation, handle: handle)
        guard case .reconciliation(let invocationID) = waiting.blockingReason else {
            return XCTFail("expected reconciliation blocker", file: file, line: line)
        }
        XCTAssertEqual(invocationID, call.invocationID, file: file, line: line)
        XCTAssertFalse(waiting.state.isTerminal, file: file, line: line)
        let result = try await handle.result()
        XCTAssertNil(result, file: file, line: line)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )

        let snapshotValue = try await harness.repository.loadRunSnapshot(for: harness.request.runID)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertEqual(snapshot.events.filter { event in
            guard case .diagnostic(let failure) = event.payload.event else { return false }
            return failure.code == "execution.tool-attempt-interrupted-uncertain"
                && failure.details["invocationID"] == call.invocationID.description
        }.count, 1, file: file, line: line)
        XCTAssertFalse(snapshot.events.contains { $0.payload.event.isRunTerminal }, file: file, line: line)
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.executions, 1, file: file, line: line)
        XCTAssertEqual(counts.boundaries, 1, file: file, line: line)
        XCTAssertTrue(snapshot.facts.budgetLedger?.reservations.isEmpty == true, file: file, line: line)
    }

    private func approvePendingTool(
        handle: any AgentExecutionHandle,
        harness: ExecutorTestHarness,
        offset: Int
    ) async throws {
        let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = waiting.blockingReason else {
            throw ExecutorIntegrationTestError.streamEndedUnexpectedly
        }
        let approval = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(4_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await handle.send(approval)
        XCTAssertEqual(receipt.disposition, .accepted)
    }
}
