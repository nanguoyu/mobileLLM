// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class AgentExecutorPublicRecoveryIntegrationTests: XCTestCase {
    func testPauseBeforeFirstToolIntentReopensAndResumesPendingBatchWithoutReproposal() async throws {
        let offset = 150
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(name: "pause-before-intent")
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Pending tool completed after reopen",
            script: script
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("first pending result"),
            counter: counter
        )
        let catalog = try SingleExecutorTestToolCatalog(tool: tool)
        let gate = ExecutorPostCommitCrashGate(targetState: .executingTools)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: catalog,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, gate: gate)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(20_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        try await gate.waitUntilIntercepted()
        let executing = try await handle.status()
        XCTAssertEqual(executing.state, .executingTools)
        let countsBeforePause = await counter.snapshot()
        XCTAssertEqual(countsBeforePause.executions, 0)
        let invocationsBeforePause = try await harness.repository.loadToolInvocations(
            for: harness.request.runID
        )
        XCTAssertTrue(invocationsBeforePause.isEmpty)

        let pause = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(21_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let pauseReceipt = try await handle.send(pause)
        XCTAssertEqual(pauseReceipt.disposition, .accepted)
        _ = try await waitForStatus(.paused, handle: handle)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let requestsBeforeReopen = await script.capturedRequests()
        XCTAssertEqual(requestsBeforeReopen.count, 1)
        await harness.repository.close()

        let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopened,
            provider: provider,
            tools: catalog
        )
        let reattached = try await restarted.attach(to: handleID)
        let paused = try await reattached.status()
        XCTAssertEqual(paused.state, .paused)
        try await Task.sleep(nanoseconds: 20_000_000)
        let countsAfterAttach = await counter.snapshot()
        let requestsAfterAttach = await script.capturedRequests()
        XCTAssertEqual(countsAfterAttach.executions, 0)
        XCTAssertEqual(requestsAfterAttach.count, 1)

        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(22_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let resumeReceipt = try await reattached.send(resume)
        XCTAssertEqual(resumeReceipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Pending tool completed after reopen")
        let finalCounts = await counter.snapshot()
        let finalRequests = await script.capturedRequests()
        XCTAssertEqual(finalCounts.executions, 1)
        XCTAssertEqual(finalCounts.boundaries, 0)
        XCTAssertEqual(finalRequests.count, 2, "the original tool proposal must not be regenerated")
        let invocations = try await reopened.loadToolInvocations(for: harness.request.runID)
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.invocationID, call.invocationID)
        XCTAssertEqual(invocations.first?.state, .completed)
    }

    func testPauseAfterFirstToolInBatchReopensAndExecutesOnlyRemainingTool() async throws {
        let offset = 151
        let model = try ExecutorTestModelDefinition(
            offset: offset,
            additionalCapabilities: [.multipleToolCalls]
        )
        let firstDefinition = try ExecutorTestToolDefinition(name: "batch-first")
        let secondDefinition = try ExecutorTestToolDefinition(name: "batch-second")
        let firstCall = try firstDefinition.call(offset: 15_101)
        let secondCall = try secondDefinition.call(offset: 15_102)
        let script = BatchToolSequenceModelScript()
        let provider = try BatchToolSequenceModelProvider(
            model: model,
            calls: [firstCall, secondCall],
            answer: "Both pending tools completed exactly once",
            script: script
        )
        let firstCounter = ExecutorTestToolCounter()
        let secondCounter = ExecutorTestToolCounter()
        let firstTool = ExecutorTestTool(
            definition: firstDefinition,
            behavior: .complete("first result"),
            counter: firstCounter
        )
        let secondTool = ExecutorTestTool(
            definition: secondDefinition,
            behavior: .complete("second result"),
            counter: secondCounter
        )
        let catalog = try ExecutorTestToolCatalog(tools: [firstTool, secondTool])
        let firstOutcomeEventID = ExecutionStableID.event(
            runID: ExecutorTestID.run(offset),
            key: "tool-outcome-\(firstCall.invocationID.description)"
        )
        let gate = ExecutorPostCommitCrashGate(targetEventID: firstOutcomeEventID)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [firstDefinition.descriptor, secondDefinition.descriptor],
            tools: catalog,
            explicitlyRequestedToolIDs: [
                firstDefinition.descriptor.id.logicalID,
                secondDefinition.descriptor.id.logicalID,
            ],
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, gate: gate)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(20_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        do {
            try await gate.waitUntilIntercepted()
        } catch {
            let status = try await handle.status()
            let firstCounts = await firstCounter.snapshot()
            let secondCounts = await secondCounter.snapshot()
            let requests = await script.capturedRequests()
            let events = try await harness.executor.controller.allEvents(runID: harness.request.runID)
            return XCTFail(
                "first tool outcome was not committed: status=\(status), "
                    + "first=\(firstCounts), second=\(secondCounts), requests=\(requests.count), "
                    + "events=\(events.map { String(describing: $0.payload.event) })"
            )
        }
        let executing = try await handle.status()
        XCTAssertEqual(executing.state, .executingTools)
        let firstAtPause = await firstCounter.snapshot()
        let secondAtPause = await secondCounter.snapshot()
        XCTAssertEqual(firstAtPause.executions, 1)
        XCTAssertEqual(secondAtPause.executions, 0)
        let durableAtPause = try await harness.repository.loadToolInvocations(
            for: harness.request.runID
        )
        XCTAssertEqual(durableAtPause.count, 1)
        XCTAssertEqual(durableAtPause.first?.invocationID, firstCall.invocationID)
        XCTAssertEqual(durableAtPause.first?.state, .completed)

        let pause = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(21_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let pauseReceipt = try await handle.send(pause)
        XCTAssertEqual(pauseReceipt.disposition, .accepted)
        _ = try await waitForStatus(.paused, handle: handle)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        await harness.repository.close()

        let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopened,
            provider: provider,
            tools: catalog
        )
        let reattached = try await restarted.attach(to: handleID)
        let paused = try await reattached.status()
        XCTAssertEqual(paused.state, .paused)
        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(22_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let resumeReceipt = try await reattached.send(resume)
        XCTAssertEqual(resumeReceipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Both pending tools completed exactly once")
        let finalFirst = await firstCounter.snapshot()
        let finalSecond = await secondCounter.snapshot()
        let finalRequests = await script.capturedRequests()
        XCTAssertEqual(finalFirst.executions, 1, "completed batch members must never replay")
        XCTAssertEqual(finalSecond.executions, 1, "the pending batch member must execute")
        XCTAssertEqual(finalRequests.count, 2, "resume must consume the durable batch, not re-propose it")
        let finalInvocations = try await reopened.loadToolInvocations(for: harness.request.runID)
        XCTAssertEqual(Set(finalInvocations.compactMap(\.invocationID)), [
            firstCall.invocationID,
            secondCall.invocationID,
        ])
        XCTAssertTrue(finalInvocations.allSatisfy { $0.state == .completed })
    }

    func testNonReplayableToolFailedDuringPauseReopensAndResumesDirectlyToSynthesis() async throws {
        let offset = 152
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "pause-nonreplayable",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Failed write was synthesized after reopen",
            script: script
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .blockFirstAttemptBeforeBoundaryThenComplete("must not replay"),
            counter: counter
        )
        let catalog = try SingleExecutorTestToolCatalog(tool: tool)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: catalog,
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(20_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        try await approvePendingTool(
            handle: handle,
            runID: harness.request.runID,
            commandOffset: 21_000 + offset
        )
        try await waitForExecutorCondition {
            await counter.snapshot().executions == 1
        }
        let executing = try await handle.status()
        XCTAssertEqual(executing.state, .executingTools)
        let pause = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(22_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let pauseReceipt = try await handle.send(pause)
        XCTAssertEqual(pauseReceipt.disposition, .accepted)
        _ = try await waitForStatus(.paused, handle: handle)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let interrupted = try await harness.repository.loadToolInvocations(
            for: harness.request.runID
        )
        XCTAssertEqual(interrupted.count, 1)
        guard case .failed(let interruption)? = interrupted.first?.outcome else {
            return XCTFail("non-replayable cancellation must commit a failed tool outcome")
        }
        XCTAssertEqual(interruption.code, "execution.tool-attempt-interrupted")
        XCTAssertEqual(interruption.externalEffect, .confirmedNone)
        let countsBeforeReopen = await counter.snapshot()
        XCTAssertEqual(countsBeforeReopen.executions, 1)
        XCTAssertEqual(countsBeforeReopen.boundaries, 0)
        await harness.repository.close()

        let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopened,
            provider: provider,
            tools: catalog
        )
        let reattached = try await restarted.attach(to: handleID)
        let paused = try await reattached.status()
        XCTAssertEqual(paused.state, .paused)
        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(23_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await reattached.send(resume)
        XCTAssertEqual(receipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Failed write was synthesized after reopen")
        let finalCounts = await counter.snapshot()
        let finalRequests = await script.capturedRequests()
        XCTAssertEqual(finalCounts.executions, 1, "failed non-replayable work must not execute again")
        XCTAssertEqual(finalRequests.count, 2)
        XCTAssertTrue(finalRequests[1].advertisedTools.isEmpty, "resume must be tool-free synthesis")
        let synthesis = finalRequests[1].messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(synthesis.contains("execution.tool-attempt-interrupted"))
    }

    func testNewProcessCancelOfClaimedRiskyToolReconcilesSucceededThenSynthesizes() async throws {
        try await assertNewProcessRiskyCancellationAndReconciliation(
            decision: .succeeded,
            expectedDiagnostic: "execution.reconciled-succeeded",
            offset: 160
        )
    }

    func testNewProcessCancelOfClaimedRiskyToolReconcilesFailedThenSynthesizes() async throws {
        try await assertNewProcessRiskyCancellationAndReconciliation(
            decision: .failed,
            expectedDiagnostic: "execution.reconciled-failed",
            offset: 161
        )
    }

    func testNewProcessCancelWithExactNoBoundaryClaimNeverRequiresReconciliation() async throws {
        let offset = 162
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "cancel-before-boundary-claim",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "must never answer after cancellation",
            script: script
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .completeCrossingBoundary("must not execute"),
            counter: counter
        )
        let catalog = try SingleExecutorTestToolCatalog(tool: tool)
        // executingTools commits: batch admission, approval acceptance, then the tool intent.
        let gate = ExecutorPostCommitCrashGate(
            targetState: .executingTools,
            targetOccurrence: 3
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: catalog,
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, gate: gate)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(20_000 + offset)
        )
        let original = try await harness.executor.attach(to: handleID)
        try await approvePendingTool(
            handle: original,
            runID: harness.request.runID,
            commandOffset: 21_000 + offset
        )
        try await gate.waitUntilIntercepted()
        let worker = await harness.executor.controller.workers[harness.request.runID]
        worker?.cancel()
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let durable = try await harness.repository.loadToolInvocations(for: harness.request.runID)
        let invocation = try XCTUnwrap(durable.first)
        XCTAssertNil(invocation.outcome)
        let approvals = try await harness.repository.loadApprovals(for: harness.request.runID)
        let approval = try XCTUnwrap(approvals.first)
        let attempt = try ExternalOperationAttempt(prepared: invocation.request, attemptNumber: 1)
        let evidence = try await harness.repository.boundaryClaimEvidence(
            approvalID: approval.request.id,
            prepared: invocation.request,
            attempt: attempt
        )
        XCTAssertEqual(evidence, .none)
        let beforeCrashCounts = await counter.snapshot()
        XCTAssertEqual(beforeCrashCounts.executions, 0)
        XCTAssertEqual(beforeCrashCounts.boundaries, 0)
        await harness.repository.close()

        let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopened,
            provider: provider,
            tools: catalog
        )
        let reattached = try await restarted.attach(to: handleID)
        let executing = try await reattached.status()
        XCTAssertEqual(executing.state, .executingTools)
        let cancel = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(22_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: .cancel,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await reattached.send(cancel)
        XCTAssertEqual(receipt.disposition, .accepted)
        XCTAssertNotEqual(receipt.currentStatus.state, .waitingForReconciliation)
        let events = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .cancelled)
        XCTAssertEqual(result?.status.terminalReason, .cancelledByUser)
        XCTAssertFalse(events.contains { event in
            if case .statusChanged(let status) = event.payload.event {
                return status.state == .waitingForReconciliation
            }
            if case .diagnostic(let failure) = event.payload.event {
                return failure.externalEffect == .uncertain
            }
            return false
        })
        let finalCounts = await counter.snapshot()
        let finalRequests = await script.capturedRequests()
        XCTAssertEqual(finalCounts.executions, 0)
        XCTAssertEqual(finalCounts.boundaries, 0)
        XCTAssertEqual(finalRequests.count, 1)
        let finalFactsValue = try await reopened.loadRunFacts(for: harness.request.runID)
        let finalFacts = try XCTUnwrap(finalFactsValue)
        XCTAssertTrue(finalFacts.budgetLedger?.reservations.isEmpty == true)
    }

    func testResumeReceiptReplaysItsOriginalCheckpointAfterCompletionFaultAndLaterTerminal() async throws {
        let offset = 163
        let model = try ExecutorTestModelDefinition(offset: offset)
        let invocationCounter = ScriptedInvocationCounter()
        let provider = try FixedCompletionModelProvider(
            model: model,
            answer: "Completed after command receipt fault",
            invocationCounter: invocationCounter
        )
        let crashGate = ExecutorPostCommitCrashGate(targetState: .preparing)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, gate: crashGate)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(20_000 + offset)
        )
        let original = try await harness.executor.attach(to: handleID)
        try await crashGate.waitUntilIntercepted()
        let oldWorker = await harness.executor.controller.workers[harness.request.runID]
        oldWorker?.cancel()
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let checkpoint = try await original.status()
        XCTAssertEqual(checkpoint.state, .preparing)
        let attemptsBeforeResume = await invocationCounter.count()
        XCTAssertEqual(attemptsBeforeResume, 0)
        await harness.repository.close()

        let resumeCommandID = ExecutorTestID.command(21_000 + offset)
        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: resumeCommandID,
            runID: harness.request.runID,
            expectedRunStateVersion: checkpoint.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let firstBacking = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let completionFault = ExecutorCommandCompletionFault(commandID: resumeCommandID)
        let firstRepository = ExecutorPostCommitGatedRepository(
            underlying: firstBacking,
            commandCompletionFault: completionFault
        )
        let firstRestart = try makeReopenedExecutor(
            harness: harness,
            repository: firstRepository,
            provider: provider
        )
        let firstHandle = try await firstRestart.attach(to: handleID)
        do {
            _ = try await firstHandle.send(resume)
            XCTFail("the injected command-completion fault must escape the first sender")
        } catch ExecutorSimulatedProcessLoss.beforeCommandCompletion {
            // The recovery checkpoint is durable and its worker is already independently running.
        }
        _ = try await collectTerminalEvents(from: firstHandle)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: firstRestart.controller
        )
        let firstResult = try await firstHandle.result()
        XCTAssertEqual(firstResult?.status.state, .completed)
        XCTAssertEqual(firstResult?.answer?.text, "Completed after command receipt fault")
        let attemptsAfterTerminal = await invocationCounter.count()
        XCTAssertEqual(attemptsAfterTerminal, 1)
        await firstBacking.close()

        let secondBacking = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let secondRestart = try makeReopenedExecutor(
            harness: harness,
            repository: secondBacking,
            provider: provider,
            clock: FixedExecutorClock(100_000)
        )
        let secondHandle = try await secondRestart.attach(to: handleID)
        let terminalBeforeReplay = try await secondHandle.status()
        XCTAssertEqual(terminalBeforeReplay.state, .completed)
        let replayed = try await secondHandle.send(resume)
        XCTAssertEqual(replayed.disposition, .accepted)
        XCTAssertEqual(
            replayed.currentStatus,
            checkpoint,
            "idempotent replay must return the status captured by the original checkpoint"
        )
        XCTAssertNotEqual(replayed.currentStatus.state, terminalBeforeReplay.state)
        let secondResult = try await secondHandle.result()
        XCTAssertEqual(secondResult, firstResult)
        let finalAttempts = await invocationCounter.count()
        XCTAssertEqual(finalAttempts, 1, "replaying a receipt must never schedule the model again")
        let durableCommand = try await secondBacking.loadCommand(resumeCommandID)
        XCTAssertEqual(durableCommand?.state, .completed)
        XCTAssertEqual(durableCommand?.receipt?.payload, replayed)
    }

    func testMutationReplayReturnsOriginalEventsAndNeverBroadcastsSpeculativeState() async throws {
        let offset = 164
        let model = try ExecutorTestModelDefinition(offset: offset)
        let provider = try FixedCompletionModelProvider(
            model: model,
            answer: "must not run"
        )
        let mutationEventID = ExecutionStableID.event(
            runID: ExecutorTestID.run(offset),
            key: "forced-mutation-replay"
        )
        let mutationIdentity = RunJournalMutationIdentity.outcome(mutationEventID)
        let replayInjector = ExecutorMutationReplayInjector(target: mutationIdentity)
        let crashGate = ExecutorPostCommitCrashGate(targetState: .created)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(
                    underlying: $0,
                    gate: crashGate,
                    mutationReplayInjector: replayInjector
                )
            }
        )
        let submission = Task {
            try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(20_000 + offset)
            )
        }
        try await crashGate.waitUntilIntercepted()
        let createdFactsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let createdFacts = try XCTUnwrap(createdFactsValue)
        let handleID = try XCTUnwrap(createdFacts.submission?.executionHandleID)
        submission.cancel()
        _ = await submission.result
        let handle = try await harness.executor.attach(to: handleID)

        let first = try await harness.executor.controller.commitEvents(
            runID: harness.request.runID,
            identity: mutationIdentity
        ) { builder in
            let preparing = try AgentRunStatus(
                state: .preparing,
                stateVersion: builder.stateVersion + 1
            )
            return [try builder.append(
                id: mutationEventID,
                event: .statusChanged(preparing),
                transitionTo: .preparing,
                redaction: AgentRunController.publicRedaction
            )]
        }
        XCTAssertEqual(first.receipt.appendReceipt.disposition, .appended)
        XCTAssertEqual(first.receipt.appendReceipt.eventIDs, first.events.map { $0.payload.eventID })

        let advanceEventID = ExecutionStableID.event(
            runID: harness.request.runID,
            key: "advance-before-replay"
        )
        let advanced = try await harness.executor.controller.commitEvents(
            runID: harness.request.runID,
            identity: .outcome(advanceEventID)
        ) { builder in
            let waiting = try AgentRunStatus(
                state: .waitingForModel,
                stateVersion: builder.stateVersion + 1,
                blockingReason: .modelResource
            )
            return [try builder.append(
                id: advanceEventID,
                event: .statusChanged(waiting),
                transitionTo: .waitingForModel,
                redaction: AgentRunController.publicRedaction
            )]
        }
        let anchor = try XCTUnwrap(advanced.events.last)
        let observer = Task<AgentEventEnvelope?, Error> {
            var iterator = handle.events(after: anchor.payload.cursor).makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let replayed = try await harness.executor.controller.commitEvents(
            runID: harness.request.runID,
            identity: mutationIdentity
        ) { builder in
            let speculative = try AgentRunStatus(
                state: .generating,
                stateVersion: builder.stateVersion + 1
            )
            return [try builder.append(
                id: mutationEventID,
                event: .statusChanged(speculative),
                transitionTo: .generating,
                redaction: AgentRunController.publicRedaction
            )]
        }
        XCTAssertEqual(replayed.receipt.appendReceipt.disposition, .replayed)
        XCTAssertEqual(replayed.receipt.appendReceipt.eventIDs, first.receipt.appendReceipt.eventIDs)
        XCTAssertEqual(replayed.events, first.events)
        XCTAssertEqual(replayed.events.first?.payload.runState, .preparing)

        let liveEventID = ExecutionStableID.event(
            runID: harness.request.runID,
            key: "real-live-event-after-replay"
        )
        let live = try await harness.executor.controller.commitEvents(
            runID: harness.request.runID,
            identity: .outcome(liveEventID)
        ) { builder in
            let generating = try AgentRunStatus(
                state: .generating,
                stateVersion: builder.stateVersion + 1
            )
            return [try builder.append(
                id: liveEventID,
                event: .statusChanged(generating),
                transitionTo: .generating,
                redaction: AgentRunController.publicRedaction
            )]
        }
        let observed = try await observer.value
        XCTAssertEqual(observed, live.events.first)
        XCTAssertEqual(observed?.payload.runState, .generating)
        let durableEvents = try await harness.executor.controller.allEvents(
            runID: harness.request.runID
        )
        XCTAssertEqual(durableEvents.filter { $0.payload.eventID == mutationEventID }.count, 1)
    }

    private func assertNewProcessRiskyCancellationAndReconciliation(
        decision: AgentReconciliationDecision,
        expectedDiagnostic: String,
        offset: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "crashed-risky-\(decision.rawValue)",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Reconciliation \(decision.rawValue) synthesized",
            script: script
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .completeCrossingBoundary("old process must not complete"),
            counter: counter
        )
        let catalog = try SingleExecutorTestToolCatalog(tool: tool)
        let claimGate = ExecutorBoundaryClaimCrashGate()
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: catalog,
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(
                    underlying: $0,
                    boundaryClaimCrashGate: claimGate
                )
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(20_000 + offset)
        )
        let original = try await harness.executor.attach(to: handleID)
        try await approvePendingTool(
            handle: original,
            runID: harness.request.runID,
            commandOffset: 21_000 + offset
        )
        try await claimGate.waitUntilIntercepted()
        let countsAtCrash = await counter.snapshot()
        XCTAssertEqual(countsAtCrash.executions, 1, file: file, line: line)
        XCTAssertEqual(countsAtCrash.boundaries, 0, file: file, line: line)
        let durable = try await harness.repository.loadToolInvocations(for: harness.request.runID)
        let invocation = try XCTUnwrap(durable.first, file: file, line: line)
        XCTAssertNil(invocation.outcome, file: file, line: line)
        let approvals = try await harness.repository.loadApprovals(for: harness.request.runID)
        let approval = try XCTUnwrap(approvals.first, file: file, line: line)
        let attempt = try ExternalOperationAttempt(prepared: invocation.request, attemptNumber: 1)
        let evidence = try await harness.repository.boundaryClaimEvidence(
            approvalID: approval.request.id,
            prepared: invocation.request,
            attempt: attempt
        )
        XCTAssertEqual(evidence, .exact, file: file, line: line)

        // Close the old process store while its stack is stopped after the durable claim. The
        // continuation deliberately remains suspended until the replacement process has reached
        // a terminal result, so no old-process cleanup can manufacture a competing outcome.
        await harness.repository.close()

        let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopened,
            provider: provider,
            tools: catalog
        )
        let reattached = try await restarted.attach(to: handleID)
        let recovered = try await reattached.status()
        XCTAssertEqual(recovered.state, .executingTools, file: file, line: line)
        try await Task.sleep(nanoseconds: 20_000_000)
        let countsAfterAttach = await counter.snapshot()
        XCTAssertEqual(countsAfterAttach.executions, 1, file: file, line: line)
        XCTAssertEqual(countsAfterAttach.boundaries, 0, file: file, line: line)

        let cancel = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(22_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: recovered.stateVersion,
            action: .cancel,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let cancelReceipt = try await reattached.send(cancel)
        XCTAssertEqual(cancelReceipt.disposition, .accepted, file: file, line: line)
        XCTAssertEqual(
            cancelReceipt.currentStatus.state,
            .waitingForReconciliation,
            file: file,
            line: line
        )
        guard case .reconciliation(let invocationID) = cancelReceipt.currentStatus.blockingReason else {
            return XCTFail("expected exact reconciliation blocker", file: file, line: line)
        }
        XCTAssertEqual(invocationID, call.invocationID, file: file, line: line)

        let reconcile = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(23_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: cancelReceipt.currentStatus.stateVersion,
            action: .reconcile(invocationID: invocationID, decision: decision),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let reconcileReceipt = try await reattached.send(reconcile)
        XCTAssertEqual(reconcileReceipt.disposition, .accepted, file: file, line: line)
        XCTAssertEqual(reconcileReceipt.currentStatus.state, .synthesizing, file: file, line: line)
        let events = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .completed, file: file, line: line)
        XCTAssertEqual(
            result?.answer?.text,
            "Reconciliation \(decision.rawValue) synthesized",
            file: file,
            line: line
        )
        let finalCounts = await counter.snapshot()
        let finalRequests = await script.capturedRequests()
        XCTAssertEqual(finalCounts.executions, 1, file: file, line: line)
        XCTAssertEqual(finalCounts.boundaries, 0, file: file, line: line)
        guard finalRequests.count == 2 else {
            return XCTFail("expected proposal plus synthesis, got \(finalRequests.count)", file: file, line: line)
        }
        XCTAssertTrue(finalRequests[1].advertisedTools.isEmpty, file: file, line: line)
        let synthesis = finalRequests[1].messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(synthesis.contains(expectedDiagnostic), file: file, line: line)
        XCTAssertFalse(events.contains { event in
            guard case .diagnostic(let failure) = event.payload.event else { return false }
            return failure.code == "execution.invalid-recovery-boundary"
        }, file: file, line: line)
        let finalFactsValue = try await reopened.loadRunFacts(for: harness.request.runID)
        let finalFacts = try XCTUnwrap(finalFactsValue, file: file, line: line)
        XCTAssertTrue(finalFacts.budgetLedger?.reservations.isEmpty == true, file: file, line: line)

        // Drain the artificial old-process stack only after replacement-process finalization.
        // The claim gate throws before the provider boundary closure, so this cannot perform the
        // external effect; terminal journal validation must also reject any late mutation.
        await claimGate.abortAsProcessLoss()
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let afterDrain = try await reopened.readEvents(RunJournalReadRequest(
            runID: harness.request.runID,
            after: nil,
            limit: 1_024
        ))
        XCTAssertEqual(
            afterDrain.events.filter { $0.payload.event.isRunTerminal }.count,
            1,
            file: file,
            line: line
        )
    }

    private func approvePendingTool(
        handle: any AgentExecutionHandle,
        runID: AgentRunID,
        commandOffset: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = waiting.blockingReason else {
            return XCTFail("expected approval blocker", file: file, line: line)
        }
        let approval = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(commandOffset),
            runID: runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await handle.send(approval)
        XCTAssertEqual(receipt.disposition, .accepted, file: file, line: line)
    }
}
