// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

/// End-to-end coverage for recovery branches whose correctness depends on durable state rather
/// than on an isolated helper. These tests deliberately exercise the public command/handle API
/// except where a restarted worker is the behavior under test.
// TEST-ID: AHT-LOOP-002
// TEST-ID: AHT-RETRY-001
// TEST-ID: AHT-OBS-001
// TEST-ID: AHT-SECURITY-003
final class AgentExecutorCoverageClosureIntegrationTests: XCTestCase {
    func testWorkerLogRedactsEveryExecutionErrorCaseWithoutDroppingInvariantDetail() async throws {
        let tool = try ExecutorTestToolDefinition(name: "worker-log-tool")
        let errors: [(AgentExecutionError, String)] = [
            (.requestRunAlreadyExists(ExecutorTestID.run(1)), "request-run-already-exists"),
            (.submissionCommandConflict(ExecutorTestID.command(1)), "submission-command-conflict"),
            (.executionNotFound(AgentExecutionHandleID()), "execution-not-found"),
            (.corruptExecutionBinding, "corrupt-execution-binding"),
            (.cursorBelongsToAnotherExecution, "cursor-belongs-to-another-execution"),
            (.cursorNotFound, "cursor-not-found"),
            (.cursorIntegrityMismatch, "cursor-integrity-mismatch"),
            (.commandTargetsAnotherRun, "command-targets-another-run"),
            (.commandLeaseUnavailable, "command-lease-unavailable"),
            (.dependencyUnavailable("fixture"), "dependency-unavailable"),
            (.malformedModelAction, "malformed-model-action"),
            (.structuredRepairExhausted, "structured-repair-exhausted"),
            (.toolBatchInvalid, "tool-batch-invalid"),
            (.toolUnavailable(tool.descriptor.id), "tool-unavailable"),
            (.approvalUnavailable, "approval-unavailable"),
            (.interactionUnavailable, "interaction-unavailable"),
            (.reconciliationUnavailable, "reconciliation-unavailable"),
            (.budgetUnavailable, "budget-unavailable"),
            (.invalidRecoveryBoundary, "invalid-recovery-boundary"),
            (.ephemeralObserverLagged, "ephemeral-observer-lagged"),
            (.internalInvariant("bounded invariant detail"), "internal-invariant"),
        ]

        for (index, scenario) in errors.enumerated() {
            let offset = 930 + index
            let model = try ExecutorTestModelDefinition(offset: offset)
            let provider = try FixedCompletionModelProvider(
                model: model,
                answer: "must not execute"
            )
            let harness = try ExecutorTestHarness(
                offset: offset,
                provider: provider,
                model: model,
                repositoryFactory: {
                    ExecutorPostCommitGatedRepository(
                        underlying: $0,
                        loadRunFactsFailure: scenario.0
                    )
                }
            )
            _ = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + offset)
            )
            try await waitForExecutorCondition {
                !(await harness.logger.snapshot()).isEmpty
            }
            let entries = await harness.logger.snapshot()
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry.code, "execution.worker-failed")
            XCTAssertEqual(entry.metadata["errorCode"], scenario.1)
            XCTAssertEqual(entry.metadata["run"], harness.request.runID.description)
            if case .internalInvariant(let detail) = scenario.0 {
                XCTAssertEqual(entry.metadata["detail"], detail)
            } else {
                XCTAssertNil(entry.metadata["detail"])
            }
        }
    }

    func testInvalidToolBatchAndMissingLiveCatalogFailClosedThroughTheWorker() async throws {
        do {
            let offset = 960
            let model = try ExecutorTestModelDefinition(
                offset: offset,
                additionalCapabilities: [.multipleToolCalls]
            )
            let definition = try ExecutorTestToolDefinition(name: "duplicate-batch")
            let firstCall = try definition.call(offset: offset)
            let secondCall = try definition.call(offset: offset + 1)
            let provider = try BatchToolSequenceModelProvider(
                model: model,
                calls: [firstCall, secondCall],
                answer: "must not continue"
            )
            let tool = ExecutorTestTool(definition: definition, behavior: .complete("unused"))
            let harness = try ExecutorTestHarness(
                offset: offset,
                provider: provider,
                model: model,
                toolDescriptors: [definition.descriptor],
                tools: SingleExecutorTestToolCatalog(tool: tool),
                explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            _ = try await collectTerminalEvents(from: handle)
            let loadedResult = try await handle.result()
            let result = try XCTUnwrap(loadedResult)
            XCTAssertEqual(result.status.state, .failed)
            XCTAssertEqual(result.status.failure?.code, "execution.invalid-tool-batch")
        }

        do {
            let offset = 961
            let model = try ExecutorTestModelDefinition(offset: offset)
            let definition = try ExecutorTestToolDefinition(name: "missing-live-tool")
            let call = try definition.call(offset: offset)
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "must not continue"
            )
            let harness = try ExecutorTestHarness(
                offset: offset,
                provider: provider,
                model: model,
                toolDescriptors: [definition.descriptor],
                tools: EmptyExecutableToolCatalog(),
                explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            _ = try await collectTerminalEvents(from: handle)
            let loadedResult = try await handle.result()
            let result = try XCTUnwrap(loadedResult)
            XCTAssertEqual(result.status.state, .failed)
            XCTAssertEqual(result.status.terminalReason, .toolUnavailable)
            XCTAssertEqual(result.status.failure?.code, "execution.tool-unavailable")
        }
    }

    func testToolRetryJitterAndTypedContractFailuresUseDurableSafeOutcomes() async throws {
        do {
            let offset = 962
            let model = try ExecutorTestModelDefinition(offset: offset)
            let retry = try ExternalRetryPolicy(
                kind: .boundedExponential,
                maximumAttempts: 3,
                baseDelayMilliseconds: 8,
                maximumDelayMilliseconds: 12,
                allowsJitter: true
            )
            let definition = try ExecutorTestToolDefinition(
                name: "jittered-retry",
                retryPolicy: retry
            )
            let call = try definition.call(offset: offset)
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "retried with bounded jitter"
            )
            let counter = ExecutorTestToolCounter()
            let tool = ExecutorTestTool(
                definition: definition,
                behavior: .throwAttemptsThenComplete(2, "eventual result"),
                counter: counter
            )
            let clock = RecordingExecutorClock()
            let harness = try ExecutorTestHarness(
                offset: offset,
                provider: provider,
                model: model,
                toolDescriptors: [definition.descriptor],
                tools: SingleExecutorTestToolCatalog(tool: tool),
                explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
                clock: clock
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            _ = try await collectTerminalEvents(from: handle)
            let loadedResult = try await handle.result()
            let result = try XCTUnwrap(loadedResult)
            XCTAssertEqual(result.status.state, .completed)
            XCTAssertEqual(result.answer?.text, "retried with bounded jitter")
            let delays = await clock.recordedDelays()
            XCTAssertEqual(delays.count, 2)
            XCTAssertTrue((6 ... 8).contains(delays[0]))
            XCTAssertTrue((9 ... 12).contains(delays[1]))
            let counts = await counter.snapshot()
            XCTAssertEqual(counts.executions, 3)
        }

        let contractCases: [(offset: Int, error: AgentContractError, code: String)] = [
            (
                963,
                .budgetExceeded(dimension: .networkRequestBytes, limit: 1, requested: 2),
                "execution.tool-budget-exceeded"
            ),
            (964, .authorizationExpired, "execution.tool-authorization-failed"),
        ]
        for testCase in contractCases {
            let model = try ExecutorTestModelDefinition(offset: testCase.offset)
            let definition = try ExecutorTestToolDefinition(name: "typed-\(testCase.offset)")
            let call = try definition.call(offset: testCase.offset)
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "synthesized typed failure"
            )
            let tool = ExecutorTestTool(
                definition: definition,
                behavior: .throwContractBeforeBoundary(testCase.error)
            )
            let harness = try ExecutorTestHarness(
                offset: testCase.offset,
                provider: provider,
                model: model,
                toolDescriptors: [definition.descriptor],
                tools: SingleExecutorTestToolCatalog(tool: tool),
                explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + testCase.offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            let events = try await collectTerminalEvents(from: handle)
            let recorded = try XCTUnwrap(events.compactMap { event -> AgentFailure? in
                guard case .toolOutcomeRecorded(_, .failed(let failure)) = event.payload.event else {
                    return nil
                }
                return failure
            }.last)
            XCTAssertEqual(recorded.code, testCase.code)
            XCTAssertEqual(recorded.externalEffect, .confirmedNone)
            let loadedResult = try await handle.result()
            let result = try XCTUnwrap(loadedResult)
            XCTAssertEqual(result.status.state, .completed)
            XCTAssertEqual(result.answer?.text, "synthesized typed failure")
        }
    }

    func testRetryDelayClampAndUnlistedContractErrorClassification() async throws {
        do {
            // Base delay equal to the maximum exercises the exponential clamp break.
            let offset = 966
            let model = try ExecutorTestModelDefinition(offset: offset)
            let retry = try ExternalRetryPolicy(
                kind: .boundedExponential,
                maximumAttempts: 3,
                baseDelayMilliseconds: 12,
                maximumDelayMilliseconds: 12,
                allowsJitter: false
            )
            let definition = try ExecutorTestToolDefinition(
                name: "clamped-retry",
                retryPolicy: retry
            )
            let call = try definition.call(offset: offset)
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "clamped retry completed"
            )
            let tool = ExecutorTestTool(
                definition: definition,
                behavior: .throwAttemptsThenComplete(2, "eventual")
            )
            let clock = RecordingExecutorClock()
            let harness = try ExecutorTestHarness(
                offset: offset,
                provider: provider,
                model: model,
                toolDescriptors: [definition.descriptor],
                tools: SingleExecutorTestToolCatalog(tool: tool),
                explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
                clock: clock
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            _ = try await collectTerminalEvents(from: handle)
            let loaded = try await handle.result()
            let result = try XCTUnwrap(loaded)
            XCTAssertEqual(result.status.state, .completed)
            let delays = await clock.recordedDelays()
            XCTAssertEqual(delays, [12, 12])
        }

        do {
            // A contract error outside the typed budget/authorization families stays permanent.
            let offset = 967
            let model = try ExecutorTestModelDefinition(offset: offset)
            let definition = try ExecutorTestToolDefinition(name: "unlisted-contract")
            let call = try definition.call(offset: offset)
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "unlisted contract synthesized"
            )
            let tool = ExecutorTestTool(
                definition: definition,
                behavior: .throwContractBeforeBoundary(
                    AgentContractError.wireLimitExceeded("unlisted contract failure")
                )
            )
            let harness = try ExecutorTestHarness(
                offset: offset,
                provider: provider,
                model: model,
                toolDescriptors: [definition.descriptor],
                tools: SingleExecutorTestToolCatalog(tool: tool),
                explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            let events = try await collectTerminalEvents(from: handle)
            let recorded = try XCTUnwrap(events.compactMap { event -> AgentFailure? in
                guard case .toolOutcomeRecorded(_, .failed(let failure)) = event.payload.event else {
                    return nil
                }
                return failure
            }.last)
            XCTAssertEqual(recorded.classification, .permanent)
            XCTAssertEqual(recorded.externalEffect, .confirmedNone)
        }
    }

    func testToolElapsedTimeFallsBackToTimeoutWhenClockRegresses() async throws {
        let offset = 969
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(name: "regressing-clock")
        let call = try definition.call(offset: offset)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "clock regression tolerated"
        )
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("local result")
        )
        let clock = RegressingExecutorClock(first: 2_000, later: 1_000)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            clock: clock
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        _ = try await collectTerminalEvents(from: handle)
        let loaded = try await handle.result()
        let result = try XCTUnwrap(loaded)
        XCTAssertEqual(result.status.state, .completed)
        XCTAssertEqual(result.answer?.text, "clock regression tolerated")
    }

    func testToolInternalCancellationDoesNotStrandTheRunAsRuntimeCancellation() async throws {
        let offset = 979
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(name: "internal-cancellation")
        let call = try definition.call(offset: offset)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "internal cancellation synthesized"
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .throwCancellationBeforeBoundary,
            counter: counter
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )

        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)
        let loadedResult = try await handle.result()
        let result = try XCTUnwrap(loadedResult)

        XCTAssertEqual(result.status.state, .completed)
        XCTAssertEqual(result.answer?.text, "internal cancellation synthesized")
        let outcome = try XCTUnwrap(events.compactMap { event -> AgentToolInvocationOutcome? in
            guard case .toolOutcomeRecorded(let invocationID, let outcome) = event.payload.event,
                  invocationID == call.invocationID
            else { return nil }
            return outcome
        }.last)
        guard case .failed(let failure) = outcome else {
            return XCTFail("expected a durable known-no-effect failure")
        }
        XCTAssertEqual(failure.code, "execution.tool-transient")
        XCTAssertEqual(failure.externalEffect, .confirmedNone)
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.executions, 1)
        XCTAssertEqual(counts.boundaries, 0)
        let finalFacts = try await harness.repository.loadRunFacts(for: harness.request.runID)
        XCTAssertTrue(finalFacts?.budgetLedger?.reservations.isEmpty == true)
    }

    func testPolicyRevocationDeniesThePreparedToolBeforeIntentOrExecution() async throws {
        let offset = 980
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(name: "policy-revoked")
        let call = try definition.call(offset: offset)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "must not synthesize"
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("must not execute"),
            counter: counter
        )
        let attestor = try executorTestAttestor(offset: offset)
        let policy = ExecutorRevokedPolicyEngine(
            underlying: try DefaultApprovalPolicyEngine(
                policyVersion: 1,
                sanitizationValidator: attestor
            )
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            policyEngine: policy
        )

        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)
        let loadedResult = try await handle.result()
        let result = try XCTUnwrap(loadedResult)

        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.terminalReason, .permissionDenied)
        XCTAssertEqual(result.status.failure?.code, "execution.tool-authorization-denied")
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.preparations, 1)
        XCTAssertEqual(counts.executions, 0)
        XCTAssertFalse(events.contains { event in
            if case .toolIntentRecorded = event.payload.event { return true }
            return false
        })
    }

    func testOrderedThreeToolBatchTerminatesAfterTwoTrailingEmptyResults() async throws {
        let offset = 965
        let model = try ExecutorTestModelDefinition(
            offset: offset,
            additionalCapabilities: [.multipleToolCalls]
        )
        let first = try ExecutorTestToolDefinition(name: "usable-first")
        let second = try ExecutorTestToolDefinition(name: "empty-second")
        let third = try ExecutorTestToolDefinition(name: "empty-third")
        let firstCall = try first.call(offset: offset)
        let secondCall = try second.call(offset: offset + 1)
        let thirdCall = try third.call(offset: offset + 2)
        let provider = try BatchToolSequenceModelProvider(
            model: model,
            calls: [firstCall, secondCall, thirdCall],
            answer: "must not reach synthesis"
        )
        let tools = try ExecutorTestToolCatalog(tools: [
            ExecutorTestTool(definition: first, behavior: .complete("usable result")),
            ExecutorTestTool(definition: second, behavior: .completeEmptyText),
            ExecutorTestTool(definition: third, behavior: .completeEmptyText),
        ])
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [first.descriptor, second.descriptor, third.descriptor],
            tools: tools,
            explicitlyRequestedToolIDs: [
                first.descriptor.id.logicalID,
                second.descriptor.id.logicalID,
                third.descriptor.id.logicalID,
            ]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)
        let loadedResult = try await handle.result()
        let result = try XCTUnwrap(loadedResult)
        XCTAssertEqual(result.status.state, .failed)
        XCTAssertEqual(result.status.terminalReason, .noProgress)
        XCTAssertEqual(result.status.failure?.code, "execution.no-progress")
        XCTAssertEqual(events.filter { event in
            if case .toolOutcomeRecorded = event.payload.event { return true }
            return false
        }.count, 3)
    }

    func testPauseDuringLateRiskyFailurePersistsUncertainOutcomeBeforeReconciliation() async throws {
        let offset = 966
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "late-risky-failure",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "must await reconciliation"
        )
        let providerFailure = try AgentFailure(
            code: "tool.fixture-failed",
            classification: .permanent,
            safeMessage: "The tool reported a failure.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
        let gate = BlockingModelGate()
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .failAfterBoundaryThenBlockStream(gate, providerFailure),
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
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = waiting.blockingReason else {
            return XCTFail("expected approval blocker")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(31_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        try await waitForExecutorCondition { await gate.hasEntered() }
        let executing = try await handle.status()
        let pause = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(32_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let pauseReceipt = try await handle.send(pause)
        XCTAssertEqual(pauseReceipt.currentStatus.state, .pausing)
        await gate.release()

        let reconciliation = try await waitForStatus(.waitingForReconciliation, handle: handle)
        guard case .reconciliation(let invocationID) = reconciliation.blockingReason else {
            return XCTFail("expected reconciliation blocker")
        }
        XCTAssertEqual(invocationID, call.invocationID)
        let invocations = try await harness.repository.loadToolInvocations(for: harness.request.runID)
        guard case .uncertain(let failure) = try XCTUnwrap(invocations.first?.outcome) else {
            return XCTFail("expected durable uncertain outcome")
        }
        XCTAssertEqual(failure.code, "execution.tool-returned-failure-uncertain")
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.boundaries, 1)
    }

    func testCancelWhileWaitingForApprovalCommitsOneTerminalResult() async throws {
        let offset = 901
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "cancel-pending-approval",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "must not continue"
        )
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .completeCrossingBoundary("must not execute")
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
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let waiting = try await waitForStatus(.waitingForApproval, handle: handle)

        let cancel = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(31_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .cancel,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await handle.send(cancel)
        XCTAssertEqual(receipt.disposition, .accepted)
        XCTAssertEqual(receipt.currentStatus.state, .cancelled)

        let events = try await collectTerminalEvents(from: handle)
        let loadedResult = try await handle.result()
        let result = try XCTUnwrap(loadedResult)
        XCTAssertEqual(result.status.state, .cancelled)
        XCTAssertEqual(result.status.terminalReason, .cancelledByUser)
        XCTAssertEqual(result.status.failure?.code, "execution.cancelled")
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
        let durableTools = try await harness.repository.loadToolInvocations(
            for: harness.request.runID
        )
        XCTAssertTrue(durableTools.isEmpty)
    }

    func testModelInterruptedOutcomeSettlesReservationAndWaitsForForeground() async throws {
        let offset = 902
        let model = try ExecutorTestModelDefinition(offset: offset)
        let provider = SequencedModelOutcomeProvider(
            model: model,
            outcomes: [.interrupted(nil)]
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let waiting = try await waitForStatus(.waitingForForeground, handle: handle)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )

        XCTAssertEqual(waiting.blockingReason, .foreground)
        let result = try await handle.result()
        XCTAssertNil(result)
        let loadedFacts = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let facts = try XCTUnwrap(loadedFacts)
        XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
        XCTAssertEqual(facts.budgetLedger?.consumed.quantities[.modelAttempts], 1)
        let events = try await harness.executor.controller.allEvents(runID: harness.request.runID)
        XCTAssertEqual(events.filter { event in
            if case .modelAttemptOutcome(.interrupted) = event.payload.event { return true }
            return false
        }.count, 1)
    }

    func testRetryableModelFailuresHonorZeroDelayAndBoundedExponentialClamp() async throws {
        struct Scenario {
            let offset: Int
            let delay: UInt64
            let failures: Int
            let expectedDelays: [UInt64]
        }
        let scenarios = [
            Scenario(offset: 903, delay: 0, failures: 1, expectedDelays: []),
            Scenario(offset: 904, delay: 20_000, failures: 2, expectedDelays: [20_000, 30_000]),
        ]

        for scenario in scenarios {
            let model = try ExecutorTestModelDefinition(offset: scenario.offset)
            let failure = try AgentFailure(
                code: "model.fixture-transient",
                classification: .transient,
                safeMessage: "The local model is temporarily unavailable.",
                retryAdvice: AgentRetryAdvice(
                    automaticallyRetryable: true,
                    maximumAdditionalAttempts: UInt16(scenario.failures),
                    delayMilliseconds: scenario.delay
                ),
                externalEffect: .confirmedNone,
                requiredUserAction: .none,
                redaction: RedactionMetadata(
                    classification: .internalMetadata,
                    policyVersion: 1
                )
            )
            let completion = try AgentModelCompletion(
                action: .finalAnswer(AgentAnswer(text: "retry completed")),
                usage: modelUsage(input: 4, output: 2, milliseconds: 3, memory: 24)
            )
            let outcomes = Array(
                repeating: AgentModelAttemptOutcome.failed(failure),
                count: scenario.failures
            ) + [.completed(completion)]
            let provider = SequencedModelOutcomeProvider(model: model, outcomes: outcomes)
            let clock = RecordingExecutorClock()
            let harness = try ExecutorTestHarness(
                offset: scenario.offset,
                provider: provider,
                model: model,
                clock: clock
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + scenario.offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            _ = try await collectTerminalEvents(from: handle)

            let loadedResult = try await handle.result()
            let result = try XCTUnwrap(loadedResult)
            XCTAssertEqual(result.status.state, .completed)
            XCTAssertEqual(result.answer?.text, "retry completed")
            XCTAssertEqual(
                result.usage.quantities[.modelAttempts],
                UInt64(scenario.failures + 1)
            )
            let recordedDelays = await clock.recordedDelays()
            XCTAssertEqual(recordedDelays, scenario.expectedDelays)
            let requests = await provider.script.capturedRequests()
            XCTAssertEqual(requests.count, scenario.failures + 1)
            let events = try await harness.executor.controller.allEvents(
                runID: harness.request.runID
            )
            XCTAssertEqual(events.filter { event in
                guard case .diagnostic(let recorded) = event.payload.event else { return false }
                return recorded.code == "execution.model-retry"
            }.count, scenario.failures)
        }
    }

    func testRestartedWorkerConservativelyRecoversDurableGeneratingAttempt() async throws {
        let offset = 905
        let model = try ExecutorTestModelDefinition(offset: offset)
        let providerGate = BlockingModelGate()
        let provider = try BlockingCompletionModelProvider(
            model: model,
            answer: "old process must not commit",
            gate: providerGate
        )
        let crashGate = ExecutorPostCommitCrashGate(targetState: .generating)
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
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        try await crashGate.waitUntilIntercepted()
        let oldWorker = await harness.executor.controller.workers[harness.request.runID]
        oldWorker?.cancel()
        await providerGate.release()
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let loadedBefore = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let before = try XCTUnwrap(loadedBefore)
        XCTAssertEqual(before.projection.state, .generating)
        XCTAssertEqual(before.budgetLedger?.reservations.count, 1)
        await harness.repository.close()

        let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopened,
            provider: provider
        )
        let handle = try await restarted.attach(to: handleID)
        await restarted.controller.schedule(runID: harness.request.runID)
        let waiting = try await waitForStatus(.waitingForForeground, handle: handle)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: restarted.controller
        )

        XCTAssertEqual(waiting.blockingReason, .foreground)
        let result = try await handle.result()
        XCTAssertNil(result)
        let loadedAfter = try await reopened.loadRunFacts(for: harness.request.runID)
        let after = try XCTUnwrap(loadedAfter)
        XCTAssertTrue(after.budgetLedger?.reservations.isEmpty == true)
        XCTAssertEqual(after.budgetLedger?.consumed.quantities[.modelAttempts], 1)
        let events = try await restarted.controller.allEvents(runID: harness.request.runID)
        XCTAssertEqual(events.filter { event in
            if case .modelAttemptOutcome(.interrupted) = event.payload.event { return true }
            return false
        }.count, 1)
    }

    func testExplicitResumeRepairsDurablePausingCheckpointForPauseAndCancel() async throws {
        for (index, action) in [
            AgentCommandAction.pause(reason: .userRequested),
            AgentCommandAction.cancel,
        ].enumerated() {
            let offset = 906 + index
            let model = try ExecutorTestModelDefinition(offset: offset)
            let providerGate = BlockingModelGate()
            let provider = try BlockingCompletionModelProvider(
                model: model,
                answer: "completed after recovered pause",
                gate: providerGate
            )
            let crashGate = ExecutorPostCommitCrashGate(targetState: .pausing)
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
                commandID: ExecutorTestID.command(30_000 + offset)
            )
            let original = try await harness.executor.attach(to: handleID)
            try await waitForExecutorCondition { await providerGate.hasEntered() }
            let generating = try await original.status()
            XCTAssertEqual(generating.state, .generating)

            let interruptedCommand = try AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(31_000 + offset),
                runID: harness.request.runID,
                expectedRunStateVersion: generating.stateVersion,
                action: action,
                issuedAt: AgentTimestamp(rawValue: 50_000)
            ))
            let sender = Task { try await original.send(interruptedCommand) }
            try await crashGate.waitUntilIntercepted()
            let loadedDurable = try await harness.repository.loadRunFacts(
                for: harness.request.runID
            )
            let durable = try XCTUnwrap(loadedDurable)
            XCTAssertEqual(durable.projection.state, .pausing)
            XCTAssertEqual(durable.budgetLedger?.reservations.count, 1)

            let oldWorker = await harness.executor.controller.workers[harness.request.runID]
            // Keep both old-process tasks suspended while a second SQLite connection performs
            // recovery. This models process loss without allowing cancellation cleanup in the old
            // controller to advance the durable `.pausing` checkpoint first.
            let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
            let recoveryLogger = ExecutorTestLogger()
            let recoveryProvider = try FixedCompletionModelProvider(
                model: model,
                answer: "completed after recovered pause"
            )
            let restarted = DurableAgentExecutor(
                repository: reopened,
                payloadStore: harness.payloadStore,
                inputFreezer: StaticAgentRunInputFreezer(inputs: harness.frozenInputs),
                modelProviders: try StaticAgentModelProviderCatalog(providers: [recoveryProvider]),
                policyEngine: try DefaultApprovalPolicyEngine(
                    policyVersion: 1,
                    sanitizationValidator: harness.attestor
                ),
                sanitizer: harness.attestor,
                residencyDriver: ScriptedModelResidencyDriver(),
                clock: FixedExecutorClock(100_000),
                logger: recoveryLogger
            )
            let handle = try await restarted.attach(to: handleID)
            let pausing = try await handle.status()
            XCTAssertEqual(pausing.state, .pausing)
            let resume = try AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(32_000 + offset),
                runID: harness.request.runID,
                expectedRunStateVersion: pausing.stateVersion,
                action: .resume,
                issuedAt: AgentTimestamp(rawValue: 100_000)
            ))
            let receipt = try await handle.send(resume)
            XCTAssertEqual(receipt.disposition, .accepted)

            if case .cancel = action {
                XCTAssertEqual(receipt.currentStatus.state, .cancelled)
                let loadedResult = try await handle.result()
                let result = try XCTUnwrap(loadedResult)
                XCTAssertEqual(result.status.terminalReason, .cancelledByUser)
            } else {
                XCTAssertEqual(receipt.currentStatus.state, .preparing)
                _ = try await collectTerminalEvents(from: handle)
                let loadedResult = try await handle.result()
                let result = try XCTUnwrap(loadedResult)
                let durableEvents = try await restarted.controller.allEvents(
                    runID: harness.request.runID
                )
                let trace = durableEvents.map {
                    String(describing: $0.payload.event)
                }.joined(separator: " | ")
                let logs = await recoveryLogger.snapshot().map {
                    "\($0.code):\($0.metadata)"
                }.joined(separator: " | ")
                XCTAssertEqual(result.status.state, .completed, "\(logs) :: \(trace)")
                XCTAssertEqual(
                    result.answer?.text,
                    "completed after recovered pause",
                    "\(logs) :: \(trace)"
                )
            }
            let loadedFinalFacts = try await reopened.loadRunFacts(for: harness.request.runID)
            let finalFacts = try XCTUnwrap(loadedFinalFacts)
            XCTAssertTrue(finalFacts.budgetLedger?.reservations.isEmpty == true)

            // Recovery is now durably complete, so releasing the cancelled old provider cannot
            // race the replacement worker or mutate the terminal/recovered state.
            sender.cancel()
            oldWorker?.cancel()
            await providerGate.release()
            _ = await sender.result
            try await waitForWorkerToStop(
                harness.request.runID,
                controller: harness.executor.controller
            )
        }
    }

    func testExplicitResumeClassifiesEveryExactClaimedToolRecovery() async throws {
        enum ExpectedRecovery {
            case retry
            case exhausted
            case reconcile
        }
        struct Scenario {
            let offset: Int
            let effect: AgentEffect
            let retryPolicy: ExternalRetryPolicy
            let idempotency: ExternalIdempotency
            let expected: ExpectedRecovery
        }
        let boundedRetry = try ExternalRetryPolicy(
            kind: .boundedExponential,
            maximumAttempts: 2,
            baseDelayMilliseconds: 1,
            maximumDelayMilliseconds: 1,
            allowsJitter: false
        )
        let scenarios = [
            Scenario(
                offset: 910,
                effect: .networkRead,
                retryPolicy: boundedRetry,
                idempotency: .pureRead,
                expected: .retry
            ),
            Scenario(
                offset: 911,
                effect: .networkRead,
                retryPolicy: .never,
                idempotency: .pureRead,
                expected: .exhausted
            ),
            Scenario(
                offset: 912,
                effect: .externalWrite,
                retryPolicy: .never,
                idempotency: .nonIdempotent,
                expected: .reconcile
            ),
        ]

        for scenario in scenarios {
            let model = try ExecutorTestModelDefinition(offset: scenario.offset)
            let definition = try ExecutorTestToolDefinition(
                name: "resume-claimed-\(scenario.offset)",
                effect: scenario.effect,
                retryPolicy: scenario.retryPolicy,
                idempotency: scenario.idempotency
            )
            let call = try definition.call(offset: scenario.offset)
            let script = ToolSequenceModelScript()
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "claimed recovery synthesized",
                script: script
            )
            let counter = ExecutorTestToolCounter()
            let tool = ExecutorTestTool(
                definition: definition,
                behavior: .completeCrossingBoundary("retried read"),
                counter: counter
            )
            let catalog = try SingleExecutorTestToolCatalog(tool: tool)
            let claimGate = ExecutorBoundaryClaimCrashGate()
            let harness = try ExecutorTestHarness(
                offset: scenario.offset,
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
                commandID: ExecutorTestID.command(30_000 + scenario.offset)
            )
            let original = try await harness.executor.attach(to: handleID)
            let approvalWait = try await waitForStatus(.waitingForApproval, handle: original)
            guard case .approval(let approvalID) = approvalWait.blockingReason else {
                return XCTFail("expected approval blocker")
            }
            let approval = try AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(31_000 + scenario.offset),
                runID: harness.request.runID,
                expectedRunStateVersion: approvalWait.stateVersion,
                action: .decideApproval(
                    approvalID: approvalID,
                    decision: .approved,
                    approvedScope: .exactInvocation
                ),
                issuedAt: AgentTimestamp(rawValue: 50_000)
            ))
            let approvalReceipt = try await original.send(approval)
            XCTAssertEqual(approvalReceipt.disposition, .accepted)
            try await claimGate.waitUntilIntercepted()
            defer {
                Task { await claimGate.abortAsProcessLoss() }
            }
            let invocations = try await harness.repository.loadToolInvocations(
                for: harness.request.runID
            )
            let invocation = try XCTUnwrap(invocations.first)
            let attempt = try ExternalOperationAttempt(
                prepared: invocation.request,
                attemptNumber: 1
            )
            let evidence = try await harness.repository.boundaryClaimEvidence(
                approvalID: approvalID,
                prepared: invocation.request,
                attempt: attempt
            )
            XCTAssertEqual(evidence, .exact)
            await harness.repository.close()

            let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
            let restarted = try makeReopenedExecutor(
                harness: harness,
                repository: reopened,
                provider: provider,
                tools: catalog
            )
            let handle = try await restarted.attach(to: handleID)
            let executing = try await handle.status()
            XCTAssertEqual(executing.state, .executingTools)
            let resume = try AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(32_000 + scenario.offset),
                runID: harness.request.runID,
                expectedRunStateVersion: executing.stateVersion,
                action: .resume,
                issuedAt: AgentTimestamp(rawValue: 50_000)
            ))
            let resumeReceipt = try await handle.send(resume)
            XCTAssertEqual(resumeReceipt.disposition, .accepted)

            if case .reconcile = scenario.expected {
                XCTAssertEqual(resumeReceipt.currentStatus.state, .waitingForReconciliation)
                guard case .reconciliation(let invocationID) =
                    resumeReceipt.currentStatus.blockingReason
                else { return XCTFail("expected reconciliation blocker") }
                XCTAssertEqual(invocationID, call.invocationID)
                let reconcile = try AgentCommandEnvelope(payload: AgentCommand(
                    commandID: ExecutorTestID.command(33_000 + scenario.offset),
                    runID: harness.request.runID,
                    expectedRunStateVersion: resumeReceipt.currentStatus.stateVersion,
                    action: .reconcile(invocationID: invocationID, decision: .failed),
                    issuedAt: AgentTimestamp(rawValue: 50_000)
                ))
                let reconcileReceipt = try await handle.send(reconcile)
                XCTAssertEqual(reconcileReceipt.disposition, .accepted)
                XCTAssertEqual(reconcileReceipt.currentStatus.state, .synthesizing)
            } else if case .exhausted = scenario.expected {
                XCTAssertEqual(resumeReceipt.currentStatus.state, .synthesizing)
            } else {
                XCTAssertEqual(resumeReceipt.currentStatus.state, .executingTools)
            }

            _ = try await collectTerminalEvents(from: handle)
            let loadedResult = try await handle.result()
            let result = try XCTUnwrap(loadedResult)
            XCTAssertEqual(result.status.state, .completed)
            XCTAssertEqual(result.answer?.text, "claimed recovery synthesized")
            let counts = await counter.snapshot()
            switch scenario.expected {
            case .retry:
                XCTAssertEqual(counts.executions, 2)
                XCTAssertEqual(counts.boundaries, 1)
            case .exhausted, .reconcile:
                XCTAssertEqual(counts.executions, 1)
                XCTAssertEqual(counts.boundaries, 0)
            }
            let durableTools = try await reopened.loadToolInvocations(
                for: harness.request.runID
            )
            let recoveredInvocation = try XCTUnwrap(durableTools.first)
            switch (scenario.expected, recoveredInvocation.outcome) {
            case (.retry, .some(.completed)):
                break
            case (.exhausted, .some(.failed(let failure))):
                XCTAssertEqual(failure.code, "execution.tool-retry-exhausted")
            case (.reconcile, .some(.uncertain(let failure))):
                XCTAssertEqual(failure.code, "execution.tool-recovery-uncertain")
            default:
                XCTFail("unexpected durable recovery outcome: \(String(describing: recoveredInvocation.outcome))")
            }
            let loadedFinalFacts = try await reopened.loadRunFacts(
                for: harness.request.runID
            )
            let finalFacts = try XCTUnwrap(loadedFinalFacts)
            XCTAssertTrue(finalFacts.budgetLedger?.reservations.isEmpty == true)

            await claimGate.abortAsProcessLoss()
            try await waitForWorkerToStop(
                harness.request.runID,
                controller: harness.executor.controller,
                maximumPolls: 5_000
            )
        }
    }

    func testWorkerRecoveryClassifiesClaimFreeAndExactClaimedToolAttemptsFromDurableFacts() async throws {
        do {
            let offset = 967
            let model = try ExecutorTestModelDefinition(offset: offset)
            let definition = try ExecutorTestToolDefinition(
                name: "worker-recovery-claim-free",
                effect: .networkRead,
                idempotency: .pureRead
            )
            let call = try definition.call(offset: offset)
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "claim-free recovery completed"
            )
            let counter = ExecutorTestToolCounter()
            let tool = ExecutorTestTool(
                definition: definition,
                behavior: .completeCrossingBoundary("claim-free result"),
                counter: counter
            )
            let catalog = try SingleExecutorTestToolCatalog(tool: tool)
            let crashGate = ExecutorPostCommitCrashGate(
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
                    ExecutorPostCommitGatedRepository(underlying: $0, gate: crashGate)
                }
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(30_000 + offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
            guard case .approval(let approvalID) = waiting.blockingReason else {
                return XCTFail("expected approval blocker")
            }
            _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(31_000 + offset),
                runID: harness.request.runID,
                expectedRunStateVersion: waiting.stateVersion,
                action: .decideApproval(
                    approvalID: approvalID,
                    decision: .approved,
                    approvedScope: .exactInvocation
                ),
                issuedAt: AgentTimestamp(rawValue: 50_000)
            )))
            try await crashGate.waitUntilIntercepted()
            let interruptedWorker = await harness.executor.controller.workers[harness.request.runID]
            interruptedWorker?.cancel()
            try await waitForWorkerToStop(
                harness.request.runID,
                controller: harness.executor.controller
            )
            let before = await counter.snapshot()
            XCTAssertEqual(before.executions, 0)
            let durable = try await harness.repository.loadToolInvocations(for: harness.request.runID)
            let invocation = try XCTUnwrap(durable.first)
            let attempt = try ExternalOperationAttempt(
                prepared: invocation.request,
                attemptNumber: 1
            )
            let claimEvidence = try await harness.repository.boundaryClaimEvidence(
                approvalID: approvalID,
                prepared: invocation.request,
                attempt: attempt
            )
            XCTAssertEqual(claimEvidence, .none)

            await harness.executor.controller.schedule(runID: harness.request.runID)
            _ = try await collectTerminalEvents(from: handle)
            let loadedResult = try await handle.result()
            XCTAssertEqual(loadedResult?.answer?.text, "claim-free recovery completed")
            let after = await counter.snapshot()
            XCTAssertEqual(after.executions, 1)
            XCTAssertEqual(after.boundaries, 1)
        }

        enum ExpectedWorkerRecovery {
            case retry
            case exhausted
            case reconcile
        }
        struct Scenario {
            let offset: Int
            let effect: AgentEffect
            let retryPolicy: ExternalRetryPolicy
            let idempotency: ExternalIdempotency
            let expected: ExpectedWorkerRecovery
        }
        let boundedRetry = try ExternalRetryPolicy(
            kind: .boundedExponential,
            maximumAttempts: 2,
            baseDelayMilliseconds: 1,
            maximumDelayMilliseconds: 1,
            allowsJitter: false
        )
        let scenarios = [
            Scenario(
                offset: 968,
                effect: .networkRead,
                retryPolicy: boundedRetry,
                idempotency: .pureRead,
                expected: .retry
            ),
            Scenario(
                offset: 969,
                effect: .networkRead,
                retryPolicy: .never,
                idempotency: .pureRead,
                expected: .exhausted
            ),
            Scenario(
                offset: 970,
                effect: .externalWrite,
                retryPolicy: .never,
                idempotency: .nonIdempotent,
                expected: .reconcile
            ),
        ]

        for scenario in scenarios {
            let model = try ExecutorTestModelDefinition(offset: scenario.offset)
            let definition = try ExecutorTestToolDefinition(
                name: "worker-recovery-exact-\(scenario.offset)",
                effect: scenario.effect,
                retryPolicy: scenario.retryPolicy,
                idempotency: scenario.idempotency
            )
            let call = try definition.call(offset: scenario.offset)
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "exact worker recovery completed"
            )
            let counter = ExecutorTestToolCounter()
            let tool = ExecutorTestTool(
                definition: definition,
                behavior: .completeCrossingBoundary("recovered result"),
                counter: counter
            )
            let catalog = try SingleExecutorTestToolCatalog(tool: tool)
            let claimGate = ExecutorBoundaryClaimCrashGate()
            let harness = try ExecutorTestHarness(
                offset: scenario.offset,
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
                commandID: ExecutorTestID.command(30_000 + scenario.offset)
            )
            let original = try await harness.executor.attach(to: handleID)
            let waiting = try await waitForStatus(.waitingForApproval, handle: original)
            guard case .approval(let approvalID) = waiting.blockingReason else {
                return XCTFail("expected approval blocker")
            }
            _ = try await original.send(AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(31_000 + scenario.offset),
                runID: harness.request.runID,
                expectedRunStateVersion: waiting.stateVersion,
                action: .decideApproval(
                    approvalID: approvalID,
                    decision: .approved,
                    approvedScope: .exactInvocation
                ),
                issuedAt: AgentTimestamp(rawValue: 50_000)
            )))
            try await claimGate.waitUntilIntercepted()
            await harness.repository.close()

            let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
            let restarted = try makeReopenedExecutor(
                harness: harness,
                repository: reopened,
                provider: provider,
                tools: catalog
            )
            let handle = try await restarted.attach(to: handleID)
            await restarted.controller.schedule(runID: harness.request.runID)

            switch scenario.expected {
            case .retry, .exhausted:
                _ = try await collectTerminalEvents(from: handle)
                let loadedResult = try await handle.result()
                let result = try XCTUnwrap(loadedResult)
                XCTAssertEqual(result.status.state, .completed)
                XCTAssertEqual(result.answer?.text, "exact worker recovery completed")
            case .reconcile:
                let reconciliation = try await waitForStatus(.waitingForReconciliation, handle: handle)
                guard case .reconciliation(let invocationID) = reconciliation.blockingReason else {
                    return XCTFail("expected reconciliation blocker")
                }
                XCTAssertEqual(invocationID, call.invocationID)
                _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
                    commandID: ExecutorTestID.command(32_000 + scenario.offset),
                    runID: harness.request.runID,
                    expectedRunStateVersion: reconciliation.stateVersion,
                    action: .reconcile(invocationID: invocationID, decision: .failed),
                    issuedAt: AgentTimestamp(rawValue: 50_000)
                )))
                _ = try await collectTerminalEvents(from: handle)
            }

            let durable = try await reopened.loadToolInvocations(for: harness.request.runID)
            let recovered = try XCTUnwrap(durable.first)
            let counts = await counter.snapshot()
            switch (scenario.expected, recovered.outcome) {
            case (.retry, .some(.completed)):
                XCTAssertEqual(counts.executions, 2)
                XCTAssertEqual(counts.boundaries, 1)
            case (.exhausted, .some(.failed(let failure))):
                XCTAssertEqual(failure.code, "execution.tool-contract-failed")
                XCTAssertEqual(counts.executions, 1)
                XCTAssertEqual(counts.boundaries, 0)
            case (.reconcile, .some(.uncertain(let failure))):
                XCTAssertEqual(failure.code, "execution.tool-recovery-uncertain")
                XCTAssertEqual(counts.executions, 1)
                XCTAssertEqual(counts.boundaries, 0)
            default:
                XCTFail("unexpected direct worker recovery outcome")
            }

            await claimGate.abortAsProcessLoss()
            try await waitForWorkerToStop(
                harness.request.runID,
                controller: harness.executor.controller,
                maximumPolls: 5_000
            )
        }
    }

    func testMultipleUserResponsesAreCompiledInStableInteractionIdentityOrder() async throws {
        let offset = 971
        let model = try ExecutorTestModelDefinition(offset: offset)
        let firstID = InteractionRequestID(rawValue: ExecutorTestID.uuid(88_972))
        let secondID = InteractionRequestID(rawValue: ExecutorTestID.uuid(88_971))
        let script = MultiUserInputModelScript()
        let provider = try MultiUserInputThenAnswerModelProvider(
            model: model,
            runID: ExecutorTestID.run(offset),
            interactionIDs: [firstID, secondID],
            answer: "two responses compiled",
            script: script
        )
        let harness = try ExecutorTestHarness(offset: offset, provider: provider, model: model)
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let responses: [(InteractionRequestID, JSONValue)] = [
            (firstID, .string("A")),
            (secondID, .string("B")),
        ]
        for (index, response) in responses.enumerated() {
            let waiting = try await waitForStatus(.waitingForUser, handle: handle)
            guard case .userInput(let requestID) = waiting.blockingReason else {
                return XCTFail("expected user-input blocker")
            }
            XCTAssertEqual(requestID, response.0)
            let value = try UserInputResponse(
                requestID: response.0,
                expectedRunStateVersion: waiting.stateVersion,
                value: response.1
            )
            let receipt = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(31_000 + offset + index),
                runID: harness.request.runID,
                expectedRunStateVersion: waiting.stateVersion,
                action: .respond(value),
                issuedAt: AgentTimestamp(rawValue: 50_000)
            )))
            XCTAssertEqual(receipt.disposition, .accepted)
            XCTAssertEqual(receipt.currentStatus.state, .waitingForModel)
        }
        _ = try await collectTerminalEvents(from: handle)
        let loadedResult = try await handle.result()
        XCTAssertEqual(loadedResult?.answer?.text, "two responses compiled")

        let requests = await script.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        let responseMessages = try XCTUnwrap(requests.last).messages.filter { message in
            message.role == .user && (message.content == "\"A\"" || message.content == "\"B\"")
        }
        XCTAssertEqual(responseMessages.map(\.content), ["\"B\"", "\"A\""])
    }

    func testHydratingSubscriptionOrdersMultipleBufferedLiveCommitsBySequence() async throws {
        let offset = 972
        let model = try ExecutorTestModelDefinition(offset: offset)
        let modelGate = BlockingModelGate()
        let provider = try BlockingCompletionModelProvider(
            model: model,
            answer: "buffered subscription completed",
            gate: modelGate
        )
        let readGate = ExecutorReadEventsGate()
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
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        try await waitForExecutorCondition { await modelGate.hasEntered() }

        let stream = harness.executor.controller.eventStream(for: handleID, after: nil)
        async let observed = collectDurableEvents(stream)
        try await readGate.waitUntilIntercepted()
        await modelGate.release()
        _ = try await waitForStatus(.completed, handle: handle)
        await readGate.release()

        let events = try await observed
        XCTAssertGreaterThan(events.count, 3)
        XCTAssertEqual(events.map(\.payload.sequence), Array(1 ... UInt64(events.count)))
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
        let loadedResult = try await handle.result()
        XCTAssertEqual(loadedResult?.answer?.text, "buffered subscription completed")
    }

    func testControllerRejectsMissingBindingsPayloadsAndDuplicateLiveToolOwnership() async throws {
        let offset = 973
        let model = try ExecutorTestModelDefinition(offset: offset)
        let provider = try FixedCompletionModelProvider(model: model, answer: "edge fixture")
        let harness = try ExecutorTestHarness(offset: offset, provider: provider, model: model)
        let missingHandle = AgentExecutionHandleID(rawValue: ExecutorTestID.uuid(99_973))
        let missingRun = AgentRunID(rawValue: ExecutorTestID.uuid(99_974))
        let missingCommand = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(40_973),
            runID: missingRun,
            expectedRunStateVersion: 1,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))

        await assertCapturedExecutionError(.executionNotFound(missingHandle)) {
            _ = try await harness.executor.controller.send(missingCommand, through: missingHandle)
        }
        await assertCapturedExecutionError(.executionNotFound(missingHandle)) {
            _ = try await harness.executor.controller.status(for: missingHandle)
        }
        await assertCapturedExecutionError(.executionNotFound(missingHandle)) {
            _ = try await harness.executor.controller.result(for: missingHandle)
        }
        await assertCapturedExecutionError(.invalidRecoveryBoundary) {
            _ = try await harness.executor.controller.loadRun(missingRun)
        }
        await assertCapturedExecutionError(.invalidRecoveryBoundary) {
            _ = try await harness.executor.controller.commitEvents(
                runID: missingRun,
                identity: .outcome(ExecutionStableID.event(runID: missingRun, key: "missing"))
            ) { _ in [] }
        }

        do {
            for try await _ in harness.executor.controller.eventStream(
                for: missingHandle,
                after: nil
            ) {
                XCTFail("a missing execution cannot publish durable events")
            }
            XCTFail("expected missing durable event stream to fail")
        } catch {
            XCTAssertEqual(error as? AgentExecutionError, .executionNotFound(missingHandle))
        }
        do {
            let stream = await harness.executor.controller.ephemeralEventStream(for: missingHandle)
            for try await _ in stream {
                XCTFail("a missing execution cannot publish ephemeral events")
            }
            XCTFail("expected missing ephemeral stream to fail")
        } catch {
            XCTAssertEqual(error as? AgentExecutionError, .executionNotFound(missingHandle))
        }

        let bytes = Data("stable payload".utf8)
        let artifact = try await harness.payloadStore.commit(
            data: bytes,
            mimeType: "application/json",
            semanticType: "executor-edge.v1",
            runID: harness.request.runID,
            stepID: nil,
            invocationID: nil,
            owner: .run(harness.request.runID),
            sensitivity: .internalMetadata
        )
        await assertCapturedExecutionError(.internalInvariant("artifact digest mismatch")) {
            _ = try await harness.executor.controller.stableReference(
                artifact,
                data: Data("different payload".utf8)
            )
        }
        let absentReference = try AgentStableBoundaryReference(
            digest: StableDigest.sha256(Data("absent".utf8)),
            artifactID: ArtifactID(rawValue: ExecutorTestID.uuid(99_975))
        )
        await assertCapturedExecutionError(.invalidRecoveryBoundary) {
            _ = try await harness.executor.controller.loadPayload(
                JSONValue.self,
                reference: absentReference
            )
        }

        let cancellation = ExecutionCancellationToken()
        let invocationID = ExecutorTestID.invocation(offset)
        try await harness.executor.controller.registerToolCancellation(
            cancellation,
            runID: harness.request.runID,
            invocationID: invocationID
        )
        await assertCapturedExecutionError(
            .internalInvariant("run already owns a live tool cancellation")
        ) {
            try await harness.executor.controller.registerToolCancellation(
                ExecutionCancellationToken(),
                runID: harness.request.runID,
                invocationID: ExecutorTestID.invocation(offset + 1)
            )
        }
        await harness.executor.controller.clearToolCancellation(
            runID: harness.request.runID,
            invocationID: invocationID
        )

        let validFrozenData = try JSONEncoder().encode(harness.frozenInputs)
        var unsupportedVersion = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validFrozenData) as? [String: Any]
        )
        unsupportedVersion["version"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(
            FrozenAgentRunInputs.self,
            from: JSONSerialization.data(withJSONObject: unsupportedVersion, options: [.sortedKeys])
        ))
        var invalidFrozen = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validFrozenData) as? [String: Any]
        )
        invalidFrozen["maximumAdvertisedTools"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(
            FrozenAgentRunInputs.self,
            from: JSONSerialization.data(withJSONObject: invalidFrozen, options: [.sortedKeys])
        ))

        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(41_973)
        )
        let wrongRunCommand = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(42_973),
            runID: missingRun,
            expectedRunStateVersion: 1,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        await assertCapturedExecutionError(.commandTargetsAnotherRun) {
            _ = try await harness.executor.controller.send(wrongRunCommand, through: handleID)
        }
        let handle = try await harness.executor.attach(to: handleID)
        _ = try await collectTerminalEvents(from: handle)
    }

    func testWorkerErrorClassificationFailsCreatedRunsWithStableTerminalReasons() async throws {
        struct Scenario {
            let offset: Int
            let error: any Error
            let reason: AgentTerminalReason
            let code: String
        }
        let model = try ExecutorTestModelDefinition(offset: 920)
        let toolDefinition = try ExecutorTestToolDefinition(name: "missing-worker-tool")
        let scenarios: [Scenario] = [
            Scenario(
                offset: 920,
                error: AgentContractError.budgetExceeded(
                    dimension: .modelAttempts,
                    limit: 0,
                    requested: 1
                ),
                reason: .budgetExceeded,
                code: "execution.budget-exceeded"
            ),
            Scenario(
                offset: 921,
                error: ContextCompilationError.contextUnsatisfiable(
                    requiredTokens: 2,
                    availableTokens: 1
                ),
                reason: .contextUnsatisfiable,
                code: "execution.context-unsatisfiable"
            ),
            Scenario(
                offset: 922,
                error: AgentModelRuntimeError.providerNotFound(model.descriptor.id),
                reason: .modelUnavailable,
                code: "execution.model-unavailable"
            ),
            Scenario(
                offset: 923,
                error: AgentContractError.authorizationDenied,
                reason: .permissionDenied,
                code: "execution.authorization-denied"
            ),
            Scenario(
                offset: 924,
                error: AgentExecutionError.toolUnavailable(toolDefinition.descriptor.id),
                reason: .toolUnavailable,
                code: "execution.tool-unavailable"
            ),
            Scenario(
                offset: 925,
                error: AgentExecutionError.dependencyUnavailable("model"),
                reason: .modelUnavailable,
                code: "execution.dependency-unavailable"
            ),
            Scenario(
                offset: 926,
                error: AgentExecutionError.internalInvariant("fixture"),
                reason: .internalFailure,
                code: "execution.worker-failed"
            ),
        ]

        for scenario in scenarios {
            let scenarioModel = try ExecutorTestModelDefinition(offset: scenario.offset)
            let provider = try FixedCompletionModelProvider(
                model: scenarioModel,
                answer: "must not execute"
            )
            let crashGate = ExecutorPostCommitCrashGate(targetState: .created)
            let harness = try ExecutorTestHarness(
                offset: scenario.offset,
                provider: provider,
                model: scenarioModel,
                repositoryFactory: {
                    ExecutorPostCommitGatedRepository(underlying: $0, gate: crashGate)
                }
            )
            let submission = Task {
                try await harness.executor.submit(
                    harness.request,
                    commandID: ExecutorTestID.command(30_000 + scenario.offset)
                )
            }
            try await crashGate.waitUntilIntercepted()
            let loadedFacts = try await harness.repository.loadRunFacts(
                for: harness.request.runID
            )
            let facts = try XCTUnwrap(loadedFacts)
            let handleID = try XCTUnwrap(facts.submission?.executionHandleID)
            submission.cancel()
            _ = await submission.result

            try await harness.executor.controller.failRun(
                runID: harness.request.runID,
                workerError: scenario.error
            )
            let handle = try await harness.executor.attach(to: handleID)
            let loadedResult = try await handle.result()
            let result = try XCTUnwrap(loadedResult)
            XCTAssertEqual(result.status.state, .failed)
            XCTAssertEqual(result.status.terminalReason, scenario.reason)
            XCTAssertEqual(result.status.failure?.code, scenario.code)
            let events = try await harness.executor.controller.allEvents(
                runID: harness.request.runID
            )
            XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
        }
    }

    func testLegacyBoundaryClaimRequiresReconciliationWithoutReplayingTheTool() async throws {
        let offset = 974
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "legacy-boundary-claim",
            effect: .networkRead,
            idempotency: .pureRead
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "legacy claim reconciled",
            script: script
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .completeCrossingBoundary("must not execute"),
            counter: counter
        )
        let crashGate = ExecutorPostCommitCrashGate(
            targetState: .executingTools,
            targetOccurrence: 3
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, gate: crashGate)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("expected approval blocker")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(31_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        try await crashGate.waitUntilIntercepted()
        let interruptedWorker = await harness.executor.controller.workers[harness.request.runID]
        interruptedWorker?.cancel()
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )

        let invocations = try await harness.repository.loadToolInvocations(
            for: harness.request.runID
        )
        let invocation = try XCTUnwrap(invocations.first)
        let attempt = try ExternalOperationAttempt(
            prepared: invocation.request,
            attemptNumber: 1
        )
        let hop = try ExternalOperationBoundaryHop(
            prepared: invocation.request,
            attempt: attempt,
            destination: invocation.request.plan.destination
        )
        try await harness.repository.recordExternalClaim(ExternalClaimReference(
            id: "boundary-hop:\(hop.fingerprint.rawValue)",
            runID: harness.request.runID,
            invocationID: call.invocationID,
            kind: "authorization-boundary-hop",
            payloadDigest: StableDigest.sha256(Data("legacy-claim".utf8))
        ))
        let evidence = try await harness.repository.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: invocation.request,
            attempt: attempt
        )
        XCTAssertEqual(evidence, .legacyConservative)

        await harness.executor.controller.schedule(runID: harness.request.runID)
        let reconciliation = try await waitForStatus(.waitingForReconciliation, handle: handle)
        guard case .reconciliation(let invocationID) = reconciliation.blockingReason else {
            return XCTFail("expected reconciliation blocker")
        }
        XCTAssertEqual(invocationID, call.invocationID)
        let beforeReconciliation = await counter.snapshot()
        XCTAssertEqual(beforeReconciliation.executions, 0)
        let receipt = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(32_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: reconciliation.stateVersion,
            action: .reconcile(invocationID: invocationID, decision: .failed),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(receipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "legacy claim reconciled")
        let afterReconciliation = await counter.snapshot()
        XCTAssertEqual(afterReconciliation.executions, 0)

        let recoveredInvocations = try await harness.repository.loadToolInvocations(
            for: harness.request.runID
        )
        let recovered = try XCTUnwrap(recoveredInvocations.first)
        guard case .uncertain(let failure) = recovered.outcome else {
            return XCTFail("expected a durable uncertain legacy outcome")
        }
        XCTAssertEqual(failure.code, "execution.legacy-boundary-claim-uncertain")
    }

    func testPauseAtAnExhaustedSafeAttemptPersistsNoEffectAndSynthesizes() async throws {
        let offset = 975
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "safe-exhausted-pause",
            effect: .networkRead,
            retryPolicy: .never,
            idempotency: .pureRead
        )
        let call = try definition.call(offset: offset)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "safe interruption synthesized"
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .blockFirstAttemptBeforeBoundaryThenComplete("must not replay"),
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
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("expected approval blocker")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(31_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        try await waitForExecutorCondition {
            (await counter.snapshot()).executions == 1
        }
        let executing = try await handle.status()
        XCTAssertEqual(executing.state, .executingTools)
        let pause = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(32_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(pause.disposition, .accepted)
        let paused = try await waitForStatus(.paused, handle: handle)
        let pausedCounts = await counter.snapshot()
        XCTAssertEqual(pausedCounts.boundaries, 0)

        let resume = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(33_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(resume.disposition, .accepted)
        _ = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "safe interruption synthesized")
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.executions, 1)
        XCTAssertEqual(counts.boundaries, 0)

        let durableInvocations = try await harness.repository.loadToolInvocations(
            for: harness.request.runID
        )
        let durable = try XCTUnwrap(durableInvocations.first)
        guard case .failed(let failure) = durable.outcome else {
            return XCTFail("expected a durable safe interruption failure")
        }
        XCTAssertEqual(failure.code, "execution.tool-attempt-interrupted")
        XCTAssertEqual(failure.externalEffect, .confirmedNone)
        let finalFacts = try await harness.repository.loadRunFacts(for: harness.request.runID)
        XCTAssertTrue(finalFacts?.budgetLedger?.reservations.isEmpty == true)
    }

    func testLegacyReconciliationWithoutToolOutcomeStillCompilesOneSafeResult() async throws {
        let offset = 976
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "legacy-no-outcome-reconciliation",
            effect: .networkRead,
            idempotency: .pureRead
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "legacy no-outcome context compiled",
            script: script
        )
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .completeCrossingBoundary("must not execute")
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
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("expected approval blocker")
        }
        let loaded = try await harness.executor.controller.loadRun(harness.request.runID)
        let approval = try XCTUnwrap(loaded.1.approvals[approvalID]?.request)
        let interruption = try AgentFailure(
            code: "execution.tool-attempt-interrupted-uncertain",
            classification: .potentiallySideEffecting,
            safeMessage: "A legacy interrupted operation needs reconciliation.",
            retryAdvice: .never,
            externalEffect: .uncertain,
            requiredUserAction: .reconcile,
            details: [
                "invocationID": call.invocationID.description,
                "attemptNumber": "1",
            ],
            redaction: AgentRunController.publicRedaction
        )
        let fixtureID = ExecutionStableID.event(
            runID: harness.request.runID,
            key: "legacy-no-outcome-reconciliation-fixture"
        )
        _ = try await harness.executor.controller.commitEvents(
            runID: harness.request.runID,
            identity: .outcome(fixtureID)
        ) { builder in
            let executing = try AgentRunStatus(
                state: .executingTools,
                stateVersion: builder.stateVersion + 1
            )
            var events = [try builder.append(
                id: ExecutionStableID.event(
                    runID: harness.request.runID,
                    key: "legacy-no-outcome-executing"
                ),
                event: .statusChanged(executing),
                transitionTo: .executingTools,
                redaction: AgentRunController.publicRedaction
            )]
            events.append(try builder.append(
                id: fixtureID,
                event: .toolIntentRecorded(approval.prepared),
                redaction: AgentRunController.publicRedaction
            ))
            events.append(try builder.append(
                id: ExecutionStableID.event(
                    runID: harness.request.runID,
                    key: "legacy-no-outcome-interruption"
                ),
                event: .diagnostic(interruption),
                redaction: AgentRunController.publicRedaction
            ))
            let waiting = try AgentRunStatus(
                state: .waitingForReconciliation,
                stateVersion: builder.stateVersion + 1,
                failure: interruption,
                blockingReason: .reconciliation(invocationID: call.invocationID)
            )
            events.append(try builder.append(
                id: ExecutionStableID.event(
                    runID: harness.request.runID,
                    key: "legacy-no-outcome-waiting"
                ),
                event: .statusChanged(waiting),
                transitionTo: .waitingForReconciliation,
                redaction: AgentRunController.publicRedaction
            ))
            return events
        }

        let waiting = try await handle.status()
        XCTAssertEqual(waiting.state, .waitingForReconciliation)
        let receipt = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(31_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .reconcile(invocationID: call.invocationID, decision: .succeeded),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(receipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "legacy no-outcome context compiled")
        let requests = await script.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        let synthesis = try XCTUnwrap(requests.last).messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(synthesis.contains("execution.reconciled-succeeded"))
        XCTAssertTrue(synthesis.contains("confirmed successful"))
    }

    func testResumeDuringPostDenialSynthesisDoesNotReenterTheDeniedTool() async throws {
        let offset = 977
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "post-denial-resume",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let synthesisGate = BlockingModelGate()
        let provider = try GatedSynthesisToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "denial remained final",
            script: script,
            gate: synthesisGate
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .completeCrossingBoundary("must never execute"),
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
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("expected approval blocker")
        }
        let denial = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(31_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .denied,
                approvedScope: nil
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(denial.disposition, .accepted)
        XCTAssertEqual(denial.currentStatus.state, .synthesizing)
        try await waitForExecutorCondition { await synthesisGate.hasEntered() }
        let generating = try await handle.status()
        XCTAssertEqual(generating.state, .generating)

        let pause = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(32_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: generating.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(pause.disposition, .accepted)
        await synthesisGate.release()
        let paused = try await waitForStatus(.paused, handle: handle)
        let resume = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(33_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(resume.disposition, .accepted)
        _ = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "denial remained final")
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.executions, 0)

        let requests = await script.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[1].advertisedTools.isEmpty)
        XCTAssertTrue(requests[2].advertisedTools.isEmpty)
        let events = try await harness.executor.controller.allEvents(runID: harness.request.runID)
        XCTAssertEqual(events.filter { event in
            if case .approvalRequested = event.payload.event { return true }
            return false
        }.count, 1)
        XCTAssertFalse(events.contains { event in
            if case .toolIntentRecorded = event.payload.event { return true }
            return false
        })
    }

    func testResumeDuringPostReconciliationSynthesisDoesNotReopenReconciliation() async throws {
        let offset = 978
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "post-reconciliation-resume",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let synthesisGate = BlockingModelGate()
        let provider = try GatedSynthesisToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "reconciliation remained final",
            script: script,
            gate: synthesisGate
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
            commandID: ExecutorTestID.command(30_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("expected approval blocker")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(31_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        let reconciliation = try await waitForStatus(.waitingForReconciliation, handle: handle)
        guard case .reconciliation(let invocationID) = reconciliation.blockingReason else {
            return XCTFail("expected reconciliation blocker")
        }
        XCTAssertEqual(invocationID, call.invocationID)
        let resolution = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(32_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: reconciliation.stateVersion,
            action: .reconcile(invocationID: invocationID, decision: .failed),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(resolution.disposition, .accepted)
        XCTAssertEqual(resolution.currentStatus.state, .synthesizing)
        try await waitForExecutorCondition { await synthesisGate.hasEntered() }
        let generating = try await handle.status()
        XCTAssertEqual(generating.state, .generating)

        let pause = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(33_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: generating.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(pause.disposition, .accepted)
        await synthesisGate.release()
        let paused = try await waitForStatus(.paused, handle: handle)
        let resume = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(34_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: paused.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(resume.disposition, .accepted)
        _ = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "reconciliation remained final")
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.executions, 1)
        XCTAssertEqual(counts.boundaries, 1)

        let requests = await script.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[1].advertisedTools.isEmpty)
        XCTAssertTrue(requests[2].advertisedTools.isEmpty)
        let finalContext = requests[2].messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(finalContext.contains("execution.reconciled-failed"))
        let events = try await harness.executor.controller.allEvents(runID: harness.request.runID)
        XCTAssertEqual(events.filter { event in
            guard case .statusChanged(let status) = event.payload.event else { return false }
            return status.state == .waitingForReconciliation
        }.count, 1)
    }
}

private func collectDurableEvents(
    _ stream: AsyncThrowingStream<AgentEventEnvelope, Error>
) async throws -> [AgentEventEnvelope] {
    var events: [AgentEventEnvelope] = []
    for try await event in stream { events.append(event) }
    return events
}

private func assertCapturedExecutionError(
    _ expected: AgentExecutionError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? AgentExecutionError, expected, file: file, line: line)
    }
}

