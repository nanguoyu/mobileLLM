// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-RECONCILE-001
// TEST-ID: AHT-SECURITY-002
// TEST-ID: AHT-TEST-002
final class AgentExecutorToolIntegrationTests: XCTestCase {
    func testRetryablePureReadUsesBoundedDelayAndFreshAuthorizedAttempt() async throws {
        let model = try ExecutorTestModelDefinition(offset: 299)
        let retry = try ExternalRetryPolicy(
            kind: .boundedExponential,
            maximumAttempts: 2,
            baseDelayMilliseconds: 10,
            maximumDelayMilliseconds: 50,
            allowsJitter: false
        )
        let definition = try ExecutorTestToolDefinition(
            name: "retry-lookup",
            retryPolicy: retry
        )
        let call = try definition.call(offset: 299)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Answer after retry",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .throwOnceThenComplete("retried value"),
            counter: toolCounter
        )
        let clock = RecordingExecutorClock()
        let harness = try ExecutorTestHarness(
            offset: 299,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            clock: clock
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(299)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)

        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Answer after retry")
        let counts = await toolCounter.snapshot()
        XCTAssertEqual(counts.preparations, 1)
        XCTAssertEqual(counts.executions, 2)
        XCTAssertEqual(counts.boundaries, 0, "localPure work must not enter a protected boundary")
        let delays = await clock.recordedDelays()
        XCTAssertEqual(delays, [10])
        let attemptNumbers = events.compactMap { event -> Int? in
            guard case .diagnostic(let failure) = event.payload.event else { return nil }
            guard failure.code == "execution.tool-attempt-started",
                  failure.details["invocationID"] == call.invocationID.description,
                  let rawAttempt = failure.details["attemptNumber"]
            else { return nil }
            return Int(rawAttempt)
        }
        XCTAssertEqual(attemptNumbers, [1, 2])
        XCTAssertEqual(events.filter { event in
            if case .toolIntentRecorded = event.payload.event { return true }
            return false
        }.count, 1)
        XCTAssertEqual(events.filter { event in
            if case .toolOutcomeRecorded = event.payload.event { return true }
            return false
        }.count, 1)
        let factsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let facts = try XCTUnwrap(factsValue)
        XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
    }

    func testLocalPureToolRunsAfterDurableIntentThenFeedsOneFollowupModelPass() async throws {
        let model = try ExecutorTestModelDefinition(offset: 300)
        let definition = try ExecutorTestToolDefinition(name: "local-lookup")
        let call = try definition.call(offset: 300)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Answer with tool result",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("local value"),
            counter: toolCounter
        )
        let claimProbe = ExecutorBoundaryClaimProbe()
        let harness = try ExecutorTestHarness(
            offset: 300,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            repositoryFactory: {
                ExecutorPostCommitGatedRepository(underlying: $0, claimProbe: claimProbe)
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(300)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)

        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "Answer with tool result")
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.usage.quantities[.modelAttempts], 2)
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 1)
        let modelRequests = await modelScript.capturedRequests()
        guard modelRequests.count == 2 else {
            return XCTFail("expected tool action plus follow-up model pass, got \(modelRequests.count)")
        }
        XCTAssertEqual(modelRequests[0].advertisedTools, [definition.descriptor])
        XCTAssertEqual(modelRequests[1].advertisedTools, [definition.descriptor])
        XCTAssertTrue(modelRequests[1].messages.contains { message in
            message.role == .tool && message.isUntrustedData
        })
        let toolCounts = await toolCounter.snapshot()
        XCTAssertEqual(toolCounts.preparations, 1)
        XCTAssertEqual(toolCounts.executions, 1)
        XCTAssertEqual(toolCounts.boundaries, 0)
        XCTAssertEqual(result?.usage.quantities[.networkRequestBytes], 0)
        XCTAssertEqual(result?.usage.quantities[.networkResponseBytesPerOperation], 0)
        XCTAssertEqual(result?.usage.quantities[.networkResponseBytesTotal], 0)
        let claims = await claimProbe.snapshot()
        XCTAssertEqual(claims.count, 2, "only the two model steps claim local generation boundaries")
        XCTAssertEqual(claims.map(\.attempt.attemptNumber), [1, 1])

        let intentIndex = try XCTUnwrap(events.firstIndex { event in
            if case .toolIntentRecorded = event.payload.event { return true }
            return false
        })
        let outcomeIndex = try XCTUnwrap(events.firstIndex { event in
            if case .toolOutcomeRecorded = event.payload.event { return true }
            return false
        })
        XCTAssertLessThan(intentIndex, outcomeIndex)
        let factsValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let facts = try XCTUnwrap(factsValue)
        XCTAssertTrue(facts.budgetLedger?.reservations.isEmpty == true)
    }

    func testNetworkByteAccountingUsesDestinationAndEffectSemanticsWithoutSkippingBoundaries() async throws {
        let cases: [(
            destination: ExternalDestination.Kind,
            effect: AgentEffect,
            idempotency: ExternalIdempotency,
            requiresApproval: Bool,
            chargesNetwork: Bool
        )] = [
            (.networkEndpoint, .networkRead, .pureRead, true, true),
            (.mcpServer, .unknownExternal, .nonIdempotent, true, true),
            (.modelProvider, .externalWrite, .nonIdempotent, true, true),
            (.modelProvider, .externalCommunication, .nonIdempotent, true, true),
            (.privateDataStore, .privateDataRead, .pureRead, true, false),
            (.fileReference, .localRead, .pureRead, false, false),
            (.artifactExport, .localWrite, .nonIdempotent, false, false),
        ]

        for (index, testCase) in cases.enumerated() {
            let offset = 330 + index
            let model = try ExecutorTestModelDefinition(offset: offset)
            let definition = try ExecutorTestToolDefinition(
                name: "accounting-\(offset)",
                effect: testCase.effect,
                idempotency: testCase.idempotency,
                destinationKind: testCase.destination
            )
            let call = try definition.call(offset: offset)
            let provider = try ToolSequenceModelProvider(
                model: model,
                call: call,
                answer: "accounted \(offset)"
            )
            let counter = ExecutorTestToolCounter()
            let tool = ExecutorTestTool(
                definition: definition,
                behavior: .complete("accounted tool result"),
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
                commandID: ExecutorTestID.command(700 + offset)
            )
            let handle = try await harness.executor.attach(to: handleID)
            if testCase.requiresApproval {
                let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
                guard case .approval(let approvalID) = waiting.blockingReason else {
                    return XCTFail("expected approval for \(testCase)")
                }
                let receipt = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
                    commandID: ExecutorTestID.command(800 + offset),
                    runID: harness.request.runID,
                    expectedRunStateVersion: waiting.stateVersion,
                    action: .decideApproval(
                        approvalID: approvalID,
                        decision: .approved,
                        approvedScope: .exactInvocation
                    ),
                    issuedAt: AgentTimestamp(rawValue: 50_000)
                )))
                XCTAssertEqual(receipt.disposition, .accepted, "case \(testCase)")
            }

            _ = try await collectTerminalEvents(from: handle)
            let result = try await handle.result()
            XCTAssertEqual(result?.status.state, .completed, "case \(testCase)")
            let counts = await counter.snapshot()
            XCTAssertEqual(counts.boundaries, 1, "case \(testCase)")
            if testCase.chargesNetwork {
                XCTAssertGreaterThan(
                    result?.usage.quantities[.networkRequestBytes] ?? 0,
                    0,
                    "case \(testCase)"
                )
                XCTAssertGreaterThan(
                    result?.usage.quantities[.networkResponseBytesPerOperation] ?? 0,
                    0,
                    "case \(testCase)"
                )
                XCTAssertGreaterThan(
                    result?.usage.quantities[.networkResponseBytesTotal] ?? 0,
                    0,
                    "case \(testCase)"
                )
            } else {
                XCTAssertEqual(result?.usage.quantities[.networkRequestBytes], 0, "case \(testCase)")
                XCTAssertEqual(
                    result?.usage.quantities[.networkResponseBytesPerOperation],
                    0,
                    "case \(testCase)"
                )
                XCTAssertEqual(
                    result?.usage.quantities[.networkResponseBytesTotal],
                    0,
                    "case \(testCase)"
                )
            }
        }
    }

    func testFailedToolSynthesisIncludesSafeFailureButNeverRawDiagnostic() async throws {
        let offset = 305
        let rawDiagnostic = "RAW_SECRET_DIAGNOSTIC_7f889d"
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(name: "safe-failure-context")
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Handled the safe tool failure",
            script: modelScript
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .throwAcrossBoundaryWithDiagnostic(rawDiagnostic),
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
            commandID: ExecutorTestID.command(offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)

        let failure = try XCTUnwrap(events.compactMap { event -> AgentFailure? in
            guard case .toolOutcomeRecorded(let invocationID, .failed(let failure)) = event.payload.event,
                  invocationID == call.invocationID
            else { return nil }
            return failure
        }.last)
        let requests = await modelScript.capturedRequests()
        guard requests.count == 2 else {
            return XCTFail("expected failed-tool synthesis pass, got \(requests.count) model attempts")
        }
        let synthesisContext = requests[1].messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(synthesisContext.contains(failure.code))
        XCTAssertTrue(synthesisContext.contains(failure.safeMessage))
        XCTAssertFalse(synthesisContext.contains(rawDiagnostic))
        XCTAssertTrue(requests[1].advertisedTools.isEmpty)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "Handled the safe tool failure")
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 1)
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.boundaries, 1)
    }

    func testDeniedApprovalIsSynthesizedWithoutExecutingTool() async throws {
        try await assertRejectedApprovalSynthesis(
            decision: .denied,
            expectedCode: "execution.tool-approval-denied",
            expectedSafeMessage: "The user denied the requested tool operation.",
            offset: 306
        )
    }

    func testCancelledApprovalIsSynthesizedWithoutExecutingTool() async throws {
        try await assertRejectedApprovalSynthesis(
            decision: .cancelled,
            expectedCode: "execution.tool-approval-cancelled",
            expectedSafeMessage: "The user cancelled the requested tool operation.",
            offset: 307
        )
    }

    func testExternalCompletedWithoutProtectedBoundaryBecomesContractFailure() async throws {
        try await assertToolBoundaryContract(
            effect: .networkRead,
            behavior: .completeWithoutBoundary("invalid external completion"),
            offset: 309,
            requiresApproval: true,
            expectedOutcomeCompleted: false,
            expectedBoundaryCount: 0
        )
    }

    func testLocalWriteCompletedWithoutProtectedBoundaryBecomesContractFailure() async throws {
        try await assertToolBoundaryContract(
            effect: .localWrite,
            behavior: .completeWithoutBoundary("invalid local write completion"),
            offset: 310,
            requiresApproval: false,
            expectedOutcomeCompleted: false,
            expectedBoundaryCount: 0
        )
    }

    func testLocalPureToolCrossingProtectedBoundaryBecomesContractFailure() async throws {
        try await assertToolBoundaryContract(
            effect: .localPure,
            behavior: .completeCrossingBoundary("invalid local-pure completion"),
            offset: 311,
            requiresApproval: false,
            expectedOutcomeCompleted: false,
            expectedBoundaryCount: 1
        )
    }

    func testLocalWriteCompletesOnlyAfterProtectedBoundary() async throws {
        try await assertToolBoundaryContract(
            effect: .localWrite,
            behavior: .complete("valid local write"),
            offset: 312,
            requiresApproval: false,
            expectedOutcomeCompleted: true,
            expectedBoundaryCount: 1
        )
    }

    func testPrivateDataReadCompletesAfterApprovalAndProtectedBoundary() async throws {
        try await assertToolBoundaryContract(
            effect: .privateDataRead,
            behavior: .complete("valid private read"),
            offset: 313,
            requiresApproval: true,
            expectedOutcomeCompleted: true,
            expectedBoundaryCount: 1
        )
    }

    func testRiskyBoundaryThenProviderConfirmedNoEffectFailureStillRequiresReconciliation() async throws {
        let offset = 314
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "risky-returned-failure",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Reconciled provider failure",
            script: modelScript
        )
        let reported = try AgentFailure(
            code: "tool.provider-confirmed-none",
            classification: .permanent,
            safeMessage: "The provider reported that the write failed.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .failAfterBoundary(reported),
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
            commandID: ExecutorTestID.command(400)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approval = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approval.blockingReason else {
            return XCTFail("expected risky-write approval")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(401),
            runID: harness.request.runID,
            expectedRunStateVersion: approval.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        let reconciliation = try await waitForStatus(.waitingForReconciliation, handle: handle)
        guard case .reconciliation(let invocationID) = reconciliation.blockingReason else {
            return XCTFail("risky boundary must override provider's confirmed-none claim")
        }
        XCTAssertEqual(invocationID, call.invocationID)
        let eventsBeforeResolution = try await harness.executor.controller.allEvents(
            runID: harness.request.runID
        )
        XCTAssertTrue(eventsBeforeResolution.contains { event in
            guard case .toolOutcomeRecorded(let id, .uncertain(let failure)) = event.payload.event
            else { return false }
            return id == call.invocationID
                && failure.code == "execution.tool-returned-failure-uncertain"
                && failure.externalEffect == .uncertain
        })
        XCTAssertFalse(eventsBeforeResolution.contains { $0.payload.event.isRunTerminal })
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.executions, 1)
        XCTAssertEqual(counts.boundaries, 1)
        let result = try await handle.result()
        XCTAssertNil(result)
    }

    func testRepeatedNormalizedToolCallTerminatesNoProgressWithoutSecondExecution() async throws {
        let model = try ExecutorTestModelDefinition(offset: 301)
        let definition = try ExecutorTestToolDefinition(name: "repeat-lookup")
        let call = try definition.call(offset: 301, query: "same")
        let modelScript = ToolSequenceModelScript(mode: .repeatTool)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Never reached",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("same value"),
            counter: toolCounter
        )
        let harness = try ExecutorTestHarness(
            offset: 301,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(301)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)

        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .failed)
        XCTAssertEqual(result?.status.terminalReason, .noProgress)
        XCTAssertEqual(result?.status.failure?.code, "execution.repeated-tool-call")
        // One duplicate is suppressed with a repair instruction; the second repetition is the failure.
        XCTAssertEqual(result?.usage.quantities[.modelAttempts], 3)
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 1)
        let toolCounts = await toolCounter.snapshot()
        XCTAssertEqual(toolCounts.executions, 1)
        XCTAssertEqual(toolCounts.boundaries, 0)
        XCTAssertEqual(events.filter { event in
            if case .toolOutcomeRecorded = event.payload.event { return true }
            return false
        }.count, 1)
    }

    func testRepeatedToolCallIsRepairedOnceThenModelAnswers() async throws {
        let model = try ExecutorTestModelDefinition(offset: 302)
        let definition = try ExecutorTestToolDefinition(name: "repeat-once-lookup")
        let call = try definition.call(offset: 302, query: "same")
        let modelScript = ToolSequenceModelScript(mode: .repeatOnceThenAnswer)
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Here is the answer.",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("same value"),
            counter: toolCounter
        )
        let harness = try ExecutorTestHarness(
            offset: 302,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(302)
        )
        let handle = try await harness.executor.attach(to: handleID)
        _ = try await collectTerminalEvents(from: handle)

        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Here is the answer.")
        XCTAssertEqual(result?.usage.quantities[.modelAttempts], 3)
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 1)
        let toolCounts = await toolCounter.snapshot()
        XCTAssertEqual(toolCounts.executions, 1)
        XCTAssertEqual(toolCounts.boundaries, 0)
    }

    func testToolFailureThenAnswerCompletesWithFailuresNotCleanSuccess() async throws {
        let model = try ExecutorTestModelDefinition(offset: 303)
        let definition = try ExecutorTestToolDefinition(name: "flaky-lookup")
        let call = try definition.call(offset: 303, query: "same")
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Here is the answer.",
            script: ToolSequenceModelScript(mode: .toolThenAnswer)
        )
        let reported = try AgentFailure(
            code: "tool.flaky",
            classification: .permanent,
            safeMessage: "The flaky tool failed.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .failWithoutBoundary(reported)
        )
        let harness = try ExecutorTestHarness(
            offset: 303,
            provider: provider,
            model: model,
            toolDescriptors: [definition.descriptor],
            tools: SingleExecutorTestToolCatalog(tool: tool),
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID]
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(303)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)

        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.status.terminalReason, .completedWithFailures)
        XCTAssertNil(result?.status.failure)
        XCTAssertEqual(result?.answer?.text, "Here is the answer.")
        XCTAssertTrue(events.contains { event in
            if case .toolOutcomeRecorded(_, .failed) = event.payload.event { return true }
            return false
        })
    }

    func testExternalReadWaitsForExactApprovalAndCannotCrossBoundaryBeforeDecision() async throws {
        let model = try ExecutorTestModelDefinition(offset: 302)
        let definition = try ExecutorTestToolDefinition(
            name: "network-lookup",
            effect: .networkRead
        )
        let call = try definition.call(offset: 302, query: "approved query")
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Approved network answer",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("network value"),
            counter: toolCounter
        )
        let harness = try ExecutorTestHarness(
            offset: 302,
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
            commandID: ExecutorTestID.command(302)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = waiting.blockingReason else {
            return XCTFail("Expected an approval blocking reason")
        }
        let beforeDecision = await toolCounter.snapshot()
        XCTAssertEqual(beforeDecision.preparations, 1)
        XCTAssertEqual(beforeDecision.boundaries, 0)
        let factsBeforeValue = try await harness.repository.loadRunFacts(for: harness.request.runID)
        let factsBefore = try XCTUnwrap(factsBeforeValue)
        XCTAssertTrue(factsBefore.budgetLedger?.reservations.isEmpty == true)

        let approval = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(303),
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
        XCTAssertEqual(receipt.currentStatus.state, .executingTools)
        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "Approved network answer")
        XCTAssertEqual(result?.status.state, .completed)
        let afterDecision = await toolCounter.snapshot()
        XCTAssertEqual(
            afterDecision.preparations,
            1,
            "approval resume must execute the durable prepared request without re-preparing"
        )
        XCTAssertEqual(afterDecision.boundaries, 1)
        XCTAssertEqual(events.filter { event in
            if case .approvalRequested = event.payload.event { return true }
            return false
        }.count, 1)
        XCTAssertEqual(events.filter { event in
            if case .approvalDecided = event.payload.event { return true }
            return false
        }.count, 1)
        XCTAssertEqual(result?.usage.quantities[.networkRequestBytes], UInt64(call.arguments.data.count))
        XCTAssertGreaterThan(result?.usage.quantities[.networkResponseBytesTotal] ?? 0, 0)
    }

    func testUncertainExternalWriteWaitsForReconciliationAndIsNeverSilentlyReplayed() async throws {
        let model = try ExecutorTestModelDefinition(offset: 303)
        let definition = try ExecutorTestToolDefinition(
            name: "external-write",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: 303, query: "write once")
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Reconciled without replay",
            script: modelScript
        )
        let toolCounter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .throwAcrossBoundary,
            counter: toolCounter
        )
        let harness = try ExecutorTestHarness(
            offset: 303,
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
            commandID: ExecutorTestID.command(304)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("Expected approval before external write")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(305),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        let reconcileWait = try await waitForStatus(.waitingForReconciliation, handle: handle)
        guard case .reconciliation(let invocationID) = reconcileWait.blockingReason else {
            return XCTFail("Expected reconciliation blocking reason")
        }
        XCTAssertEqual(invocationID, call.invocationID)
        let beforeReconciliation = await toolCounter.snapshot()
        XCTAssertEqual(beforeReconciliation.boundaries, 1)

        let reconcile = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(306),
            runID: harness.request.runID,
            expectedRunStateVersion: reconcileWait.stateVersion,
            action: .reconcile(invocationID: invocationID, decision: .failed),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let reconcileReceipt = try await handle.send(reconcile)
        XCTAssertEqual(reconcileReceipt.disposition, .accepted)
        XCTAssertEqual(reconcileReceipt.currentStatus.state, .synthesizing)
        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "Reconciled without replay")
        XCTAssertEqual(result?.status.state, .completed)
        let afterReconciliation = await toolCounter.snapshot()
        XCTAssertEqual(afterReconciliation.boundaries, 1, "uncertain write must never be replayed")
        XCTAssertTrue(events.contains { event in
            guard case .toolOutcomeRecorded(let id, .uncertain(let failure)) = event.payload.event
            else { return false }
            return id == invocationID && failure.externalEffect == .uncertain
        })
        XCTAssertTrue(events.contains { event in
            guard case .diagnostic(let failure) = event.payload.event else { return false }
            return failure.code == "execution.reconciled-failed"
        })
        let synthesisRequests = await modelScript.capturedRequests()
        guard synthesisRequests.count == 2 else {
            return XCTFail("expected a reconciliation synthesis pass")
        }
        let synthesisContext = synthesisRequests[1].messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(synthesisContext.contains("execution.reconciled-failed"))
        XCTAssertTrue(synthesisContext.contains("confirmed not to have succeeded"))
        XCTAssertFalse(synthesisContext.contains("execution.reconciled-succeeded"))
        XCTAssertFalse(synthesisContext.contains("confirmed successful"))
    }

    func testUncertainExternalWriteConfirmedSuccessIsSynthesizedWithoutReplay() async throws {
        let offset = 308
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "confirmed-external-write",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset, query: "write once")
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Reported reconciled success",
            script: modelScript
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
            commandID: ExecutorTestID.command(320)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("expected approval before external write")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(321),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        let reconcileWait = try await waitForStatus(.waitingForReconciliation, handle: handle)
        guard case .reconciliation(let invocationID) = reconcileWait.blockingReason else {
            return XCTFail("expected reconciliation after uncertain write")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(322),
            runID: harness.request.runID,
            expectedRunStateVersion: reconcileWait.stateVersion,
            action: .reconcile(invocationID: invocationID, decision: .succeeded),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        _ = try await collectTerminalEvents(from: handle)

        let requests = await modelScript.capturedRequests()
        guard requests.count == 2 else {
            return XCTFail("expected confirmed-success synthesis pass")
        }
        let synthesisContext = requests[1].messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(synthesisContext.contains("execution.reconciled-succeeded"))
        XCTAssertTrue(synthesisContext.contains("confirmed successful"))
        XCTAssertFalse(synthesisContext.contains("execution.reconciled-failed"))
        let result = try await handle.result()
        XCTAssertEqual(result?.answer?.text, "Reported reconciled success")
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 1)
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.boundaries, 1, "reconciliation must not replay the write")
    }

    func testTOCTOUAuthorizationRejectionStartsNoRiskyBoundaryAndProducesConfirmedNoEffect() async throws {
        let offset = 304
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "revoked-write",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset, query: "must not cross")
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Authorization expired safely",
            script: modelScript
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("must not appear"),
            counter: counter
        )
        let attestor = try executorTestAttestor(offset: offset)
        let policy = RejectExternalAtExecutionPolicyEngine(
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
            capabilityCeiling: definition.ceiling(),
            availableToolCapabilities: definition.descriptor.requiredCapabilities,
            explicitlyRequestedToolIDs: [definition.descriptor.id.logicalID],
            policyEngine: policy
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(307)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("Expected exact approval")
        }
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(308),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        let events = try await collectTerminalEvents(from: handle)

        let counts = await counter.snapshot()
        XCTAssertEqual(
            counts.preparations,
            1,
            "TOCTOU revalidation must use the durable prepared request without re-preparing"
        )
        XCTAssertEqual(counts.boundaries, 0, "adapter I/O must not start before gate revalidation")
        XCTAssertFalse(events.contains { event in
            if case .statusChanged(let status) = event.payload.event,
               status.state == .waitingForReconciliation
            {
                return true
            }
            return false
        })
        let failedOutcome = events.compactMap { event -> AgentFailure? in
            guard case .toolOutcomeRecorded(_, .failed(let failure)) = event.payload.event else {
                return nil
            }
            return failure
        }.last
        XCTAssertEqual(failedOutcome?.externalEffect, .confirmedNone)
        XCTAssertNotEqual(failedOutcome?.classification, .potentiallySideEffecting)
        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "Authorization expired safely")
    }

    private func assertRejectedApprovalSynthesis(
        decision: ApprovalDecision,
        expectedCode: String,
        expectedSafeMessage: String,
        offset: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "approval-rejection-\(offset)",
            effect: .networkRead
        )
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Continued without the rejected tool",
            script: modelScript
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .complete("must not execute"),
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
            commandID: ExecutorTestID.command(330 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = waiting.blockingReason else {
            return XCTFail("expected approval request", file: file, line: line)
        }
        let receipt = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(340 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: waiting.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: decision,
                approvedScope: nil
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        )))
        XCTAssertEqual(receipt.disposition, .accepted, file: file, line: line)
        XCTAssertEqual(receipt.currentStatus.state, .synthesizing, file: file, line: line)
        let events = try await collectTerminalEvents(from: handle)

        let requests = await modelScript.capturedRequests()
        guard requests.count == 2 else {
            return XCTFail("expected rejected-approval synthesis pass", file: file, line: line)
        }
        let synthesisContext = requests[1].messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(synthesisContext.contains(expectedCode), file: file, line: line)
        XCTAssertTrue(synthesisContext.contains(expectedSafeMessage), file: file, line: line)
        XCTAssertTrue(requests[1].advertisedTools.isEmpty, file: file, line: line)
        XCTAssertEqual(events.filter { event in
            if case .toolOutcomeRecorded = event.payload.event { return true }
            return false
        }.count, 0, file: file, line: line)
        let result = try await handle.result()
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 0, file: file, line: line)
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.boundaries, 0, file: file, line: line)
    }

    private func assertToolBoundaryContract(
        effect: AgentEffect,
        behavior: ExecutorTestToolBehavior,
        offset: Int,
        requiresApproval: Bool,
        expectedOutcomeCompleted: Bool,
        expectedBoundaryCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "boundary-contract-\(offset)",
            effect: effect,
            idempotency: effect == .localPure ? .pureRead : .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let modelScript = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "Synthesized boundary result",
            script: modelScript
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(definition: definition, behavior: behavior, counter: counter)
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
            commandID: ExecutorTestID.command(500 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        if requiresApproval {
            let waiting = try await waitForStatus(.waitingForApproval, handle: handle)
            guard case .approval(let approvalID) = waiting.blockingReason else {
                return XCTFail("expected exact approval", file: file, line: line)
            }
            _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
                commandID: ExecutorTestID.command(600 + offset),
                runID: harness.request.runID,
                expectedRunStateVersion: waiting.stateVersion,
                action: .decideApproval(
                    approvalID: approvalID,
                    decision: .approved,
                    approvedScope: .exactInvocation
                ),
                issuedAt: AgentTimestamp(rawValue: 50_000)
            )))
        }
        let events = try await collectTerminalEvents(from: handle)

        let outcome = try XCTUnwrap(events.compactMap { event -> AgentToolInvocationOutcome? in
            guard case .toolOutcomeRecorded(let id, let outcome) = event.payload.event,
                  id == call.invocationID
            else { return nil }
            return outcome
        }.last, file: file, line: line)
        if expectedOutcomeCompleted {
            guard case .completed = outcome else {
                return XCTFail("expected completed tool outcome, got \(outcome)", file: file, line: line)
            }
        } else {
            guard case .failed(let failure) = outcome else {
                return XCTFail("expected known contract failure, got \(outcome)", file: file, line: line)
            }
            XCTAssertEqual(failure.code, "execution.tool-contract-failed", file: file, line: line)
            XCTAssertEqual(failure.externalEffect, .confirmedNone, file: file, line: line)
        }
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.executions, 1, file: file, line: line)
        XCTAssertEqual(counts.boundaries, expectedBoundaryCount, file: file, line: line)
        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .completed, file: file, line: line)
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 1, file: file, line: line)
    }
}
