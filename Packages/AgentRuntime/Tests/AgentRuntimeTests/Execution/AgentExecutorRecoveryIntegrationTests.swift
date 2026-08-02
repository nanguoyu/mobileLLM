// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-RECOVERY-001
// TEST-ID: AHT-LOOP-001
final class AgentExecutorRecoveryIntegrationTests: XCTestCase {
    func testExhaustedModelAttemptBudgetFailsBeforeProviderAndLeavesNoLeaseOrReservation() async throws {
        let model = try ExecutorTestModelDefinition(offset: 99)
        let counter = ScriptedInvocationCounter()
        let provider = try FixedCompletionModelProvider(
            model: model,
            answer: "Must not execute",
            invocationCounter: counter
        )
        let defaults = try AgentBudget.firstReleaseDefaults(
            contextTokensPerAttempt: 4_096,
            outputTokens: 6_144,
            peakMemoryBytes: 1_073_741_824
        )
        var limits = Dictionary(uniqueKeysWithValues: defaults.limits.entries.map {
            ($0.dimension, $0.value)
        })
        limits[.modelAttempts] = 0
        let exhaustedBudget = try AgentBudget(
            limits: BudgetQuantities(limits),
            maximumThermalState: defaults.maximumThermalState,
            memoryPressureResponse: defaults.memoryPressureResponse
        )
        let harness = try ExecutorTestHarness(
            offset: 99,
            provider: provider,
            model: model,
            budget: exhaustedBudget
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(99)
        )
        let handle = try await harness.executor.attach(to: handleID)
        _ = try await collectTerminalEvents(from: handle)

        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 0)
        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .failed)
        XCTAssertEqual(result?.status.terminalReason, .budgetExceeded)
        XCTAssertEqual(result?.status.failure?.code, "execution.budget-exceeded")
        let factsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let facts = try XCTUnwrap(factsValue)
        XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
        XCTAssertEqual(facts.budgetLedger?.consumed.quantities[.modelAttempts], 0)
        let arbiter = await harness.executor.controller.arbiter.snapshot()
        XCTAssertNil(arbiter.rootOwner)
        XCTAssertNil(arbiter.decodeOwner)
        let residency = await harness.residencyDriver.snapshot()
        XCTAssertTrue(
            residency.calls.isEmpty,
            "hard budget preflight must reject before model residency is touched"
        )
        XCTAssertEqual(residency.lifecycleViolations, 0)
    }

    func testMalformedActionGetsExactlyOneConstrainedRepairAndReleasesFailedDecode() async throws {
        let model = try ExecutorTestModelDefinition(offset: 100)
        let script = MalformedThenValidModelScript()
        let provider = try MalformedThenValidModelProvider(
            model: model,
            answer: "Repaired answer",
            script: script
        )
        let claimProbe = ExecutorBoundaryClaimProbe()
        let harness = try ExecutorTestHarness(
            offset: 100,
            provider: provider,
            model: model,
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, claimProbe: claimProbe)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(100)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)

        let requests = await script.capturedRequests()
        guard requests.count == 2 else {
            return XCTFail("expected exactly two model attempts, got \(requests.count)")
        }
        XCTAssertEqual(requests[0].generationParameters.thinkingMode, .automatic)
        XCTAssertEqual(requests[0].generationParameters.temperature, 0.7)
        XCTAssertEqual(requests[1].generationParameters.thinkingMode, .disabled)
        XCTAssertEqual(requests[1].generationParameters.temperature, 0)

        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Repaired answer")
        XCTAssertEqual(result?.usage.quantities[.modelAttempts], 2)
        XCTAssertEqual(result?.usage.quantities[.structuredRepairs], 1)
        XCTAssertEqual(events.compactMap { event -> String? in
            guard case .diagnostic(let failure) = event.payload.event else { return nil }
            return failure.code
        }.filter { $0 == "execution.structured-repair" }.count, 1)
        let claims = await claimProbe.snapshot()
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims.map(\.attempt.attemptNumber), [1, 1])

        let factsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let facts = try XCTUnwrap(factsValue)
        XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
        let arbiter = await harness.executor.controller.arbiter.snapshot()
        XCTAssertNil(arbiter.rootOwner)
        XCTAssertNil(arbiter.decodeOwner)
        XCTAssertNil(arbiter.residencyTransition)
        let residency = await harness.residencyDriver.snapshot()
        XCTAssertEqual(residency.lifecycleViolations, 0)
        XCTAssertEqual(residency.calls.map(\.operation), [.load, .cancelAndDrain])
    }

    func testSecondMalformedActionTerminatesRepairWithoutThirdModelAttempt() async throws {
        let model = try ExecutorTestModelDefinition(offset: 101)
        let script = AlwaysMalformedModelScript()
        let provider = try AlwaysMalformedModelProvider(model: model, script: script)
        let harness = try ExecutorTestHarness(
            offset: 101,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(101)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)

        let attemptCount = await script.count()
        XCTAssertEqual(attemptCount, 2)
        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .failed)
        XCTAssertEqual(result?.status.terminalReason, .internalFailure)
        XCTAssertEqual(result?.status.failure?.code, "execution.structured-repair-exhausted")
        XCTAssertNil(result?.answer)
        XCTAssertEqual(result?.usage.quantities[.modelAttempts], 2)
        XCTAssertEqual(result?.usage.quantities[.structuredRepairs], 1)
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
        let residency = await harness.residencyDriver.snapshot()
        XCTAssertEqual(residency.calls.map(\.operation), [.load, .cancelAndDrain, .cancelAndDrain])
        let arbiter = await harness.executor.controller.arbiter.snapshot()
        XCTAssertNil(arbiter.rootOwner)
        XCTAssertNil(arbiter.decodeOwner)
    }

    func testTrustedMalformedActionFailureIsRepairedDespiteIncompatibleClassification() async throws {
        try await assertTrustedStructuredFailureIsRepaired(
            code: "model.local.malformed-action",
            offset: 102
        )
    }

    func testTrustedStructuredOutputFailureIsRepairedDespiteIncompatibleClassification() async throws {
        try await assertTrustedStructuredFailureIsRepaired(
            code: "model.local.structured-output-invalid",
            offset: 103
        )
    }

    func testNonRetryableModelFailureClassificationMapsToStableTerminalReason() async throws {
        let cases: [(AgentFailureClassification, ExternalEffectDisposition, AgentTerminalReason)] = [
            (.budgetRelated, .confirmedNone, .budgetExceeded),
            (.permissionRelated, .confirmedNone, .permissionDenied),
            (.incompatible, .confirmedNone, .modelUnavailable),
            (.permanent, .confirmedNone, .internalFailure),
            (.transient, .confirmedNone, .internalFailure),
        ]

        for (index, testCase) in cases.enumerated() {
            let offset = 110 + index
            let model = try ExecutorTestModelDefinition(offset: offset)
            let failure = try modelFailure(
                classification: testCase.0,
                effect: testCase.1
            )
            let provider = SequencedModelOutcomeProvider(
                model: model,
                outcomes: [.failed(failure)]
            )
            let harness = try ExecutorTestHarness(
                offset: offset,
                provider: provider,
                model: model
            )
            let handleID = try await harness.executor.submit(
                harness.request,
                commandID: ExecutorTestID.command(offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            let events = try await collectTerminalEvents(from: handle)

            let loadedResult = try await handle.result()
            let result = try XCTUnwrap(loadedResult)
            XCTAssertEqual(result.status.state, .failed, "classification: \(testCase.0)")
            XCTAssertEqual(
                result.status.terminalReason,
                testCase.2,
                "classification: \(testCase.0)"
            )
            XCTAssertEqual(result.status.failure, failure, "classification: \(testCase.0)")
            XCTAssertEqual(result.usage.quantities[.modelAttempts], 1)
            XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 1)
            let requests = await provider.script.capturedRequests()
            XCTAssertEqual(requests.count, 1, "non-retryable failure must execute once")
            let loadedFacts = try await harness.repository.loadRunFacts(for: harness.request.runID)
            let facts = try XCTUnwrap(loadedFacts)
            XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
            let arbiter = await harness.executor.controller.arbiter.snapshot()
            XCTAssertNil(arbiter.rootOwner)
            XCTAssertNil(arbiter.decodeOwner)
        }
    }

    func testCancelledProviderFailureWaitsForForegroundWithoutTerminalizing() async throws {
        let offset = 120
        let model = try ExecutorTestModelDefinition(offset: offset)
        let failure = try modelFailure(classification: .cancelled, effect: .confirmedNone)
        let provider = SequencedModelOutcomeProvider(
            model: model,
            outcomes: [.failed(failure)]
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let status = try await waitForStatus(.waitingForForeground, handle: handle)
        try await waitForWorkerToStop(harness.request.runID, controller: harness.executor.controller)

        XCTAssertEqual(status.blockingReason, .foreground)
        XCTAssertNil(status.terminalReason)
        let result = try await handle.result()
        XCTAssertNil(result)
        let events = try await harness.executor.controller.allEvents(runID: harness.request.runID)
        XCTAssertEqual(events.filter { $0.payload.event.isRunTerminal }.count, 0)
        XCTAssertEqual(events.filter { event in
            guard case .modelAttemptOutcome(.failed(let recorded)) = event.payload.event else {
                return false
            }
            return recorded == failure
        }.count, 1)
        let requests = await provider.script.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        let loadedFacts = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let facts = try XCTUnwrap(loadedFacts)
        XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
        let arbiter = await harness.executor.controller.arbiter.snapshot()
        XCTAssertNil(arbiter.rootOwner)
        XCTAssertNil(arbiter.decodeOwner)
    }

    func testWaitingForForegroundReopensReadOnlyAndRetriesOnlyAfterExplicitResume() async throws {
        let offset = 121
        let model = try ExecutorTestModelDefinition(offset: offset)
        let interruption = try modelFailure(
            classification: .cancelled,
            effect: .confirmedNone
        )
        let completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "Foreground recovery completed")),
            usage: modelUsage(input: 7, output: 4, milliseconds: 3, memory: 32)
        )
        let provider = SequencedModelOutcomeProvider(
            model: model,
            outcomes: [.failed(interruption), .completed(completion)]
        )
        let claimProbe = ExecutorBoundaryClaimProbe()
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, claimProbe: claimProbe)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(4_000 + offset)
        )
        let original = try await harness.executor.attach(to: handleID)
        _ = try await waitForStatus(.waitingForForeground, handle: original)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let requestsBeforeReopen = await provider.script.capturedRequests()
        XCTAssertEqual(requestsBeforeReopen.count, 1)
        await harness.repository.close()

        let reopenedBacking = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let reopenedRepository = ExecutorPostCommitGatedRepository(
            underlying: reopenedBacking,
            claimProbe: claimProbe
        )
        let restartedResidency = ScriptedModelResidencyDriver()
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopenedRepository,
            provider: provider,
            residencyDriver: restartedResidency
        )
        let reattached = try await restarted.attach(to: handleID)
        let waiting = try await reattached.status()
        XCTAssertEqual(waiting.state, .waitingForForeground)
        XCTAssertEqual(waiting.blockingReason, .foreground)
        try await Task.sleep(nanoseconds: 20_000_000)
        let requestsAfterAttach = await provider.script.capturedRequests()
        let residencyAfterAttach = await restartedResidency.snapshot()
        XCTAssertEqual(requestsAfterAttach.count, 1)
        XCTAssertTrue(residencyAfterAttach.calls.isEmpty)

        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(5_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await reattached.send(resume)
        XCTAssertEqual(receipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Foreground recovery completed")
        let finalRequests = await provider.script.capturedRequests()
        XCTAssertEqual(finalRequests.count, 2)
        let claims = await claimProbe.snapshot()
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims.map(\.attempt.attemptNumber), [1, 1])
        let finalFactsValue = try await reopenedBacking.loadRunFacts(for: harness.request.runID)
        let finalFacts = try XCTUnwrap(finalFactsValue)
        XCTAssertTrue(finalFacts.budgetLedger?.reservations.isEmpty == true)
    }

    func testPostCommitCrashAtEveryCoreModelBoundaryReopensReadOnlyUntilExplicitResume() async throws {
        let states: [AgentRunState] = [
            .created,
            .preparing,
            .waitingForModel,
            .generating,
            .validatingAction,
        ]

        for (index, targetState) in states.enumerated() {
            let offset = 130 + index
            let model = try ExecutorTestModelDefinition(offset: offset)
            let counter = ScriptedInvocationCounter()
            let provider = try FixedCompletionModelProvider(
                model: model,
                answer: "Recovered from \(targetState.rawValue)",
                invocationCounter: counter
            )
            let gate = ExecutorPostCommitCrashGate(targetState: targetState)
            let harness = try ExecutorTestHarness(
                offset: offset,
                provider: provider,
                model: model,
                repositoryFactory: {
                    ExecutorPostCommitGatedRepository(underlying: $0, gate: gate)
                }
            )
            let submissionCommandID = ExecutorTestID.command(5_000 + offset)
            let handleID: AgentExecutionHandleID

            if targetState == .created {
                let submission = Task {
                    try await harness.executor.submit(
                        harness.request,
                        commandID: submissionCommandID
                    )
                }
                try await gate.waitUntilIntercepted()
                let factsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
                let facts = try XCTUnwrap(factsValue, "state \(targetState)")
                handleID = try XCTUnwrap(
                    facts.submission?.executionHandleID,
                    "state \(targetState)"
                )
                submission.cancel()
                _ = await submission.result
            } else {
                handleID = try await harness.executor.submit(
                    harness.request,
                    commandID: submissionCommandID
                )
                try await gate.waitUntilIntercepted()
                let worker = await harness.executor.controller.workers[harness.request.runID]
                worker?.cancel()
                try await waitForWorkerToStop(
                    harness.request.runID,
                    controller: harness.executor.controller
                )
            }

            let durableBeforeValue = try await harness.repository.loadRunFacts(
                for: harness.request.runID
            )
            let durableBefore = try XCTUnwrap(durableBeforeValue, "state \(targetState)")
            XCTAssertEqual(
                durableBefore.projection.state,
                targetState,
                "crash gate must stop after target commit"
            )
            let attemptsBeforeAttach = await counter.count()
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
            let attachedStatus = try await reattached.status()
            XCTAssertEqual(attachedStatus.state, targetState, "state \(targetState)")
            try await Task.sleep(nanoseconds: 20_000_000)
            let attemptsAfterAttach = await counter.count()
            XCTAssertEqual(
                attemptsAfterAttach,
                attemptsBeforeAttach,
                "attach must remain read-only at \(targetState)"
            )

            let resume = try AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(6_000 + offset),
                runID: harness.request.runID,
                expectedRunStateVersion: attachedStatus.stateVersion,
                action: .resume,
                issuedAt: AgentTimestamp(rawValue: 50_000)
            ))
            let resumeReceipt = try await reattached.send(resume)
            guard resumeReceipt.disposition == .accepted else {
                XCTFail(
                    "public resume was \(resumeReceipt.disposition) at \(targetState); "
                        + "failure=\(String(describing: resumeReceipt.failure))"
                )
                continue
            }
            let events = try await collectTerminalEvents(from: reattached)
            let result = try await reattached.result()
            let diagnostics = events.map { String(describing: $0.payload.event) }
                .joined(separator: "\n")
            XCTAssertEqual(result?.status.state, .completed, diagnostics)
            XCTAssertEqual(
                result?.answer?.text,
                "Recovered from \(targetState.rawValue)",
                diagnostics
            )
            let finalAttemptCount = await counter.count()
            XCTAssertEqual(finalAttemptCount, 1, "state \(targetState)")
            XCTAssertEqual(events.filter { event in
                if case .modelAttemptOutcome(.completed) = event.payload.event { return true }
                return false
            }.count, 1, "state \(targetState)")
            let finalFactsValue = try await reopenedRepository.loadRunFacts(
                for: harness.request.runID
            )
            let finalFacts = try XCTUnwrap(finalFactsValue, "state \(targetState)")
            XCTAssertTrue(
                finalFacts.budgetLedger?.reservations.isEmpty == true,
                "state \(targetState)"
            )
        }
    }

    func testPostIntentCrashReopensWithoutExecutingToolUntilExplicitResume() async throws {
        try await assertPostCommitToolCrashRecovery(
            targetState: .executingTools,
            targetOccurrence: 1,
            expectedExecutionsAtCrash: 0,
            offset: 140
        )
    }

    func testPostToolOutcomeCrashReopensWithoutReplayingToolAndResumesNextModelStep() async throws {
        try await assertPostCommitToolCrashRecovery(
            targetState: .waitingForModel,
            targetOccurrence: 2,
            expectedExecutionsAtCrash: 1,
            offset: 141
        )
    }

    func testPostToolOutcomeCrashInSynthesisReopensWithoutReplayingTool() async throws {
        let failure = try AgentFailure(
            code: "tool.synthetic-failure",
            classification: .permanent,
            safeMessage: "The deterministic local tool failed.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(
                classification: .internalMetadata,
                policyVersion: 1
            )
        )
        try await assertPostCommitToolCrashRecovery(
            targetState: .synthesizing,
            targetOccurrence: 1,
            expectedExecutionsAtCrash: 1,
            offset: 146,
            behavior: .failWithoutBoundary(failure)
        )
    }

    func testWaitingForApprovalReopensWithoutLoadingOrExecutingUntilDecision() async throws {
        let offset = 142
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "reopen-approval",
            effect: .networkRead,
            idempotency: .pureRead
        )
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Approved after reopen",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("approved read"),
            counter: toolCounter
        )
        let toolCatalog = try SingleExecutorTestToolCatalog(tool: tool)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: toolCatalog,
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(9_000 + offset)
        )
        let original = try await harness.executor.attach(to: handleID)
        _ = try await waitForStatus(.waitingForApproval, handle: original)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        await harness.repository.close()

        let reopenedRepository = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restartedResidency = ScriptedModelResidencyDriver()
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopenedRepository,
            provider: provider,
            tools: toolCatalog,
            residencyDriver: restartedResidency
        )
        let reattached = try await restarted.attach(to: handleID)
        let waiting = try await reattached.status()
        XCTAssertEqual(waiting.state, .waitingForApproval)
        guard case .approval(let approvalID) = waiting.blockingReason else {
            return XCTFail("expected durable approval blocker")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let countsAfterAttach = await toolCounter.snapshot()
        let residencyAfterAttach = await restartedResidency.snapshot()
        let requestsAfterAttach = await modelScript.capturedRequests()
        XCTAssertEqual(countsAfterAttach.executions, 0)
        XCTAssertTrue(residencyAfterAttach.calls.isEmpty)
        XCTAssertEqual(requestsAfterAttach.count, 1)

        let approval = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(10_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await reattached.send(approval)
        XCTAssertEqual(receipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Approved after reopen")
        let finalToolCounts = await toolCounter.snapshot()
        let finalRequests = await modelScript.capturedRequests()
        XCTAssertEqual(finalToolCounts.executions, 1)
        XCTAssertEqual(finalRequests.count, 2)
    }

    func testWaitingForUserReopensReadOnlyAndAcceptsSchemaBoundResponse() async throws {
        let offset = 143
        let model = try ExecutorTestModelDefinition(offset: offset)
        let interactionID = InteractionRequestID(rawValue: ExecutorTestID.uuid(77_143))
        let script = UserInputModelScript()
        let provider = try UserInputThenAnswerModelProvider(
            model: model,
            runID: ExecutorTestID.run(offset),
            interactionID: interactionID,
            answer: "Response survived reopen",
            script: script
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(9_000 + offset)
        )
        let original = try await harness.executor.attach(to: handleID)
        _ = try await waitForStatus(.waitingForUser, handle: original)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        await harness.repository.close()

        let reopenedRepository = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopenedRepository,
            provider: provider
        )
        let reattached = try await restarted.attach(to: handleID)
        let waiting = try await reattached.status()
        XCTAssertEqual(waiting.state, .waitingForUser)
        try await Task.sleep(nanoseconds: 20_000_000)
        let requestsAfterAttach = await script.capturedRequests()
        XCTAssertEqual(requestsAfterAttach.count, 1)

        let response = try UserInputResponse(
            requestID: interactionID,
            expectedRunStateVersion: waiting.stateVersion,
            value: .string("B")
        )
        let command = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(10_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .respond(response),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await reattached.send(command)
        XCTAssertEqual(receipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Response survived reopen")
        let finalRequests = await script.capturedRequests()
        XCTAssertEqual(finalRequests.count, 2)
    }

    func testWaitingForReconciliationReopensWithoutReplayingRiskyBoundary() async throws {
        let offset = 144
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "reopen-reconciliation",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Reconciled after reopen",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .throwAcrossBoundary,
            counter: toolCounter
        )
        let toolCatalog = try SingleExecutorTestToolCatalog(tool: tool)
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: toolCatalog,
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(9_000 + offset)
        )
        let original = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: original)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("expected approval before risky write")
        }
        _ = try await original.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(10_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        let originalWaiting = try await waitForStatus(.waitingForReconciliation, handle: original)
        guard case .reconciliation(let invocationID) = originalWaiting.blockingReason else {
            return XCTFail("expected durable reconciliation blocker")
        }
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let countsBeforeReopen = await toolCounter.snapshot()
        XCTAssertEqual(countsBeforeReopen.boundaries, 1)
        await harness.repository.close()

        let reopenedRepository = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopenedRepository,
            provider: provider,
            tools: toolCatalog
        )
        let reattached = try await restarted.attach(to: handleID)
        let waiting = try await reattached.status()
        XCTAssertEqual(waiting.state, .waitingForReconciliation)
        try await Task.sleep(nanoseconds: 20_000_000)
        let countsAfterAttach = await toolCounter.snapshot()
        XCTAssertEqual(countsAfterAttach.executions, 1)
        XCTAssertEqual(countsAfterAttach.boundaries, 1)
        let requestsAfterAttach = await modelScript.capturedRequests()
        XCTAssertEqual(requestsAfterAttach.count, 1)

        let reconcile = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(11_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .reconcile(invocationID: invocationID, decision: .failed),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await reattached.send(reconcile)
        XCTAssertEqual(receipt.disposition, .accepted)
        _ = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Reconciled after reopen")
        let finalCounts = await toolCounter.snapshot()
        XCTAssertEqual(finalCounts.executions, 1)
        XCTAssertEqual(finalCounts.boundaries, 1)
        let finalRequests = await modelScript.capturedRequests()
        guard finalRequests.count == 2 else {
            return XCTFail("expected original tool call and reopened synthesis pass")
        }
        let synthesis = finalRequests[1].messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(synthesis.contains("execution.reconciled-failed"))
        XCTAssertFalse(synthesis.contains("execution.reconciled-succeeded"))
    }

    func testPausedRunReopensReadOnlyAndContinuesOnlyAfterExplicitResume() async throws {
        let offset = 145
        let model = try ExecutorTestModelDefinition(offset: offset)
        let script = PauseThenAnswerModelScript()
        let provider = try PauseThenAnswerModelProvider(
            model: model,
            answer: "Resumed after reopen",
            script: script
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(9_000 + offset)
        )
        let original = try await harness.executor.attach(to: handleID)
        try await waitForExecutorCondition { await script.hasStartedFirstAttempt() }
        let generating = try await original.status()
        let pause = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(10_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: generating.stateVersion,
            action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        _ = try await original.send(pause)
        _ = try await waitForStatus(.paused, handle: original)
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        await harness.repository.close()

        let reopenedRepository = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let restartedResidency = ScriptedModelResidencyDriver()
        let restarted = try makeReopenedExecutor(
            harness: harness,
            repository: reopenedRepository,
            provider: provider,
            residencyDriver: restartedResidency
        )
        let reattached = try await restarted.attach(to: handleID)
        let paused = try await reattached.status()
        XCTAssertEqual(paused.state, .paused)
        try await Task.sleep(nanoseconds: 20_000_000)
        let requestsAfterAttach = await script.capturedRequests()
        let residencyAfterAttach = await restartedResidency.snapshot()
        XCTAssertEqual(requestsAfterAttach.count, 1)
        XCTAssertTrue(residencyAfterAttach.calls.isEmpty)

        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(11_000 + offset),
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
        XCTAssertEqual(result?.answer?.text, "Resumed after reopen")
        let finalRequests = await script.capturedRequests()
        XCTAssertEqual(finalRequests.count, 2)
    }

    private func assertPostCommitToolCrashRecovery(
        targetState: AgentRunState,
        targetOccurrence: Int,
        expectedExecutionsAtCrash: Int,
        offset: Int,
        behavior: ExecutorTestToolBehavior = .complete("durable local result"),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(name: "recovery-local-\(offset)")
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Recovered tool chain \(offset)",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: behavior,
            counter: toolCounter
        )
        let toolCatalog = try SingleExecutorTestToolCatalog(tool: tool)
        let gate = ExecutorPostCommitCrashGate(
            targetState: targetState,
            targetOccurrence: targetOccurrence
        )
        let claimProbe = ExecutorBoundaryClaimProbe()
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: toolCatalog,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(
                    underlying: $0,
                    gate: gate,
                    claimProbe: claimProbe
                )
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(7_000 + offset)
        )
        try await gate.waitUntilIntercepted()
        let worker = await harness.executor.controller.workers[harness.request.runID]
        worker?.cancel()
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller
        )
        let crashFactsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let crashFacts = try XCTUnwrap(crashFactsValue, file: file, line: line)
        XCTAssertEqual(crashFacts.projection.state, targetState, file: file, line: line)
        let crashCounts = await toolCounter.snapshot()
        XCTAssertEqual(
            crashCounts.executions,
            expectedExecutionsAtCrash,
            file: file,
            line: line
        )
        await harness.repository.close()

        let reopenedBacking = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let reopenedRepository = ExecutorPostCommitGatedRepository(
            underlying: reopenedBacking,
            claimProbe: claimProbe
        )
        let restarted = DurableAgentExecutor(
            repository: reopenedRepository,
            payloadStore: harness.payloadStore,
            inputFreezer: StaticAgentRunInputFreezer(inputs: harness.frozenInputs),
            modelProviders: try StaticAgentModelProviderCatalog(providers: [provider]),
            tools: toolCatalog,
            policyEngine: try DefaultApprovalPolicyEngine(
                policyVersion: 1,
                sanitizationValidator: harness.attestor
            ),
            sanitizer: harness.attestor,
            residencyDriver: ScriptedModelResidencyDriver(),
            clock: FixedExecutorClock()
        )
        let reattached = try await restarted.attach(to: handleID)
        let attachedStatus = try await reattached.status()
        XCTAssertEqual(attachedStatus.state, targetState, file: file, line: line)
        try await Task.sleep(nanoseconds: 20_000_000)
        let afterAttachCounts = await toolCounter.snapshot()
        XCTAssertEqual(
            afterAttachCounts.executions,
            expectedExecutionsAtCrash,
            "attach must never execute or replay a tool",
            file: file,
            line: line
        )

        let resume = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(8_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: attachedStatus.stateVersion,
            action: .resume,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let receipt = try await reattached.send(resume)
        XCTAssertEqual(receipt.disposition, .accepted, file: file, line: line)
        let events = try await collectTerminalEvents(from: reattached)
        let result = try await reattached.result()
        let diagnostics = events.map { String(describing: $0.payload.event) }.joined(separator: "\n")
        XCTAssertEqual(result?.status.state, .completed, diagnostics, file: file, line: line)
        XCTAssertEqual(
            result?.answer?.text,
            "Recovered tool chain \(offset)",
            diagnostics,
            file: file,
            line: line
        )
        let finalToolCounts = await toolCounter.snapshot()
        XCTAssertEqual(finalToolCounts.executions, 1, file: file, line: line)
        XCTAssertEqual(finalToolCounts.boundaries, 0, file: file, line: line)
        let requests = await modelScript.capturedRequests()
        XCTAssertEqual(requests.count, 2, file: file, line: line)
        let claims = await claimProbe.snapshot()
        XCTAssertEqual(claims.count, 2, file: file, line: line)
        XCTAssertEqual(claims.map(\.attempt.attemptNumber), [1, 1], file: file, line: line)
        let durableTools = try await reopenedBacking.loadToolInvocations(for: harness.request.runID)
        XCTAssertEqual(durableTools.count, 1, file: file, line: line)
        XCTAssertEqual(durableTools.first?.state, .completed, file: file, line: line)
    }

    private func assertTrustedStructuredFailureIsRepaired(
        code: String,
        offset: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let failure = try AgentFailure(
            code: code,
            classification: .incompatible,
            safeMessage: "The local model returned an invalid structured action.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(
                classification: .internalMetadata,
                policyVersion: 1
            )
        )
        let completion = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "Recovered from \(code)")),
            usage: modelUsage(input: 8, output: 3, milliseconds: 4, memory: 48)
        )
        let provider = SequencedModelOutcomeProvider(
            model: model,
            outcomes: [.failed(failure), .completed(completion)]
        )
        let harness = try ExecutorTestHarness(
            offset: offset,
            provider: provider,
            model: model
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)

        let requests = await provider.script.capturedRequests()
        let loadedResult = try await handle.result()
        guard requests.count == 2 else {
            let diagnostics = events.map { String(describing: $0.payload.event) }.joined(separator: " | ")
            let logEntries = await harness.logger.snapshot()
            let logs = logEntries.map { "\($0.code):\($0.metadata)" }.joined(separator: " | ")
            let residency = await harness.residencyDriver.snapshot()
            let facts = try await harness.repository.loadRunFacts(for: harness.request.runID)
            let inputArtifact = if let id = facts?.submission?.inputSnapshot.artifactID {
                await harness.payloadStore.reference(for: id)
            } else {
                Optional<ArtifactReference>.none
            }
            let manifestReference = events.compactMap { event -> AgentStableBoundaryReference? in
                guard case .compiledManifestCommitted(_, let reference) = event.payload.event else {
                    return nil
                }
                return reference
            }.last
            let manifestArtifact = if let id = manifestReference?.artifactID {
                await harness.payloadStore.reference(for: id)
            } else {
                Optional<ArtifactReference>.none
            }
            XCTFail(
                "expected one constrained repair attempt, got \(requests.count); "
                    + "status=\(String(describing: loadedResult?.status)); "
                    + "logs=\(logs); residency=\(residency.calls); "
                    + "submission=\(String(describing: facts?.submission)); "
                    + "inputArtifact=\(String(describing: inputArtifact)); "
                    + "manifestArtifact=\(String(describing: manifestArtifact)); "
                    + "events=\(diagnostics)",
                file: file,
                line: line
            )
            return
        }
        XCTAssertEqual(requests[1].generationParameters.thinkingMode, .disabled, file: file, line: line)
        XCTAssertEqual(requests[1].generationParameters.temperature, 0, file: file, line: line)
        let result = try XCTUnwrap(loadedResult, file: file, line: line)
        XCTAssertEqual(result.status.state, .completed, file: file, line: line)
        XCTAssertEqual(result.answer?.text, "Recovered from \(code)", file: file, line: line)
        XCTAssertEqual(result.usage.quantities[.modelAttempts], 2, file: file, line: line)
        XCTAssertEqual(result.usage.quantities[.structuredRepairs], 1, file: file, line: line)
        XCTAssertEqual(events.compactMap { event -> String? in
            guard case .diagnostic(let recorded) = event.payload.event else { return nil }
            return recorded.code
        }.filter { $0 == "execution.structured-repair" }.count, 1, file: file, line: line)
    }
}

private actor AlwaysMalformedModelScript {
    private var attempts = 0
    func begin() -> Int {
        attempts += 1
        return attempts
    }
    func count() -> Int { attempts }
}

private struct AlwaysMalformedModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let emitted: AgentModelCompletion
    let returned: AgentModelCompletion
    let script: AlwaysMalformedModelScript

    init(model: ExecutorTestModelDefinition, script: AlwaysMalformedModelScript) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        emitted = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "Malformed emitted answer")),
            usage: modelUsage(input: 2, output: 1, milliseconds: 1, memory: 16)
        )
        returned = try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: "Conflicting returned answer")),
            usage: modelUsage(input: 2, output: 1, milliseconds: 1, memory: 16)
        )
        self.script = script
    }

    func capabilities(for _: AgentModelSelection) async throws -> AgentModelCapabilities {
        capabilitiesValue
    }

    func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        try LocalAgentModelPreparation.prepare(request: request, context: context, provider: descriptor)
    }

    func generate(
        _: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        _ = await script.begin()
        try await emitter.emit(.completed(emitted), responseBytes: 8)
        return AgentModelBoundaryCompletion(outcome: .completed(returned))
    }
}