private struct ExecutorRevokedPolicyEngine: ApprovalPolicyEngine, Sendable {
    let underlying: DefaultApprovalPolicyEngine

    var policyVersion: UInt32 { underlying.policyVersion }

    func evaluate(
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority _: TrustedRunAuthority?,
        feature: ApprovalFeatureState,
        interaction: ApprovalInteractionContext,
        candidateReceipts: [ApprovalReceipt],
        at timestamp: AgentTimestamp
    ) -> ApprovalPolicyEvaluation {
        underlying.evaluate(
            prepared: prepared,
            trustedRunAuthority: nil,
            feature: feature,
            interaction: interaction,
            candidateReceipts: candidateReceipts,
            at: timestamp
        )
    }

    func bind(
        prepared: PreparedExternalOperationRequest,
        receipt: ApprovalReceipt,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        try await underlying.bind(
            prepared: prepared,
            receipt: receipt,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
    }

    func bindLocalPolicy(
        prepared: PreparedExternalOperationRequest,
        approvalID: ApprovalID,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        try await underlying.bindLocalPolicy(
            prepared: prepared,
            approvalID: approvalID,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
    }

    func validateCurrentAuthorization(
        receipt: ApprovalReceipt,
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws {
        try await underlying.validateCurrentAuthorization(
            receipt: receipt,
            prepared: prepared,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
    }
}
