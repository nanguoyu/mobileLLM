// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class AgentExecutorBoundaryClaimRaceIntegrationTests: XCTestCase {
    func testPauseWhenBoundaryClaimWinsRequiresReconciliation() async throws {
        try await assertBoundaryClaimRace(commandIsCancel: false, winner: .claim, offset: 170)
    }

    func testCancelWhenBoundaryClaimWinsRequiresReconciliation() async throws {
        try await assertBoundaryClaimRace(commandIsCancel: true, winner: .claim, offset: 171)
    }

    func testPauseWhenLifecycleCASWinsRejectsClaimAndPerformsNoBoundaryIO() async throws {
        try await assertBoundaryClaimRace(commandIsCancel: false, winner: .lifecycle, offset: 172)
    }

    func testCancelWhenLifecycleCASWinsRejectsClaimAndPerformsNoBoundaryIO() async throws {
        try await assertBoundaryClaimRace(commandIsCancel: true, winner: .lifecycle, offset: 173)
    }

    private enum Winner: Equatable {
        case claim
        case lifecycle
    }

    private func assertBoundaryClaimRace(
        commandIsCancel: Bool,
        winner: Winner,
        offset: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let definition = try ExecutorTestToolDefinition(
            name: "boundary-race-\(commandIsCancel ? "cancel" : "pause")-\(offset)",
            effect: .externalWrite,
            idempotency: .nonIdempotent
        )
        let call = try definition.call(offset: offset)
        let script = ToolSequenceModelScript()
        let provider = try ToolSequenceModelProvider(
            model: model,
            call: call,
            answer: "must remain blocked",
            script: script
        )
        let counter = ExecutorTestToolCounter()
        let tool = ExecutorTestTool(
            definition: definition,
            behavior: .blockFirstAttemptInsideBoundaryThenComplete("must not complete"),
            counter: counter
        )
        let catalog = try SingleExecutorTestToolCatalog(tool: tool)
        let claimGate = winner == .claim ? ExecutorBoundaryClaimCrashGate() : nil
        let lifecycleGate = winner == .lifecycle ? ExecutorBeforeBoundaryClaimGate() : nil
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
                    boundaryClaimCrashGate: claimGate,
                    beforeBoundaryClaimGate: lifecycleGate
                )
            }
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(20_000 + offset)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let approvalWait = try await waitForStatus(.waitingForApproval, handle: handle)
        guard case .approval(let approvalID) = approvalWait.blockingReason else {
            return XCTFail("expected approval blocker", file: file, line: line)
        }
        let approval = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(21_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: approvalWait.stateVersion,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            ),
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let approvalReceipt = try await handle.send(approval)
        XCTAssertEqual(approvalReceipt.disposition, .accepted, file: file, line: line)
        switch winner {
        case .claim:
            try await claimGate!.waitUntilIntercepted()
        case .lifecycle:
            try await lifecycleGate!.waitUntilIntercepted()
        }
        let executing = try await handle.status()
        XCTAssertEqual(executing.state, .executingTools, file: file, line: line)
        let countsAtRace = await counter.snapshot()
        XCTAssertEqual(countsAtRace.executions, 1, file: file, line: line)
        XCTAssertEqual(countsAtRace.boundaries, 0, file: file, line: line)

        let action: AgentCommandAction = commandIsCancel
            ? .cancel
            : .pause(reason: .userRequested)
        let lifecycle = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(22_000 + offset),
            runID: harness.request.runID,
            expectedRunStateVersion: executing.stateVersion,
            action: action,
            issuedAt: AgentTimestamp(rawValue: 50_000)
        ))
        let lifecycleReceipt = try await handle.send(lifecycle)
        XCTAssertEqual(lifecycleReceipt.disposition, .accepted, file: file, line: line)
        XCTAssertEqual(lifecycleReceipt.currentStatus.state, .pausing, file: file, line: line)

        switch winner {
        case .claim:
            await claimGate!.releaseAfterDurableClaim()
        case .lifecycle:
            await lifecycleGate!.release()
        }
        try await waitForWorkerToStop(
            harness.request.runID,
            controller: harness.executor.controller,
            maximumPolls: 5_000
        )
        let finalStatus = try await handle.status()

        let invocations = try await harness.repository.loadToolInvocations(
            for: harness.request.runID
        )
        let invocation = try XCTUnwrap(invocations.first, file: file, line: line)
        let attempt = try ExternalOperationAttempt(prepared: invocation.request, attemptNumber: 1)
        let evidence = try await harness.repository.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: invocation.request,
            attempt: attempt
        )
        let finalCounts = await counter.snapshot()
        let events = try await harness.executor.controller.allEvents(runID: harness.request.runID)
        let requests = await script.capturedRequests()
        XCTAssertEqual(requests.count, 1, file: file, line: line)
        switch winner {
        case .claim:
            XCTAssertEqual(
                finalStatus.state,
                .waitingForReconciliation,
                "an exact durable claim must be conservatively reconciled",
                file: file,
                line: line
            )
            XCTAssertEqual(evidence, .exact, file: file, line: line)
            guard case .reconciliation(let invocationID) = finalStatus.blockingReason else {
                return XCTFail("claim-first race must expose reconciliation", file: file, line: line)
            }
            XCTAssertEqual(invocationID, call.invocationID, file: file, line: line)
            XCTAssertTrue(events.contains { event in
                guard case .diagnostic(let failure) = event.payload.event else { return false }
                return failure.externalEffect == .uncertain
            }, file: file, line: line)
            XCTAssertTrue(invocation.outcome.map { outcome in
                if case .uncertain = outcome { return true }
                return false
            } ?? false, file: file, line: line)
            XCTAssertLessThanOrEqual(finalCounts.boundaries, 1, file: file, line: line)
        case .lifecycle:
            XCTAssertEqual(
                finalStatus.state,
                commandIsCancel ? .cancelled : .paused,
                file: file,
                line: line
            )
            XCTAssertEqual(evidence, .none, file: file, line: line)
            XCTAssertEqual(finalCounts.boundaries, 0, file: file, line: line)
            XCTAssertFalse(events.contains { event in
                if case .statusChanged(let status) = event.payload.event {
                    return status.state == .waitingForReconciliation
                }
                if case .diagnostic(let failure) = event.payload.event {
                    return failure.externalEffect == .uncertain
                }
                return false
            }, file: file, line: line)
        }
    }
}
