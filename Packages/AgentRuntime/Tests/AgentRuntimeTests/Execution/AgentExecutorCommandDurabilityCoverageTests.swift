// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class AgentExecutorCommandDurabilityCoverageTests: XCTestCase {
    func testHydrationOrdersACommittedTwoEventBatchBufferedDuringTheInitialRead() async throws {
        let offset = 10_100
        let model = try ExecutorTestModelDefinition(offset: offset)
        let modelGate = BlockingModelGate()
        let readGate = ExecutorReadEventsGate()
        let provider = try BlockingCompletionModelProvider(
            model: model,
            answer: "hydration preserved durable order",
            gate: modelGate
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, readEventsGate: readGate)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(40_100)
        )
        let handle = try await harness.executor.attach(to: handleID)
        try await waitForExecutorCondition { await modelGate.hasEntered() }

        let stream = harness.executor.controller.eventStream(for: handleID, after: nil)
        async let observedEvents = collectCommandDurabilityEvents(stream)
        try await readGate.waitUntilIntercepted()

        let firstFailure = try AgentFailure(
            code: "execution.hydration-buffer-first",
            classification: .transient,
            safeMessage: "The first buffered hydration diagnostic.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: AgentRunController.publicRedaction
        )
        let secondFailure = try AgentFailure(
            code: "execution.hydration-buffer-second",
            classification: .transient,
            safeMessage: "The second buffered hydration diagnostic.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: AgentRunController.publicRedaction
        )
        let firstEventID = ExecutionStableID.event(
            runID: harness.request.runID,
            key: "hydration-buffer-first"
        )
        let secondEventID = ExecutionStableID.event(
            runID: harness.request.runID,
            key: "hydration-buffer-second"
        )
        let committed = try await harness.executor.controller.commitEvents(
            runID: harness.request.runID,
            identity: .outcome(firstEventID)
        ) { builder in
            [
                try builder.append(
                    id: firstEventID,
                    event: .diagnostic(firstFailure),
                    redaction: AgentRunController.publicRedaction
                ),
                try builder.append(
                    id: secondEventID,
                    event: .diagnostic(secondFailure),
                    redaction: AgentRunController.publicRedaction
                ),
            ]
        }
        XCTAssertEqual(committed.events.count, 2)
        XCTAssertEqual(
            committed.events.map(\.payload.eventID),
            [firstEventID, secondEventID]
        )

        await readGate.release()
        await modelGate.release()
        let events = try await observedEvents

        XCTAssertEqual(events.map(\.payload.sequence), Array(1 ... UInt64(events.count)))
        XCTAssertEqual(events.filter { $0.payload.eventID == firstEventID }.count, 1)
        XCTAssertEqual(events.filter { $0.payload.eventID == secondEventID }.count, 1)
        let firstIndex = try XCTUnwrap(events.firstIndex { $0.payload.eventID == firstEventID })
        let secondIndex = try XCTUnwrap(events.firstIndex { $0.payload.eventID == secondEventID })
        XCTAssertLessThan(firstIndex, secondIndex)
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "hydration preserved durable order")
    }

    func testAbandoningAnUncertainExternalOperationTerminatesWithoutSynthesisOrReplay() async throws {
        let offset = 10_101
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "abandon-uncertain-write",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "must not synthesize after abandonment",
            script: script
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .throwAcrossBoundary,
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
            commandID: ExecutorTestID.command(40_101)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approval = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approval.blockingReason else {
            return XCTFail("expected approval before the non-idempotent write")
        }
        let approvalReceipt = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(40_102),
            runID: harness.request.runID,
            expectedRunStateVersion: approval.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(approvalReceipt.disposition, .accepted)

        let waiting = try await waitForStatus(.waitingForReconciliation, handle: handle)
        guard case .reconciliation(let invocationID) = waiting.blockingReason else {
            return XCTFail("expected the uncertain write to require reconciliation")
        }
        XCTAssertEqual(invocationID, call.invocationID)
        let reconcile = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(40_103),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .reconcile(invocationID: invocationID, decision: .abandoned),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await handle.send(reconcile)

        XCTAssertEqual(receipt.disposition, .accepted)
        XCTAssertEqual(receipt.currentStatus.state, .failed)
        XCTAssertEqual(receipt.currentStatus.terminalReason, .externalResultUncertain)
        XCTAssertEqual(receipt.currentStatus.failure?.code, "execution.reconciliation-abandoned")
        let replayed = try await handle.send(reconcile)
        XCTAssertEqual(replayed, receipt)

        let events = try await collectTerminalEvents(from: handle)
        let loadedResult = try await handle.result()
        let result = try XCTUnwrap(loadedResult)
        XCTAssertEqual(result.status, receipt.currentStatus)
        XCTAssertNil(result.answer)
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
        XCTAssertTrue(events.contains { event in
            guard case .toolOutcomeRecorded(let id, .uncertain) = event.payload.event else {
                return false
            }
            return id == invocationID
        })
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.executions, 1)
        XCTAssertEqual(counts.boundaries, 1)
        let requests = await script.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testResumeRejectsAtomicallyWhenAFrozenPendingToolIsUnavailableAfterReopen() async throws {
        let offset = 10_102
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(name: "missing-after-reopen")
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "must not complete without its frozen tool",
            script: script
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("must remain pending"),
            counter: counter
        )
        let crashGate = ExecutorPostCommitCrashGate(targetState: .executingTools)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, gate: crashGate)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(40_104)
        )
        let original = try await harness.executor.attach(to: handleID)
        try await crashGate.waitUntilIntercepted()
        let executing = try await original.status()
        let countsBeforePause = await counter.snapshot()
        XCTAssertEqual(executing.state, .executingTools)
        XCTAssertEqual(countsBeforePause.executions, 0)

        let pause = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(40_105),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let pauseReceipt = try await original.send(pause)
        XCTAssertEqual(pauseReceipt.disposition, .accepted)
        let paused = try await waitForStatus(.paused, handle: original)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let countsAfterPause = await counter.snapshot()
        XCTAssertEqual(countsAfterPause.executions, 0)
        await harness.repository.close()

        let reopenedRepository = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopenedRepository,
            provider: provider,
            tools: EmptyExecutableToolCatalog()
        )
        let reattached = try await restarted.attach(to: handleID)
        let eventsBefore = try await restarted.controller.allEvents(runID: harness.request.runID)
        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(40_106),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await reattached.send(resume)

        XCTAssertEqual(receipt.disposition, .rejected)
        XCTAssertEqual(receipt.failure?.code, "execution.resume-dependency-unavailable")
        XCTAssertEqual(receipt.currentStatus, paused)
        let statusAfter = try await reattached.status()
        let eventsAfter = try await restarted.controller.allEvents(runID: harness.request.runID)
        let activeWorker = await restarted.controller.workers[harness.request.runID]
        let finalCounts = await counter.snapshot()
        let toolInvocations = try await reopenedRepository.loadToolInvocations(
            for: harness.request.runID
        )
        XCTAssertEqual(statusAfter, paused)
        XCTAssertEqual(eventsAfter, eventsBefore)
        XCTAssertNil(activeWorker)
        XCTAssertEqual(finalCounts.executions, 0)
        XCTAssertTrue(toolInvocations.isEmpty)
    }

    func testWaitingApprovalRejectsUnrelatedCommandsWithoutMutatingTheRun() async throws {
        let offset = 10_103
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "negative-command-matrix",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "cancelled after negative command matrix"
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .completeCrossingBoundary("must not execute"),
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
            commandID: ExecutorTestID.command(40_107)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = waiting.blockingReason else {
            return XCTFail("expected approval blocker")
        }
        let baselineEvents = try await harness.executor.controller.allEvents(
            runID: harness.request.runID
        )
        let unknownApprovalID = ApprovalID(rawValue: ExecutorTestID.uuid(80_103))
        let unknownInteractionID = InteractionRequestID(rawValue: ExecutorTestID.uuid(81_103))
        let response = try UserInputResponse(
            requestID: unknownInteractionID,
            expectedRunStateVersion: waiting.stateVersion,
            value: .string("unrequested")
        )
        let cases: [(AgentCommandAction, String)] = [
            (.resume, "execution.resume-invalid"),
            (.pause(reason: .userRequested), "execution.pause-invalid"),
            (
                .decideApproval(
                    approvalID: unknownApprovalID,
                    decision: .approved,
                    approvedScope: .exactInvocation
                ),
                "execution.approval-missing"
            ),
            (.respond(response), "execution.response-invalid"),
            (
                .reconcile(invocationID: call.invocationID, decision: .failed),
                "execution.reconcile-invalid"
            ),
            (
                .decideApproval(
                    approvalID: approvalID,
                    decision: .approved,
                    approvedScope: .conversation
                ),
                "execution.approval-scope"
            ),
        ]

        for (index, entry) in cases.enumerated() {
            let receipt = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(41_000 + index),
                runID: harness.request.runID,
                expectedRunStateVersion: waiting.stateVersion,
                action: entry.0,
                issuedAt: AgentTimestamp(rawValue: 50_000)
            )))
            XCTAssertEqual(receipt.disposition, .rejected, "command index \(index)")
            XCTAssertEqual(receipt.failure?.code, entry.1, "command index \(index)")
            XCTAssertEqual(receipt.currentStatus, waiting, "command index \(index)")
        }
        let statusAfterRejectedCommands = try await handle.status()
        let eventsAfterRejectedCommands = try await harness.executor.controller.allEvents(
            runID: harness.request.runID
        )
        let countsAfterRejectedCommands = await counter.snapshot()
        XCTAssertEqual(statusAfterRejectedCommands, waiting)
        XCTAssertEqual(eventsAfterRejectedCommands, baselineEvents)
        XCTAssertEqual(countsAfterRejectedCommands.executions, 0)

        let cancellation = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(41_100),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .cancel,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(cancellation.disposition, .accepted)
        XCTAssertEqual(cancellation.currentStatus.state, .cancelled)
    }
}

private func collectCommandDurabilityEvents(
    _ stream: AsyncThrowingStream<AgentEventEnvelope, Error>
) async throws -> [AgentEventEnvelope] {
    var events: [AgentEventEnvelope] = []
    for try await event in stream { events.append(event) }
    return events
}
