// SPDX-License-Identifier: MIT
// TEST-ID: AHT-DYNAMIC-001

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class DynamicWorkflowAdversarialTests: XCTestCase {
    func testLaunchApprovalOnceAlwaysDigestAndScopeBinding() async throws {
        let fixture = try ADWorkflowFixture(body: "return 'ok';")
        let journal = InMemoryDynamicWorkflowJournal()
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: ADImmediateSpawner())

        let once = fixture.launch()
        let oncePreview = try await engine.prepareLaunch(script: fixture.saved, snapshot: once)
        XCTAssertTrue(oncePreview.requiresApproval)
        try await engine.approveLaunch(runID: once.runID, approvalID: ApprovalID())

        // A one-shot approval must not silently authorize a later run.
        let afterOnce = fixture.launch(conversationID: once.conversationID)
        let afterOncePreview = try await engine.prepareLaunch(script: fixture.saved, snapshot: afterOnce)
        XCTAssertTrue(afterOncePreview.requiresApproval)

        let reusableID = ApprovalID()
        try await engine.approveLaunch(
            runID: afterOnce.runID,
            approvalID: reusableID,
            reuseScope: .conversation
        )

        let sameAuthorization = fixture.launch(conversationID: once.conversationID)
        let reused = try await engine.prepareLaunch(script: fixture.saved, snapshot: sameAuthorization)
        XCTAssertFalse(reused.requiresApproval)
        XCTAssertEqual(reused.reusedApprovalID, reusableID)
        let reusedProjection = try await engine.projection(runID: sameAuthorization.runID)
        XCTAssertEqual(reusedProjection?.state, .queued)

        let otherConversation = fixture.launch()
        let otherConversationPreview = try await engine.prepareLaunch(
            script: fixture.saved,
            snapshot: otherConversation
        )
        XCTAssertTrue(otherConversationPreview.requiresApproval)

        let changedTools = fixture.launch(
            conversationID: once.conversationID,
            toolPolicyDigest: StableDigest.sha256(Data("changed-tools".utf8))
        )
        let changedToolsPreview = try await engine.prepareLaunch(
            script: fixture.saved,
            snapshot: changedTools
        )
        XCTAssertTrue(changedToolsPreview.requiresApproval)

        let changedPolicy = fixture.launch(
            conversationID: once.conversationID,
            policySnapshotDigest: StableDigest.sha256(Data("changed-policy".utf8))
        )
        let changedPolicyPreview = try await engine.prepareLaunch(
            script: fixture.saved,
            snapshot: changedPolicy
        )
        XCTAssertTrue(changedPolicyPreview.requiresApproval)

        let changedBudget = fixture.launch(
            conversationID: once.conversationID,
            budget: try AgentBudget.firstReleaseDefaults(
                contextTokensPerAttempt: 2_048,
                outputTokens: 512,
                peakMemoryBytes: 128 * 1_024 * 1_024
            )
        )
        let changedBudgetPreview = try await engine.prepareLaunch(
            script: fixture.saved,
            snapshot: changedBudget
        )
        XCTAssertTrue(changedBudgetPreview.requiresApproval)

        // A personal approval remains exact-digest bound, but is intentionally cross-conversation.
        let personal = fixture.launch()
        let personalApproval = try WorkflowLaunchApprovalV1(
            approvalID: ApprovalID(), launch: personal, reuseScope: .personal,
            createdAt: AgentTimestamp(rawValue: 99)
        )
        XCTAssertTrue(try personalApproval.authorizes(fixture.launch(
            conversationID: ConversationID(),
            toolPolicyDigest: personal.toolPolicyDigest,
            policySnapshotDigest: personal.policySnapshotDigest
        )))
        XCTAssertFalse(try personalApproval.authorizes(changedTools))
    }

    func testSQLiteReopenRetainsOnlyExactReusableApproval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-approval-adversarial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflows.sqlite3")
        let fixture = try ADWorkflowFixture(body: "return 'ok';")
        let launch = fixture.launch()
        let approval = try WorkflowLaunchApprovalV1(
            approvalID: ApprovalID(), launch: launch, reuseScope: .conversation,
            createdAt: AgentTimestamp(rawValue: 7)
        )

        let journal = SQLiteDynamicWorkflowJournal(databaseURL: url)
        try await journal.saveScript(fixture.saved)
        try await journal.saveLaunchApproval(approval)
        await journal.close()

        let reopened = SQLiteDynamicWorkflowJournal(databaseURL: url)
        let exact = try await reopened.reusableLaunchApproval(for: launch)
        let otherConversation = try await reopened.reusableLaunchApproval(for: fixture.launch())
        let otherPolicy = try await reopened.reusableLaunchApproval(for: fixture.launch(
            conversationID: launch.conversationID,
            policySnapshotDigest: StableDigest.sha256(Data("new-policy".utf8))
        ))
        XCTAssertEqual(exact, approval)
        XCTAssertNil(otherConversation)
        XCTAssertNil(otherPolicy)
    }

    func testSchedulerCancelledWaiterDoesNotLeakPermitAndPauseDrainsBeforeResume() async throws {
        let scheduler = WorkflowDispatchScheduler(maximumConcurrentAgents: 1)
        let gate = ADGate()
        let holder = Task {
            try await scheduler.run {
                await gate.wait()
                return 1
            }
        }
        let holderStarted = try await ADEventually { await scheduler.activeCount == 1 }
        XCTAssertTrue(holderStarted)

        let cancelledWaiter = Task { try await scheduler.run { 2 } }
        let waiterQueued = try await ADEventually { await scheduler.waitingCount == 1 }
        XCTAssertTrue(waiterQueued)
        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("cancelled waiter unexpectedly acquired a permit")
        } catch is CancellationError {
            // Expected.
        }
        let waiterRemoved = try await ADEventually { await scheduler.waitingCount == 0 }
        XCTAssertTrue(waiterRemoved)

        await scheduler.pause()
        let paused = Task { try await scheduler.waitUntilPaused() }
        let pausingState = await scheduler.state
        XCTAssertEqual(pausingState, .pausing)
        await gate.open()
        let holderValue = try await holder.value
        XCTAssertEqual(holderValue, 1)
        try await paused.value
        let pausedState = await scheduler.state
        let pausedActiveCount = await scheduler.activeCount
        XCTAssertEqual(pausedState, .paused)
        XCTAssertEqual(pausedActiveCount, 0)

        await scheduler.resume()
        let resumedState = await scheduler.state
        let resumedValue = try await scheduler.run { 3 }
        XCTAssertEqual(resumedState, .running)
        XCTAssertEqual(resumedValue, 3)
    }

    func testStopCancelsSubmittedChildAndCommitsTerminalCancellation() async throws {
        let fixture = try ADWorkflowFixture(body: "return await agent('held');")
        let journal = InMemoryDynamicWorkflowJournal()
        let spawner = ADControlledSpawner(mode: .held)
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = fixture.launch()
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        try await engine.start(runID: launch.runID)
        let childSubmitted = try await ADEventually { await spawner.collectCount == 1 }
        XCTAssertTrue(childSubmitted)

        try await engine.stop(runID: launch.runID)
        let terminal = try await ADEventually {
            try await engine.projection(runID: launch.runID)?.state == .cancelled
        }
        let cancelCount = await spawner.cancelCount
        let loadedProjection = try await engine.projection(runID: launch.runID)
        XCTAssertTrue(terminal)
        XCTAssertEqual(cancelCount, 1)
        let projection = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(projection.state, .cancelled)
        XCTAssertEqual(projection.calls.count, 1)
        XCTAssertEqual(projection.submittedHandles.count, 1)
    }

    func testEnginePauseDrainsInFlightChildThenResumeReplaysWithoutRespawn() async throws {
        let fixture = try ADWorkflowFixture(body: """
        await agent('pause-me');
        while (true) { /* cancellation checkpoint */ }
        """)
        let journal = InMemoryDynamicWorkflowJournal()
        let spawner = ADControlledSpawner(mode: .releasable)
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = fixture.launch()
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        try await engine.start(runID: launch.runID)
        let childCollecting = try await ADEventually { await spawner.collectCount == 1 }
        XCTAssertTrue(childCollecting)

        let pause = Task { try await engine.pause(runID: launch.runID) }
        let pauseRequested = try await ADEventually {
            try await engine.projection(runID: launch.runID)?.state == .pausing
        }
        XCTAssertTrue(pauseRequested)
        await spawner.releaseAll()
        try await pause.value

        let loadedPausedProjection = try await engine.projection(runID: launch.runID)
        let pausedProjection = try XCTUnwrap(loadedPausedProjection)
        XCTAssertEqual(pausedProjection.state, .paused)
        XCTAssertEqual(pausedProjection.calls.count, 1)
        XCTAssertEqual(pausedProjection.outcomes.count, 1)

        try await engine.resume(runID: launch.runID)
        let resumed = try await ADEventually {
            try await engine.projection(runID: launch.runID)?.state == .running
        }
        XCTAssertTrue(resumed)
        let spawnCountAfterResume = await spawner.spawnCount
        XCTAssertEqual(spawnCountAfterResume, 1)

        try await engine.stop(runID: launch.runID)
        let cancelled = try await ADEventually {
            try await engine.projection(runID: launch.runID)?.state == .cancelled
        }
        XCTAssertTrue(cancelled)
    }

    func testCancellationUsesCommittedResultWhenAcknowledgementIsLostAndKeepsUsage() async throws {
        let fixture = try ADWorkflowFixture(body: "return await agent('held');")
        let spawner = ADControlledSpawner(mode: .held, losesCancellationAcknowledgement: true)
        let engine = ADWorkflowFixture.engine(journal: InMemoryDynamicWorkflowJournal(), spawner: spawner)
        let launch = fixture.launch()
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        try await engine.start(runID: launch.runID)
        let started = try await ADEventually { await spawner.collectCount == 1 }
        XCTAssertTrue(started)
        try await engine.stop(runID: launch.runID)
        let stopped = try await ADEventually { try await engine.projection(runID: launch.runID)?.state == .cancelled }
        XCTAssertTrue(stopped)
        let loaded = try await engine.projection(runID: launch.runID)
        let projection = try XCTUnwrap(loaded)
        XCTAssertNil(projection.reconciliationCallID)
        XCTAssertEqual(projection.usage.quantities[.inputTokens], 14)
        let handle = try XCTUnwrap(projection.submittedHandles.values.first)
        let committed = try await spawner.terminalResult(handle)
        let terminal = try XCTUnwrap(committed)
        let encoded = try JSONEncoder().encode(terminal)
        XCTAssertEqual(try JSONDecoder().decode(SubagentResult.self, from: encoded).usage, terminal.usage)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "terminalUsage")
        XCTAssertEqual(try JSONDecoder().decode(SubagentResult.self, from: JSONSerialization.data(withJSONObject: legacy)).usage, .zero)
    }

    func testFailedParallelWorkflowWaitsForDelayedCancellationCommitWithoutRespawning() async throws {
        let fixture = try ADWorkflowFixture(
            body: "return await parallel([0,1,2,3,4].map(i => () => agent(`held-${i}`)));",
            maximumConcurrentAgents: 8)
        let spawner = ADControlledSpawner(mode: .held, losesCancellationAcknowledgement: true, delayedTerminalReads: 2)
        let engine = ADWorkflowFixture.engine(journal: InMemoryDynamicWorkflowJournal(), spawner: spawner)
        let launch = fixture.launch()
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        do {
            _ = try await engine.runAndWait(runID: launch.runID)
            XCTFail("The fifth child exceeds available reserved capacity")
        } catch { }
        let projection = try await engine.projection(runID: launch.runID)
        let spawned = await spawner.spawnCount
        let cancelled = await spawner.cancelCount
        XCTAssertEqual(spawned, 4)
        XCTAssertEqual(cancelled, 4)
        XCTAssertEqual(projection?.state, .failed)
        XCTAssertNil(projection?.reconciliationCallID)
        XCTAssertEqual(projection?.outcomes.count, 4)
        XCTAssertEqual(projection?.usage.quantities[.inputTokens], 56)
    }

    func testUncertainChildStopsForReconciliationWithoutSettlingOrRetrying() async throws {
        for body in [
            "return await agent('external-effect');",
            "try { await agent('external-effect'); } catch(e) {} return 'pretend success';",
            "try { await agent('external-effect'); } catch(e) {} return await agent('repeat-effect');"
        ] {
        let fixture = try ADWorkflowFixture(body: body)
        let journal = InMemoryDynamicWorkflowJournal()
        let spawner = ADControlledSpawner(mode: .uncertain)
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = fixture.launch()
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())

        do {
            _ = try await engine.runAndWait(runID: launch.runID)
            XCTFail("uncertain external result must stop for reconciliation")
        } catch {
            // The durable projection, not the provider-specific error text, is the contract.
        }
        let loadedProjection = try await engine.projection(runID: launch.runID)
        let projection = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(projection.state, .waitingForReconciliation)
        XCTAssertEqual(projection.calls.count, 1)
        XCTAssertTrue(projection.outcomes.isEmpty)
        XCTAssertNil(projection.failure)
        XCTAssertNil(projection.output)
        let spawnCount = await spawner.spawnCount
        let collectCount = await spawner.collectCount
        XCTAssertEqual(spawnCount, 1)
        XCTAssertEqual(collectCount, 1)
            }
    }

    func testManualReconciliationIsCallBoundDurableAndSettlesExactlyOnce() async throws {
        let fixture = try ADWorkflowFixture(body: "return await agent('manual-reconciliation');")
        let journal = InMemoryDynamicWorkflowJournal()
        let spawner = ADManualReconciliationSpawner()
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = fixture.launch()
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())

        do {
            _ = try await engine.runAndWait(runID: launch.runID)
            XCTFail("collect must suspend the workflow for an explicit reconciliation decision")
        } catch {
            // Durable state below is the contract; provider error wording is not.
        }
        let loadedWaiting = try await engine.projection(runID: launch.runID)
        let waiting = try XCTUnwrap(loadedWaiting)
        let call = try XCTUnwrap(waiting.calls.first)
        let handle = try XCTUnwrap(waiting.submittedHandles[call.callID])
        XCTAssertEqual(waiting.state, .waitingForReconciliation)
        XCTAssertEqual(waiting.reconciliationCallID, call.callID)
        XCTAssertTrue(waiting.outcomes.isEmpty)

        // Generic resume must never reinterpret an unresolved external effect as retryable work.
        await ADAssertThrows(
            DynamicWorkflowEngineError.illegalRunState(.waitingForReconciliation)
        ) {
            try await engine.resume(runID: launch.runID)
        }
        let afterRejectedResume = try await engine.projection(runID: launch.runID)
        XCTAssertEqual(afterRejectedResume?.state, .waitingForReconciliation)
        let collectCountBeforeDecision = await spawner.collectCount
        XCTAssertEqual(collectCountBeforeDecision, 1)

        let wrongCallID = WorkflowAgentCallID()
        await ADAssertThrows(
            DynamicWorkflowEngineError.illegalRunState(.waitingForReconciliation)
        ) {
            try await engine.reconcileAgent(
                runID: launch.runID,
                callID: wrongCallID,
                decision: .succeeded
            )
        }
        let reconcileCountAfterWrongCall = await spawner.reconcileCount
        XCTAssertEqual(reconcileCountAfterWrongCall, 0)

        try await engine.reconcileAgent(
            runID: launch.runID,
            callID: call.callID,
            decision: .succeeded
        )
        let queued = try await engine.projection(runID: launch.runID)
        XCTAssertEqual(queued?.state, .queued)
        XCTAssertNil(queued?.reconciliationCallID)
        let reconciliation = await spawner.reconciliationSnapshot()
        XCTAssertEqual(reconciliation?.handleID, handle)
        XCTAssertEqual(reconciliation?.runID, call.childRunID)
        XCTAssertEqual(reconciliation?.decision, .succeeded)

        await ADAssertThrows(DynamicWorkflowEngineError.illegalRunState(.queued)) {
            try await engine.reconcileAgent(
                runID: launch.runID,
                callID: call.callID,
                decision: .failed
            )
        }
        let reconcileCountAfterDuplicate = await spawner.reconcileCount
        XCTAssertEqual(reconcileCountAfterDuplicate, 1)

        let output = try await engine.runAndWait(runID: launch.runID)
        XCTAssertEqual(try ADDecode(output), .string("reconciled"))
        let loadedCompleted = try await engine.projection(runID: launch.runID)
        let completed = try XCTUnwrap(loadedCompleted)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.calls.count, 1)
        XCTAssertEqual(completed.outcomes.count, 1)
        XCTAssertNotNil(completed.outcomes[call.callID])
        let finalSpawnCount = await spawner.spawnCount
        let finalCollectCount = await spawner.collectCount
        let collectedHandles = await spawner.collectedHandles
        XCTAssertEqual(finalSpawnCount, 1)
        XCTAssertEqual(finalCollectCount, 2)
        XCTAssertEqual(collectedHandles, [handle, handle])

        let eventPage = try await engine.events(runID: launch.runID, limit: 256)
        let settlements = eventPage.events.filter {
            if case .agentCallSettled(let callID, _) = $0.kind { return callID == call.callID }
            return false
        }
        let decisions = eventPage.events.filter {
            if case .reconciliationDecided(let callID, _) = $0.kind { return callID == call.callID }
            return false
        }
        XCTAssertEqual(settlements.count, 1)
        XCTAssertEqual(decisions.count, 1)
    }

    func testReconciliationIntentClosesCommandAppliedBeforeWorkflowAppendCrashGap() async throws {
        let fixture = try ADWorkflowFixture(body: "return await agent('crash-gap');")
        let journal = ADFailReconciliationDecisionJournal()
        let spawner = ADIdempotentReconciliationSpawner()
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = fixture.launch()
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        await ADAssertThrowsAny {
            _ = try await engine.runAndWait(runID: launch.runID)
        }
        let waitingValue = try await engine.projection(runID: launch.runID)
        let waiting = try XCTUnwrap(waitingValue)
        let call = try XCTUnwrap(waiting.calls.first)

        // The child command succeeds, then the injected workflow append fails exactly once.
        await ADAssertThrowsAny {
            try await engine.reconcileAgent(
                runID: launch.runID,
                callID: call.callID,
                decision: .succeeded
            )
        }
        let afterCrashValue = try await engine.projection(runID: launch.runID)
        let afterCrash = try XCTUnwrap(afterCrashValue)
        XCTAssertEqual(afterCrash.state, .waitingForReconciliation)
        XCTAssertEqual(afterCrash.reconciliationCallID, call.callID)
        XCTAssertEqual(afterCrash.reconciliationDecision, .succeeded)
        let appliedBeforeRecovery = await spawner.appliedCommandCount
        XCTAssertEqual(appliedBeforeRecovery, 1)

        // A fresh engine recovers the intent, reuses the stable child command, and only backfills
        // the missing workflow receipt. It must not apply the external decision twice.
        let recovered = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        try await recovered.reconcileAgent(
            runID: launch.runID,
            callID: call.callID,
            decision: .succeeded
        )
        let queuedValue = try await recovered.projection(runID: launch.runID)
        let queued = try XCTUnwrap(queuedValue)
        XCTAssertEqual(queued.state, .queued)
        XCTAssertNil(queued.reconciliationCallID)
        XCTAssertNil(queued.reconciliationDecision)
        let appliedAfterRecovery = await spawner.appliedCommandCount
        let reconciliationCalls = await spawner.reconcileCallCount
        XCTAssertEqual(appliedAfterRecovery, 1)
        XCTAssertEqual(reconciliationCalls, 2)

        let page = try await recovered.events(runID: launch.runID, limit: 256)
        XCTAssertEqual(page.events.filter {
            if case .reconciliationRequested(let callID, .succeeded) = $0.kind {
                return callID == call.callID
            }
            return false
        }.count, 1)
        XCTAssertEqual(page.events.filter {
            if case .reconciliationDecided(let callID, .succeeded) = $0.kind {
                return callID == call.callID
            }
            return false
        }.count, 1)
    }

    func testOnlyExplicitAvailabilityFailureDegradesToNull() async throws {
        for classification in AgentFailureClassification.allCases
            where classification != .potentiallySideEffecting
        {
            let fixture = try ADWorkflowFixture(body: "return await agent('classification');")
            let journal = InMemoryDynamicWorkflowJournal()
            let failure = try ADFailure(classification)
            let engine = ADWorkflowFixture.engine(
                journal: journal,
                spawner: ADFailingSpawner(failure: failure)
            )
            let launch = fixture.launch()
            _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
            try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
            if classification == .availabilityRelated {
                let value = try await engine.runAndWait(runID: launch.runID)
                XCTAssertEqual(try ADDecode(value), .null)
                let projectionValue = try await engine.projection(runID: launch.runID)
                let projection = try XCTUnwrap(projectionValue)
                XCTAssertEqual(projection.state, .completed)
                guard case .unavailable = try XCTUnwrap(projection.outcomes.values.first) else {
                    return XCTFail("availability failure must be the only nullable outcome")
                }
            } else {
                await ADAssertThrowsAny {
                    _ = try await engine.runAndWait(runID: launch.runID)
                }
                let projectionValue = try await engine.projection(runID: launch.runID)
                let projection = try XCTUnwrap(projectionValue)
                XCTAssertEqual(projection.state, .failed, "classification: \(classification)")
                guard case .failed(let durable, _) = try XCTUnwrap(projection.outcomes.values.first)
                else { return XCTFail("structural failure must remain durable and typed") }
                XCTAssertEqual(durable, failure)
                XCTAssertEqual(projection.failure, failure.safeMessage)
            }
        }
    }

    func testCancelFailureRequiresReconciliationAndCannotPublishTerminalState() async throws {
        let fixture = try ADWorkflowFixture(body: "return await agent('cannot-cancel');")
        let journal = InMemoryDynamicWorkflowJournal()
        let spawner = ADCancelFailureSpawner()
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = fixture.launch()
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        try await engine.start(runID: launch.runID)
        let didBeginCollection = try await ADEventually { await spawner.collectCount == 1 }
        XCTAssertTrue(didBeginCollection)
        await ADAssertThrowsAny { try await engine.stop(runID: launch.runID) }
        let projectionValue = try await engine.projection(runID: launch.runID)
        let projection = try XCTUnwrap(projectionValue)
        XCTAssertEqual(projection.state, .waitingForReconciliation)
        XCTAssertNotNil(projection.reconciliationCallID)
        XCTAssertNil(projection.output)
        XCTAssertFalse(projection.isTerminal)
    }

    func testProjectionRejectsOutputOrTerminalStateWithUnsettledSubmittedChild() async throws {
        let fixture = try ADWorkflowFixture(body: "return null;")
        let launch = fixture.launch()
        let cursor = try WorkflowReplayCursor(launch: launch)
        guard case .execute(let call) = try await cursor.next(
            prompt: "unsettled",
            options: WorkflowAgentOptionsV1()
        ) else { return XCTFail("expected executable call") }
        var prefix = try ADStartedEvents(launch)
        try ADAppend(.agentCallPrepared(call), runID: launch.runID, events: &prefix)
        try ADAppend(
            .agentChildSubmitted(callID: call.callID, handleID: AgentExecutionHandleID()),
            runID: launch.runID,
            events: &prefix
        )
        for forbidden in [
            WorkflowRunEventKindV1.outputCommitted(.inline(try CanonicalJSON(.null))),
            .stateChanged(from: .running, to: .completed, reason: nil),
            .stateChanged(from: .running, to: .cancelled, reason: "test"),
        ] {
            var events = prefix
            try ADAppend(forbidden, runID: launch.runID, events: &events)
            XCTAssertThrowsError(try WorkflowRunProjectionV1.replay(events))
        }
    }

    func testRestartInvalidatesSelectedCallAndEveryLaterPrefixAttempt() async throws {
        let fixture = try ADWorkflowFixture(body: "return null;")
        let launch = fixture.launch()
        let initial = try WorkflowReplayCursor(launch: launch)
        let options = try WorkflowAgentOptionsV1()
        guard case .execute(let first) = try await initial.next(prompt: "first", options: options),
              case .execute(let second) = try await initial.next(prompt: "second", options: options),
              case .execute(let third) = try await initial.next(prompt: "third", options: options)
        else { return XCTFail("initial replay cursor must execute") }

        var events = try ADStartedEvents(launch)
        for call in [first, second, third] {
            try ADAppend(.agentCallPrepared(call), runID: launch.runID, events: &events)
            try ADAppend(.agentCallSettled(
                callID: call.callID,
                outcome: .completed(value: .inline(try CanonicalJSON(.string("done"))), usage: .zero)
            ), runID: launch.runID, events: &events)
        }
        try ADAppend(.agentRestartRequested(callID: second.callID), runID: launch.runID, events: &events)
        let projection = try XCTUnwrap(WorkflowRunProjectionV1.replay(events))
        let resumed = try WorkflowReplayCursor(launch: launch, priorProjection: projection)

        guard case .reuse(let reusedFirst, _) = try await resumed.next(prompt: "first", options: options)
        else { return XCTFail("prefix before restart must remain reusable") }
        XCTAssertEqual(reusedFirst.callID, first.callID)
        guard case .execute(let restarted) = try await resumed.next(prompt: "second", options: options)
        else { return XCTFail("selected call must restart") }
        XCTAssertEqual(restarted.ordinal, 2)
        XCTAssertEqual(restarted.attempt, 2)
        guard case .execute(let suffix) = try await resumed.next(prompt: "third", options: options)
        else { return XCTFail("suffix after restart must be invalidated") }
        XCTAssertEqual(suffix.ordinal, 3)
        XCTAssertEqual(suffix.attempt, 2)
    }

    func testNestedSavedWorkflowSharesGlobalSequencePinsVersionAndDoesNotDeadlockAtOnePermit() async throws {
        let root = try ADWorkflowFixture(
            name: "root",
            body: """
            return await parallel([
              () => workflow('child', { value: 'a' }),
              () => agent('root-agent'),
            ]);
            """,
            maximumConcurrentAgents: 1
        )
        let child = try ADWorkflowFixture(
            name: "child",
            body: "return await agent(`child-${args.value}`);",
            maximumConcurrentAgents: 1
        )
        let journal = InMemoryDynamicWorkflowJournal()
        try await journal.saveScript(child.saved)
        let spawner = ADImmediateSpawner()
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = root.launch()
        _ = try await engine.prepareLaunch(script: root.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())

        let output = try await engine.runAndWait(runID: launch.runID)
        XCTAssertEqual(try ADDecode(output), .array([.string("child-a"), .string("root-agent")]))
        let loadedProjection = try await engine.projection(runID: launch.runID)
        let projection = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(projection.state, .completed)
        XCTAssertEqual(projection.calls.map(\.ordinal), [1, 2])
        XCTAssertEqual(Set(projection.calls.map(\.attempt)), [1])
        XCTAssertEqual(projection.savedWorkflowPins["child"], child.saved.script.reference)
        let maximumActive = await spawner.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }

    func testUnawaitedAgentTaskIsCancelledAndDrainedBeforeRuntimeReturns() async throws {
        let script = try WorkflowScriptV1(
            scriptID: WorkflowScriptID(), version: 1,
            source: """
            export const meta = { name: 'orphan', description: 'Cancellation probe' };
            agent('orphan');
            return 'finished';
            """
        )
        let analyzed = try DynamicWorkflowScriptAnalyzer().analyze(script)
        let probe = ADHostCancellationProbe()
        let result = try await JavaScriptCoreWorkflowRuntime().execute(
            analyzed,
            args: nil,
            limits: try ADLimits(maximumConcurrentAgents: 1),
            requirement: .init(),
            host: WorkflowScriptHost(agent: { _ in try await probe.waitUntilCancelled() })
        )
        XCTAssertEqual(try ADDecode(result), .string("finished"))
        let state = await probe.snapshot()
        XCTAssertTrue(state.started)
        XCTAssertTrue(state.cancelled)
    }

    func testChangedPrefixCancelsRecoveredChildReleasesBudgetFenceAndStartsNewAttempt() async throws {
        let fixture = try ADWorkflowFixture(body: "return await agent('new-prompt');")
        let launch = fixture.launch()
        let journal = InMemoryDynamicWorkflowJournal()
        try await journal.saveScript(fixture.saved)
        let cursor = try WorkflowReplayCursor(launch: launch)
        guard case .execute(let staleCall) = try await cursor.next(
            prompt: "old-prompt",
            options: try WorkflowAgentOptionsV1()
        ) else { return XCTFail("expected stale call") }
        let staleHandle = AgentExecutionHandleID()
        var events = try ADStartedEvents(launch)
        try ADAppend(.agentCallPrepared(staleCall), runID: launch.runID, events: &events)
        try ADAppend(
            .agentChildSubmitted(callID: staleCall.callID, handleID: staleHandle),
            runID: launch.runID,
            events: &events
        )
        _ = try await journal.append(try WorkflowEventAppendRequestV1(
            runID: launch.runID,
            expectedSequence: 0,
            expectedDigest: nil,
            events: events
        ))

        let spawner = ADRecoveredPrefixSpawner(
            staleHandle: staleHandle,
            staleRunID: staleCall.childRunID
        )
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let output = try await engine.runAndWait(runID: launch.runID)
        XCTAssertEqual(try ADDecode(output), .string("new-prompt"))
        let loadedProjection = try await engine.projection(runID: launch.runID)
        let projection = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(projection.calls.map(\.attempt), [1, 2])
        XCTAssertEqual(projection.outcomes[staleCall.callID], .stopped(usage: .zero))
        let cancellationCount = await spawner.cancellationCount()
        XCTAssertEqual(cancellationCount, 1)
    }

    func testHashChainCorruptionCASAndEventIdentityConflictFailClosed() async throws {
        let fixture = try ADWorkflowFixture(body: "return 'ok';")
        let launch = fixture.launch()
        let created = try ADEvent(runID: launch.runID, sequence: 1, previous: nil, kind: .created(launch))
        let wrongPrevious = StableDigest.sha256(Data("not-the-head".utf8))
        let broken = try ADEvent(
            runID: launch.runID, sequence: 2, previous: wrongPrevious,
            kind: .launchApproved(ApprovalID())
        )
        XCTAssertThrowsError(try WorkflowRunProjectionV1.replay([created, broken])) { error in
            XCTAssertEqual(error as? WorkflowProjectionError, .hashChainMismatch)
        }

        let journal = InMemoryDynamicWorkflowJournal()
        try await journal.saveScript(fixture.saved)
        _ = try await journal.append(try WorkflowEventAppendRequestV1(
            runID: launch.runID, expectedSequence: 0, expectedDigest: nil, events: [created]
        ))
        let approvalID = ApprovalID()
        let sharedEventID = WorkflowEventID()
        let approval = try WorkflowRunEventV1(
            eventID: sharedEventID,
            runID: launch.runID,
            sequence: 2,
            timestamp: AgentTimestamp(rawValue: 2),
            previousDigest: created.recordDigest,
            kind: .launchApproved(approvalID)
        )
        _ = try await journal.append(try WorkflowEventAppendRequestV1(
            runID: launch.runID,
            expectedSequence: 1,
            expectedDigest: created.recordDigest,
            events: [approval]
        ))

        let stale = try ADEvent(
            runID: launch.runID, sequence: 2, previous: created.recordDigest,
            kind: .launchApproved(ApprovalID())
        )
        await ADAssertThrows(WorkflowJournalError.stale(expectedSequence: 1, actualSequence: 2)) {
            _ = try await journal.append(try WorkflowEventAppendRequestV1(
                runID: launch.runID,
                expectedSequence: 1,
                expectedDigest: created.recordDigest,
                events: [stale]
            ))
        }

        let identityConflict = try WorkflowRunEventV1(
            eventID: sharedEventID,
            runID: launch.runID,
            sequence: 2,
            timestamp: AgentTimestamp(rawValue: 3),
            previousDigest: created.recordDigest,
            kind: .launchApproved(approvalID)
        )
        await ADAssertThrows(WorkflowJournalError.eventIdentityConflict) {
            _ = try await journal.append(try WorkflowEventAppendRequestV1(
                runID: launch.runID,
                expectedSequence: 1,
                expectedDigest: created.recordDigest,
                events: [identityConflict]
            ))
        }
    }

    func testHardAgentAndCollectionCeilingsRejectBeforeForbiddenDispatch() async throws {
        XCTAssertThrowsError(try ADLimits(
            maximumConcurrentAgents: 1,
            maximumAgentCalls: WorkflowRunLimitsV1.hardMaximumAgentCalls + 1
        ))
        XCTAssertThrowsError(try ADLimits(
            maximumConcurrentAgents: 1,
            maximumCollectionItems: WorkflowRunLimitsV1.hardMaximumCollectionItems + 1
        ))

        let fixture = try ADWorkflowFixture(body: """
        await agent('allowed-one');
        await agent('allowed-two');
        return await agent('must-not-dispatch');
        """)
        let spawner = ADImmediateSpawner()
        let journal = InMemoryDynamicWorkflowJournal()
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = fixture.launch(limits: try ADLimits(
            maximumConcurrentAgents: 1,
            maximumAgentCalls: 2
        ))
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        do {
            _ = try await engine.runAndWait(runID: launch.runID)
            XCTFail("third call must exceed the configured agent-call limit")
        } catch {
            XCTAssertTrue(String(describing: error).contains("agentCallLimitExceeded"))
        }
        let boundedSpawnCount = await spawner.spawnCount
        XCTAssertEqual(boundedSpawnCount, 2)

        let hardLimits = try ADLimits(
            maximumConcurrentAgents: 1,
            maximumCollectionItems: WorkflowRunLimitsV1.hardMaximumCollectionItems,
            maximumSerializedValueBytes: UInt64(CanonicalJSON.maximumBytes)
        )
        XCTAssertEqual(hardLimits.maximumCollectionItems, 4_096)

        // Cross the exact 4,096 count check without scheduling 4,096 promises: element validation
        // must run, proving the collection count itself was accepted at the inclusive boundary.
        let exactCollectionBody = "return await parallel(["
            + Array(repeating: "0", count: 4_096).joined(separator: ",")
            + "]);"
        let exactCollectionLimit = try ADAnalyze(body: exactCollectionBody)
        do {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                exactCollectionLimit,
                args: nil,
                limits: hardLimits,
                requirement: .init(),
                host: WorkflowScriptHost(agent: { _ in
                    XCTFail("invalid collection elements must not dispatch")
                    return .stopped
                })
            )
            XCTFail("non-function elements must be rejected after the inclusive count check")
        } catch {
            XCTAssertTrue(String(describing: error).contains("parallel expects thunks"))
        }

        let overCollectionBody = "return await parallel(["
            + Array(repeating: "() => 0", count: 4_097).joined(separator: ",")
            + "]);"
        let overCollectionLimit = try ADAnalyze(body: overCollectionBody)
        await ADAssertThrows(WorkflowScriptRuntimeError.collectionLimitExceeded) {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                overCollectionLimit,
                args: nil,
                limits: hardLimits,
                requirement: .init(),
                host: WorkflowScriptHost(agent: { _ in
                    XCTFail("over-limit collection must fail before dispatch")
                    return .stopped
                })
            )
        }
    }

    func testSourceValueLogPhaseStepAndWallClockLimitsFailClosed() async throws {
        let prefix = "export const meta = { name: 'source', description: 'limit' };\nreturn null;"
        let exactSource = prefix + String(
            repeating: " ",
            count: WorkflowScriptV1.maximumSourceBytes - prefix.utf8.count
        )
        XCTAssertNoThrow(try WorkflowScriptV1(
            scriptID: WorkflowScriptID(), version: 1, source: exactSource
        ))
        XCTAssertThrowsError(try WorkflowScriptV1(
            scriptID: WorkflowScriptID(), version: 1, source: exactSource + "x"
        ))

        let valueScript = try ADAnalyze(body: "return '0123456789abcdef';")
        await ADAssertThrows(
            WorkflowScriptRuntimeError.invalidResult(
                "serialized value exceeds the configured limit"
            )
        ) {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                valueScript,
                args: nil,
                limits: try ADLimits(maximumConcurrentAgents: 1, maximumSerializedValueBytes: 8),
                requirement: .init(),
                host: WorkflowScriptHost(agent: { _ in .stopped })
            )
        }

        for (body, limits) in [
            (
                "log('one'); log('two'); return null;",
                try ADLimits(maximumConcurrentAgents: 1, maximumLogLines: 1)
            ),
            (
                "phase('one'); phase('two'); return null;",
                try ADLimits(maximumConcurrentAgents: 1, maximumPhaseEntries: 1)
            ),
        ] {
            let fixture = try ADWorkflowFixture(body: body)
            let spawner = ADImmediateSpawner()
            let journal = InMemoryDynamicWorkflowJournal()
            let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
            let launch = fixture.launch(limits: limits)
            _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: launch)
            try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
            do {
                _ = try await engine.runAndWait(runID: launch.runID)
                XCTFail("observability limit must fail the workflow")
            } catch {
                let projection = try await engine.projection(runID: launch.runID)
                XCTAssertEqual(projection?.state, .failed)
            }
            let spawnCount = await spawner.spawnCount
            XCTAssertEqual(spawnCount, 0)
        }

        for body in [
            "while (true) { /* synchronous runaway */ }",
            "async function spin() { while (true) { await Promise.resolve(); } } return await spin();",
        ] {
            let runaway = try ADAnalyze(body: body)
            await ADAssertThrows(WorkflowScriptRuntimeError.stepLimitExceeded) {
                _ = try await JavaScriptCoreWorkflowRuntime().execute(
                    runaway,
                    args: nil,
                    limits: try ADLimits(maximumConcurrentAgents: 1, maximumScriptSteps: 32),
                    requirement: .init(),
                    host: WorkflowScriptHost(agent: { _ in .stopped })
                )
            }
        }

        let wallClock = try ADAnalyze(body: "return await agent('slow-host');")
        let cancellation = ADHostCancellationProbe()
        await ADAssertThrows(WorkflowScriptRuntimeError.timedOut) {
            _ = try await JavaScriptCoreWorkflowRuntime().execute(
                wallClock,
                args: nil,
                limits: try ADLimits(maximumConcurrentAgents: 1, maximumWallClockMilliseconds: 10),
                requirement: .init(),
                host: WorkflowScriptHost(agent: { _ in try await cancellation.waitUntilCancelled() })
            )
        }
        let hostState = await cancellation.snapshot()
        XCTAssertTrue(hostState.started)
        XCTAssertTrue(hostState.cancelled)
    }

    func testRollingPrefixKeyInvalidatesArgsPromptAndOutputOptionsButNotDisplayOptions() async throws {
        let fixture = try ADWorkflowFixture(body: "return null;")
        let argsA = try CanonicalJSON(.object(["value": .string("a")]))
        let argsB = try CanonicalJSON(.object(["value": .string("b")]))
        let base = fixture.launch(args: argsA)
        let originalOptions = try WorkflowAgentOptionsV1(label: "original", phase: "phase-a")
        let initial = try WorkflowReplayCursor(launch: base)
        guard case .execute(let original) = try await initial.next(
            prompt: "same-prompt", options: originalOptions
        ) else { return XCTFail("initial call must execute") }
        var events = try ADStartedEvents(base)
        try ADAppend(.agentCallPrepared(original), runID: base.runID, events: &events)
        try ADAppend(.agentCallSettled(
            callID: original.callID,
            outcome: .completed(value: .inline(try CanonicalJSON(.string("done"))), usage: .zero)
        ), runID: base.runID, events: &events)
        let projection = try XCTUnwrap(WorkflowRunProjectionV1.replay(events))

        let displayOnly = try WorkflowReplayCursor(launch: base, priorProjection: projection)
        let changedDisplay = try WorkflowAgentOptionsV1(label: "changed", phase: "phase-b", stallMilliseconds: 9)
        guard case .reuse(let displayReuse, _) = try await displayOnly.next(
            prompt: "same-prompt", options: changedDisplay
        ) else { return XCTFail("display-only options must not change output identity") }
        XCTAssertEqual(displayReuse.callID, original.callID)

        let promptCursor = try WorkflowReplayCursor(launch: base, priorProjection: projection)
        guard case .execute(let promptChanged) = try await promptCursor.next(
            prompt: "different-prompt", options: originalOptions
        ) else { return XCTFail("prompt change must invalidate the prefix") }
        XCTAssertEqual(promptChanged.attempt, 2)

        let optionCursor = try WorkflowReplayCursor(launch: base, priorProjection: projection)
        let outputOption = try WorkflowAgentOptionsV1(requestedModel: "test-model")
        guard case .execute(let optionChanged) = try await optionCursor.next(
            prompt: "same-prompt", options: outputOption
        ) else { return XCTFail("output-affecting option must invalidate the prefix") }
        XCTAssertEqual(optionChanged.attempt, 2)

        let argsCursor = try WorkflowReplayCursor(
            launch: ADCopyLaunch(base, args: argsB),
            priorProjection: projection
        )
        guard case .execute(let argsChanged) = try await argsCursor.next(
            prompt: "same-prompt", options: originalOptions
        ) else { return XCTFail("canonical args change must invalidate the prefix") }
        XCTAssertEqual(argsChanged.attempt, 2)
    }

    func testApprovalInvalidatesOnSourceAndAuthorityChange() throws {
        let fixture = try ADWorkflowFixture(body: "return 'one';")
        let launch = fixture.launch()
        let approval = try WorkflowLaunchApprovalV1(
            approvalID: ApprovalID(),
            launch: launch,
            reuseScope: .personal,
            createdAt: AgentTimestamp(rawValue: 1)
        )
        let changedSource = try ADWorkflowFixture(body: "return 'two';").launch()
        XCTAssertFalse(try approval.authorizes(changedSource))

        let changedAuthority = ADCopyLaunch(
            launch,
            capabilityCeiling: RunCapabilityCeiling(
                capabilities: AgentCapabilitySet([.localRead, .localWrite])
            )
        )
        XCTAssertFalse(try approval.authorizes(changedAuthority))
    }

    func testBudgetReservationsExhaustWhileInFlightAndReleaseAfterSettlement() async throws {
        let parallel = try ADWorkflowFixture(
            body: "return await parallel([0,1,2,3,4].map(i => () => agent(`held-${i}`)));",
            maximumConcurrentAgents: 8
        )
        let heldSpawner = ADControlledSpawner(mode: .held)
        let heldJournal = InMemoryDynamicWorkflowJournal()
        let heldEngine = ADWorkflowFixture.engine(journal: heldJournal, spawner: heldSpawner)
        let heldLaunch = parallel.launch()
        _ = try await heldEngine.prepareLaunch(script: parallel.saved, snapshot: heldLaunch)
        try await heldEngine.approveLaunch(runID: heldLaunch.runID, approvalID: ApprovalID())
        do {
            _ = try await heldEngine.runAndWait(runID: heldLaunch.runID)
            XCTFail("fifth quarter-budget reservation must be rejected while four are in flight")
        } catch {
            // Fail-closed structural budget error is expected.
        }
        let heldSpawnCount = await heldSpawner.spawnCount
        let heldCancelCount = await heldSpawner.cancelCount
        XCTAssertEqual(heldSpawnCount, 4)
        XCTAssertEqual(heldCancelCount, 4)
        let heldProjection = try await heldEngine.projection(runID: heldLaunch.runID)
        XCTAssertEqual(heldProjection?.state, .failed)

        let sampleChildBudget = try ADChildBudget(parent: heldLaunch.budget)
        XCTAssertEqual(sampleChildBudget.limits[.structuredRepairs], 0)
        XCTAssertEqual(sampleChildBudget.limits[.toolInvocations], 0)

        let sequential = try ADWorkflowFixture(body: """
        const values = [];
        for (let i = 0; i < 5; i++) { values.push(await agent(`settled-${i}`)); }
        return values;
        """)
        let immediateSpawner = ADImmediateSpawner()
        let sequentialJournal = InMemoryDynamicWorkflowJournal()
        let sequentialEngine = ADWorkflowFixture.engine(
            journal: sequentialJournal,
            spawner: immediateSpawner
        )
        let sequentialLaunch = sequential.launch()
        _ = try await sequentialEngine.prepareLaunch(
            script: sequential.saved,
            snapshot: sequentialLaunch
        )
        try await sequentialEngine.approveLaunch(
            runID: sequentialLaunch.runID,
            approvalID: ApprovalID()
        )
        let result = try await sequentialEngine.runAndWait(runID: sequentialLaunch.runID)
        guard case .array(let values) = try ADDecode(result) else {
            return XCTFail("expected sequential values")
        }
        XCTAssertEqual(values.count, 5)
        let sequentialSpawnCount = await immediateSpawner.spawnCount
        XCTAssertEqual(sequentialSpawnCount, 5)
    }

    func testAnalyzerRejectsEscapedAndReflectiveCapabilityCorpusBeforeRuntime() throws {
        let forbiddenBodies = [
            "return f\\u0065tch('https://example.com');",
            "return global\\u0054his;",
            "return `${globalThis}`;",
            "return `${({})['constructor']}`;",
            "return Object['pro' + 'totype'];",
            "return (async function() {}).constructor('return 1')();",
            "return __workflowCheckpoint;",
            "return ({ __proto__: null });",
        ]
        for body in forbiddenBodies {
            XCTAssertThrowsError(try ADAnalyze(body: body), body)
        }

        XCTAssertNoThrow(try ADAnalyze(body: """
        // fetch, globalThis, constructor and __workflowCheckpoint are inert here.
        return 'fetch globalThis constructor __workflowCheckpoint';
        """))
    }

    func testSavedVersionResolutionPinsNewestAndSecondNestedLevelIsRejected() async throws {
        let logicalID = WorkflowScriptID()
        let childV1 = try ADSavedScript(
            scriptID: logicalID,
            version: 1,
            name: "versioned-child",
            body: "return 'v1';",
            createdAt: 1
        )
        let childV2 = try ADSavedScript(
            scriptID: logicalID,
            version: 2,
            name: "versioned-child",
            body: "return 'v2';",
            createdAt: 2
        )
        let journal = InMemoryDynamicWorkflowJournal()
        try await journal.saveScript(childV1)
        try await journal.saveScript(childV2)
        let resolved = await journal.resolveScript(
            named: "versioned-child",
            owners: [ADWorkflowOwner]
        )
        XCTAssertEqual(resolved?.script.reference, childV2.script.reference)

        let root = try ADWorkflowFixture(body: "return await workflow('versioned-child');")
        let spawner = ADImmediateSpawner()
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: spawner)
        let launch = root.launch()
        _ = try await engine.prepareLaunch(script: root.saved, snapshot: launch)
        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        let output = try await engine.runAndWait(runID: launch.runID)
        XCTAssertEqual(try ADDecode(output), .string("v2"))
        let completed = try await engine.projection(runID: launch.runID)
        XCTAssertEqual(completed?.savedWorkflowPins["versioned-child"], childV2.script.reference)

        let grandchild = try ADSavedScript(
            name: "grandchild",
            body: "return await agent('must-not-dispatch');"
        )
        let nestingChild = try ADSavedScript(
            name: "nesting-child",
            body: "return await workflow('grandchild');"
        )
        let nestingRoot = try ADWorkflowFixture(body: "return await workflow('nesting-child');")
        let depthJournal = InMemoryDynamicWorkflowJournal()
        try await depthJournal.saveScript(grandchild)
        try await depthJournal.saveScript(nestingChild)
        let depthSpawner = ADImmediateSpawner()
        let depthEngine = ADWorkflowFixture.engine(journal: depthJournal, spawner: depthSpawner)
        let depthLaunch = nestingRoot.launch(limits: try ADLimits(
            maximumConcurrentAgents: 1,
            maximumNestedWorkflowDepth: 1
        ))
        _ = try await depthEngine.prepareLaunch(script: nestingRoot.saved, snapshot: depthLaunch)
        try await depthEngine.approveLaunch(runID: depthLaunch.runID, approvalID: ApprovalID())
        do {
            _ = try await depthEngine.runAndWait(runID: depthLaunch.runID)
            XCTFail("second nested workflow level must be rejected")
        } catch {
            let projection = try await depthEngine.projection(runID: depthLaunch.runID)
            XCTAssertEqual(projection?.state, .failed)
            XCTAssertEqual(projection?.savedWorkflowPins["nesting-child"], nestingChild.script.reference)
            XCTAssertNil(projection?.savedWorkflowPins["grandchild"])
        }
        let forbiddenDepthSpawns = await depthSpawner.spawnCount
        XCTAssertEqual(forbiddenDepthSpawns, 0)
    }

    func testSavedDependencyIsPinnedBeforeApprovalAndCatalogReplacementCannotRedirectExecution() async throws {
        let logicalID = WorkflowScriptID()
        let childV1 = try ADSavedScript(
            scriptID: logicalID,
            version: 1,
            name: "approval-child",
            body: "return 'approved-v1';"
        )
        let root = try ADWorkflowFixture(body: "return await workflow('approval-child');")
        let journal = InMemoryDynamicWorkflowJournal()
        try await journal.saveScript(childV1)
        let engine = ADWorkflowFixture.engine(journal: journal, spawner: ADImmediateSpawner())
        let launch = root.launch()
        _ = try await engine.prepareLaunch(script: root.saved, snapshot: launch)

        let prepared = try await engine.projection(runID: launch.runID)
        XCTAssertEqual(prepared?.state, .waitingForLaunchApproval)
        XCTAssertEqual(prepared?.launch.savedWorkflowPins["approval-child"], childV1.script.reference)
        XCTAssertEqual(prepared?.savedWorkflowPins["approval-child"], childV1.script.reference)

        try await engine.approveLaunch(runID: launch.runID, approvalID: ApprovalID())
        let childV2 = try ADSavedScript(
            scriptID: logicalID,
            version: 2,
            name: "approval-child",
            body: "return 'replacement-v2';",
            createdAt: 2
        )
        try await journal.saveScript(childV2)

        let output = try await engine.runAndWait(runID: launch.runID)
        XCTAssertEqual(try ADDecode(output), .string("approved-v1"))
        let completed = try await engine.projection(runID: launch.runID)
        XCTAssertEqual(completed?.savedWorkflowPins["approval-child"], childV1.script.reference)
    }

    func testSavedWorkflowCatalogIsOwnerIsolatedAcrossConversations() async throws {
        let conversationA = ConversationID()
        let conversationB = ConversationID()
        let ownerA = WorkflowScriptOwnerV1.conversation(conversationA)
        let ownerB = WorkflowScriptOwnerV1.conversation(conversationB)
        let childA = try ADSavedScript(
            name: "private-child", body: "return 'conversation-a';", owner: ownerA
        )
        let childB = try ADSavedScript(
            name: "private-child", body: "return 'conversation-b';", owner: ownerB
        )
        let rootA = try ADWorkflowFixture(
            body: "return await workflow('private-child');", owner: ownerA
        )
        let rootB = try ADWorkflowFixture(
            body: "return await workflow('private-child');", owner: ownerB
        )
        let journal = InMemoryDynamicWorkflowJournal()
        try await journal.saveScript(childA)
        try await journal.saveScript(childB)

        let engine = ADWorkflowFixture.engine(journal: journal, spawner: ADImmediateSpawner())
        let launchA = rootA.launch(conversationID: conversationA)
        _ = try await engine.prepareLaunch(script: rootA.saved, snapshot: launchA)
        try await engine.approveLaunch(runID: launchA.runID, approvalID: ApprovalID())
        let outputA = try await engine.runAndWait(runID: launchA.runID)
        XCTAssertEqual(try ADDecode(outputA), .string("conversation-a"))

        let launchB = rootB.launch(conversationID: conversationB)
        _ = try await engine.prepareLaunch(script: rootB.saved, snapshot: launchB)
        try await engine.approveLaunch(runID: launchB.runID, approvalID: ApprovalID())
        let outputB = try await engine.runAndWait(runID: launchB.runID)
        XCTAssertEqual(try ADDecode(outputB), .string("conversation-b"))

        let unrelated = await journal.resolveScript(named: "private-child", owners: [
            .conversation(ConversationID())
        ])
        XCTAssertNil(unrelated)
    }
}

private struct ADWorkflowFixture {
    let saved: SavedWorkflowScriptV1
    let maximumConcurrentAgents: UInt16

    init(
        name: String = "adversarial",
        body: String,
        maximumConcurrentAgents: UInt16 = 2,
        owner: WorkflowScriptOwnerV1 = ADWorkflowOwner
    ) throws {
        let source = "export const meta = { name: '\(name)', description: 'Adversarial test' };\n" + body
        let script = try WorkflowScriptV1(scriptID: WorkflowScriptID(), version: 1, source: source)
        saved = SavedWorkflowScriptV1(
            script: script,
            metadata: try WorkflowScriptMetadataV1(name: name, description: "Adversarial test"),
            owner: owner,
            createdAt: AgentTimestamp(rawValue: 1)
        )
        self.maximumConcurrentAgents = maximumConcurrentAgents
    }

    func launch(
        conversationID: ConversationID = ConversationID(),
        toolPolicyDigest: StableDigest = StableDigest.sha256(Data("tools".utf8)),
        policySnapshotDigest: StableDigest = StableDigest.sha256(Data("policy".utf8)),
        args: CanonicalJSON? = nil,
        budget: AgentBudget? = nil,
        limits: WorkflowRunLimitsV1? = nil
    ) -> WorkflowLaunchSnapshotV1 {
        let selection = AgentModelSelection(
            providerID: try! AgentModelProviderID("test.local"),
            modelID: try! AgentModelID("test-model"),
            variantID: try! AgentModelVariantID("v1"),
            capabilityVersion: try! SemanticVersion(major: 1, minor: 0, patch: 0)
        )
        let policy = try! AgentModelPolicy(
            localOnly: true,
            allowedSelections: [selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        return WorkflowLaunchSnapshotV1(
            runID: WorkflowRunID(),
            scriptReference: saved.script.reference,
            args: args,
            conversationID: conversationID,
            initiatingRunID: AgentRunID(),
            initiatingRequestID: AgentRequestID(),
            requestingStepID: AgentStepID(),
            capabilityCeiling: RunCapabilityCeiling(capabilities: AgentCapabilitySet([.localRead])),
            budget: budget ?? (try! AgentBudget.firstReleaseDefaults(
                contextTokensPerAttempt: 4_096,
                outputTokens: 1_024,
                peakMemoryBytes: 256 * 1_024 * 1_024
            )),
            defaultModelPolicy: policy,
            toolPolicyDigest: toolPolicyDigest,
            policySnapshotDigest: policySnapshotDigest,
            limits: limits ?? (try! ADLimits(maximumConcurrentAgents: maximumConcurrentAgents)),
            savedWorkflowOwners: [saved.owner]
        )
    }

    static func engine(
        journal: any DynamicWorkflowJournal,
        spawner: any SubagentSpawning,
        runtime: any WorkflowScriptRuntimeProvider = JavaScriptCoreWorkflowRuntime()
    ) -> DynamicWorkflowEngine {
        DynamicWorkflowEngine(
            journal: journal,
            runtime: runtime,
            spawner: spawner,
            requestBuilder: ClosureWorkflowChildRequestBuilder { launch, call, prompt in
                try SubagentSpawnRequest(
                    parentRunID: launch.initiatingRunID,
                    parentRequestID: launch.initiatingRequestID,
                    requestingStepID: launch.requestingStepID,
                    childRunID: call.childRunID,
                    role: call.options.requestedAgentType ?? "workflow-agent",
                    instruction: prompt,
                    outputRequirement: call.options.schema.map(AgentOutputRequirement.structured) ?? .text,
                    modelPolicy: launch.defaultModelPolicy,
                    capabilityCeiling: RunCapabilityCeiling(capabilities: AgentCapabilitySet([])),
                    budget: try ADChildBudget(parent: launch.budget),
                    source: .workflow,
                    approvalMode: launch.approvalMode
                )
            }
        )
    }
}

private func ADChildBudget(parent: AgentBudget) throws -> AgentBudget {
    // Four children may be admitted concurrently. Cumulative dimensions must use pure floor
    // division: raising a 0 share to 1 would over-reserve parent totals such as one schema repair.
    let values = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
        ($0, parent.limits[$0] / 4)
    })
    let child = try AgentBudget(
        limits: BudgetQuantities(values),
        maximumThermalState: parent.maximumThermalState,
        memoryPressureResponse: parent.memoryPressureResponse
    )
    _ = try parent.attenuating(to: child, requireStrict: true)
    return child
}

private actor ADImmediateSpawner: SubagentSpawning {
    private var active = 0
    private(set) var spawnCount = 0
    private(set) var maximumActive = 0
    private var prompts: [AgentExecutionHandleID: (AgentRunID, String)] = [:]

    func spawn(_ request: SubagentSpawnRequest) -> AgentExecutionHandleID {
        spawnCount += 1
        let handle = AgentExecutionHandleID()
        prompts[handle] = (request.childRunID, request.instruction)
        return handle
    }

    func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult {
        guard let (runID, prompt) = prompts[handleID] else {
            throw DynamicWorkflowEngineError.outputUnavailable
        }
        active += 1
        maximumActive = max(maximumActive, active)
        await Task.yield()
        active -= 1
        return SubagentResult(
            runID: runID,
            handleID: handleID,
            outcome: .completed(answer: try AgentAnswer(text: prompt), usage: .zero)
        )
    }
}

private actor ADRecoveredPrefixSpawner: SubagentSpawning {
    private let staleHandle: AgentExecutionHandleID
    private let staleRunID: AgentRunID
    private var bindings: [AgentExecutionHandleID: (AgentRunID, String)] = [:]
    private var cancellations = 0

    init(staleHandle: AgentExecutionHandleID, staleRunID: AgentRunID) {
        self.staleHandle = staleHandle
        self.staleRunID = staleRunID
        bindings[staleHandle] = (staleRunID, "old-prompt")
    }

    func spawn(_ request: SubagentSpawnRequest) -> AgentExecutionHandleID {
        let handle = AgentExecutionHandleID()
        bindings[handle] = (request.childRunID, request.instruction)
        return handle
    }

    func collect(_ handleID: AgentExecutionHandleID) throws -> SubagentResult {
        guard let (runID, prompt) = bindings[handleID], handleID != staleHandle else {
            throw DynamicWorkflowEngineError.outputUnavailable
        }
        return SubagentResult(
            runID: runID,
            handleID: handleID,
            outcome: .completed(answer: try AgentAnswer(text: prompt), usage: .zero)
        )
    }

    func cancel(_ handleID: AgentExecutionHandleID, runID: AgentRunID) throws {
        guard handleID == staleHandle, runID == staleRunID else {
            throw DynamicWorkflowEngineError.outputUnavailable
        }
        cancellations += 1
    }

    func cancellationCount() -> Int { cancellations }
}

private actor ADControlledSpawner: SubagentSpawning {
    enum Mode { case held, releasable, uncertain }

    let mode: Mode
    let losesCancellationAcknowledgement: Bool
    let delayedTerminalReads: Int
    private var terminalReads: [AgentExecutionHandleID: Int] = [:]
    private var bindings: [AgentExecutionHandleID: (runID: AgentRunID, prompt: String)] = [:]
    private var cancelled: Set<AgentExecutionHandleID> = []
    private var released = false
    private(set) var spawnCount = 0
    private(set) var collectCount = 0
    private(set) var cancelCount = 0

    init(mode: Mode, losesCancellationAcknowledgement: Bool = false, delayedTerminalReads: Int = 0) {
        self.mode = mode
        self.losesCancellationAcknowledgement = losesCancellationAcknowledgement
        self.delayedTerminalReads = delayedTerminalReads
    }

    func terminalResult(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult? {
        if case .uncertain = mode { return nil }
        guard cancelled.contains(handleID), let binding = bindings[handleID] else { return nil }
        terminalReads[handleID, default: 0] += 1
        if terminalReads[handleID, default: 0] <= delayedTerminalReads { return nil }
        return SubagentResult(runID: binding.runID, handleID: handleID, outcome: .cancelled,
            terminalUsage: losesCancellationAcknowledgement ? AgentUsage(quantities: BudgetQuantities([.inputTokens: 14])) : nil)
    }

    func spawn(_ request: SubagentSpawnRequest) -> AgentExecutionHandleID {
        spawnCount += 1
        let handle = AgentExecutionHandleID()
        bindings[handle] = (request.childRunID, request.instruction)
        return handle
    }

    func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult {
        collectCount += 1
        guard let binding = bindings[handleID] else {
            throw DynamicWorkflowEngineError.outputUnavailable
        }
        switch mode {
        case .uncertain:
            return SubagentResult(
                runID: binding.runID,
                handleID: handleID,
                outcome: .failed(failure: try AgentFailure(
                    code: "test.workflow-uncertain",
                    classification: .potentiallySideEffecting,
                    safeMessage: "external outcome is uncertain",
                    retryAdvice: .never,
                    externalEffect: .uncertain,
                    requiredUserAction: .reconcile,
                    redaction: try RedactionMetadata(
                        classification: .internalMetadata,
                        policyVersion: 1
                    )
                ), usage: .zero)
            )
        case .held:
            while !cancelled.contains(handleID) {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let result = try await terminalResult(handleID) else { throw SubagentSpawnError.resultUnavailable }
            return result
        case .releasable:
            while !released, !cancelled.contains(handleID) {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if cancelled.contains(handleID) {
                return SubagentResult(runID: binding.runID, handleID: handleID, outcome: .cancelled)
            }
            return SubagentResult(
                runID: binding.runID,
                handleID: handleID,
                outcome: .completed(answer: try AgentAnswer(text: binding.prompt), usage: .zero)
            )
        }
    }

    func cancel(_ handleID: AgentExecutionHandleID, runID: AgentRunID) throws {
        guard bindings[handleID]?.runID == runID else { return }
        if cancelled.insert(handleID).inserted { cancelCount += 1 }
        if losesCancellationAcknowledgement { throw SubagentSpawnError.resultUnavailable }
    }

    func releaseAll() { released = true }
}

private actor ADManualReconciliationSpawner: SubagentSpawning {
    private var binding: (handleID: AgentExecutionHandleID, runID: AgentRunID)?
    private var decided: AgentReconciliationDecision?
    private(set) var spawnCount = 0
    private(set) var collectCount = 0
    private(set) var reconcileCount = 0
    private(set) var collectedHandles: [AgentExecutionHandleID] = []

    func spawn(_ request: SubagentSpawnRequest) throws -> AgentExecutionHandleID {
        guard binding == nil else { throw SubagentSpawnError.invalidResult }
        spawnCount += 1
        let handle = AgentExecutionHandleID()
        binding = (handle, request.childRunID)
        return handle
    }

    func collect(_ handleID: AgentExecutionHandleID) throws -> SubagentResult {
        guard let binding, binding.handleID == handleID else {
            throw SubagentSpawnError.invalidResult
        }
        collectCount += 1
        collectedHandles.append(handleID)
        guard decided != nil else {
            throw SubagentSpawnError.reconciliationRequired(try AgentFailure(
                code: "test.manual-reconciliation",
                classification: .potentiallySideEffecting,
                safeMessage: "manual reconciliation is required",
                retryAdvice: .never,
                externalEffect: .uncertain,
                requiredUserAction: .reconcile,
                redaction: try RedactionMetadata(
                    classification: .internalMetadata,
                    policyVersion: 1
                )
            ))
        }
        return SubagentResult(
            runID: binding.runID,
            handleID: handleID,
            outcome: .completed(answer: try AgentAnswer(text: "reconciled"), usage: .zero)
        )
    }

    func reconcile(
        _ handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        decision: AgentReconciliationDecision
    ) throws {
        guard let binding,
              binding.handleID == handleID,
              binding.runID == runID,
              decided == nil
        else { throw SubagentSpawnError.invalidResult }
        reconcileCount += 1
        decided = decision
    }

    func reconciliationSnapshot() -> (
        handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        decision: AgentReconciliationDecision
    )? {
        guard let binding, let decided else { return nil }
        return (binding.handleID, binding.runID, decided)
    }
}

private actor ADIdempotentReconciliationSpawner: SubagentSpawning {
    private var binding: (AgentExecutionHandleID, AgentRunID)?
    private var decision: AgentReconciliationDecision?
    private(set) var reconcileCallCount = 0
    private(set) var appliedCommandCount = 0

    func spawn(_ request: SubagentSpawnRequest) throws -> AgentExecutionHandleID {
        guard binding == nil else { throw SubagentSpawnError.invalidResult }
        let handle = AgentExecutionHandleID()
        binding = (handle, request.childRunID)
        return handle
    }

    func collect(_ handleID: AgentExecutionHandleID) throws -> SubagentResult {
        guard let binding, binding.0 == handleID else { throw SubagentSpawnError.invalidResult }
        guard decision != nil else {
            throw SubagentSpawnError.reconciliationRequired(try ADFailure(.potentiallySideEffecting))
        }
        return SubagentResult(
            runID: binding.1,
            handleID: handleID,
            outcome: .completed(answer: try AgentAnswer(text: "reconciled"), usage: .zero)
        )
    }

    func reconcile(
        _ handleID: AgentExecutionHandleID,
        runID: AgentRunID,
        decision requested: AgentReconciliationDecision
    ) throws {
        guard let binding, binding.0 == handleID, binding.1 == runID else {
            throw SubagentSpawnError.invalidResult
        }
        reconcileCallCount += 1
        if let decision {
            guard decision == requested else { throw SubagentSpawnError.invalidResult }
            return
        }
        decision = requested
        appliedCommandCount += 1
    }
}

private actor ADFailingSpawner: SubagentSpawning {
    let failure: AgentFailure
    private var binding: (AgentExecutionHandleID, AgentRunID)?

    init(failure: AgentFailure) { self.failure = failure }

    func spawn(_ request: SubagentSpawnRequest) -> AgentExecutionHandleID {
        let handle = AgentExecutionHandleID()
        binding = (handle, request.childRunID)
        return handle
    }

    func collect(_ handleID: AgentExecutionHandleID) throws -> SubagentResult {
        guard let binding, binding.0 == handleID else { throw SubagentSpawnError.invalidResult }
        return SubagentResult(
            runID: binding.1,
            handleID: handleID,
            outcome: .failed(failure: failure, usage: .zero)
        )
    }
}

private actor ADCancelFailureSpawner: SubagentSpawning {
    private var binding: (AgentExecutionHandleID, AgentRunID)?
    private var cancellationAttempted = false
    private(set) var collectCount = 0

    func spawn(_ request: SubagentSpawnRequest) -> AgentExecutionHandleID {
        let handle = AgentExecutionHandleID()
        binding = (handle, request.childRunID)
        return handle
    }

    func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult {
        collectCount += 1
        guard let binding, binding.0 == handleID else { throw SubagentSpawnError.invalidResult }
        while !cancellationAttempted { try await Task.sleep(nanoseconds: 1_000_000) }
        return SubagentResult(runID: binding.1, handleID: handleID, outcome: .cancelled)
    }

    func cancel(_ handleID: AgentExecutionHandleID, runID: AgentRunID) throws {
        guard let binding, binding.0 == handleID, binding.1 == runID else {
            throw SubagentSpawnError.invalidResult
        }
        cancellationAttempted = true
        throw SubagentSpawnError.resultUnavailable
    }
}

private actor ADFailReconciliationDecisionJournal: DynamicWorkflowJournal {
    private let base = InMemoryDynamicWorkflowJournal()
    private var mustFailDecisionAppend = true

    func saveScript(_ script: SavedWorkflowScriptV1) async throws {
        try await base.saveScript(script)
    }

    func loadScript(
        _ reference: WorkflowScriptReferenceV1,
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> SavedWorkflowScriptV1? {
        await base.loadScript(reference, owners: owners)
    }

    func resolveScript(
        named name: String,
        owners: [WorkflowScriptOwnerV1]
    ) async throws -> SavedWorkflowScriptV1? {
        await base.resolveScript(named: name, owners: owners)
    }

    func listScripts(owners: [WorkflowScriptOwnerV1]) async throws -> [SavedWorkflowScriptV1] {
        await base.listScripts(owners: owners)
    }

    func saveLaunchApproval(_ approval: WorkflowLaunchApprovalV1) async throws {
        try await base.saveLaunchApproval(approval)
    }

    func reusableLaunchApproval(
        for launch: WorkflowLaunchSnapshotV1
    ) async throws -> WorkflowLaunchApprovalV1? {
        try await base.reusableLaunchApproval(for: launch)
    }

    func loadProjection(for runID: WorkflowRunID) async throws -> WorkflowRunProjectionV1? {
        try await base.loadProjection(for: runID)
    }

    func append(_ request: WorkflowEventAppendRequestV1) async throws -> WorkflowJournalAppendReceipt {
        if mustFailDecisionAppend,
           request.events.contains(where: {
               if case .reconciliationDecided = $0.kind { return true }
               return false
           })
        {
            mustFailDecisionAppend = false
            throw WorkflowJournalError.unavailable("injected reconciliation receipt crash")
        }
        return try await base.append(request)
    }

    func readEvents(
        runID: WorkflowRunID,
        after sequence: UInt64,
        limit: Int
    ) async throws -> WorkflowJournalEventPage {
        try await base.readEvents(runID: runID, after: sequence, limit: limit)
    }
}

private func ADFailure(_ classification: AgentFailureClassification) throws -> AgentFailure {
    let uncertain = classification == .potentiallySideEffecting
    return try AgentFailure(
        code: "test.workflow-\(classification.rawValue.lowercased())",
        classification: classification,
        safeMessage: "safe \(classification.rawValue) failure",
        retryAdvice: .never,
        externalEffect: uncertain ? .uncertain : .confirmedNone,
        requiredUserAction: uncertain ? .reconcile : .none,
        redaction: RedactionMetadata(
            classification: .internalMetadata,
            policyVersion: 1
        )
    )
}

private actor ADGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor ADHostCancellationProbe {
    private var started = false
    private var cancelled = false

    func waitUntilCancelled() async throws -> WorkflowAgentBridgeResult {
        started = true
        do {
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func snapshot() -> (started: Bool, cancelled: Bool) { (started, cancelled) }
}

private func ADLimits(
    maximumConcurrentAgents: UInt16,
    maximumAgentCalls: UInt32 = 32,
    maximumCollectionItems: UInt32 = 32,
    maximumWallClockMilliseconds: UInt64 = 5_000,
    maximumScriptSteps: UInt64 = 1_000_000,
    maximumLogLines: UInt32 = 100,
    maximumPhaseEntries: UInt32 = 100,
    maximumSerializedValueBytes: UInt64 = 1_048_576,
    maximumNestedWorkflowDepth: UInt8 = 1
) throws -> WorkflowRunLimitsV1 {
    try WorkflowRunLimitsV1(
        maximumConcurrentAgents: maximumConcurrentAgents,
        maximumAgentCalls: maximumAgentCalls,
        maximumCollectionItems: maximumCollectionItems,
        maximumWallClockMilliseconds: maximumWallClockMilliseconds,
        maximumScriptSteps: maximumScriptSteps,
        maximumLogLines: maximumLogLines,
        maximumPhaseEntries: maximumPhaseEntries,
        maximumSerializedValueBytes: maximumSerializedValueBytes,
        maximumNestedWorkflowDepth: maximumNestedWorkflowDepth
    )
}

private func ADAnalyze(body: String) throws -> AnalyzedWorkflowScriptV1 {
    let script = try WorkflowScriptV1(
        scriptID: WorkflowScriptID(),
        version: 1,
        source: "export const meta = { name: 'analysis', description: 'Adversarial analysis' };\n" + body
    )
    return try DynamicWorkflowScriptAnalyzer().analyze(script)
}

private func ADSavedScript(
    scriptID: WorkflowScriptID = WorkflowScriptID(),
    version: UInt64 = 1,
    name: String,
    body: String,
    createdAt: Int64 = 1,
    owner: WorkflowScriptOwnerV1 = ADWorkflowOwner
) throws -> SavedWorkflowScriptV1 {
    let script = try WorkflowScriptV1(
        scriptID: scriptID,
        version: version,
        source: "export const meta = { name: '\(name)', description: 'Saved adversarial test' };\n" + body
    )
    return SavedWorkflowScriptV1(
        script: script,
        metadata: try WorkflowScriptMetadataV1(
            name: name,
            description: "Saved adversarial test"
        ),
        owner: owner,
        createdAt: AgentTimestamp(rawValue: createdAt)
    )
}

private func ADCopyLaunch(
    _ launch: WorkflowLaunchSnapshotV1,
    args: CanonicalJSON? = nil,
    capabilityCeiling: RunCapabilityCeiling? = nil
) -> WorkflowLaunchSnapshotV1 {
    WorkflowLaunchSnapshotV1(
        runID: launch.runID,
        scriptReference: launch.scriptReference,
        args: args ?? launch.args,
        conversationID: launch.conversationID,
        initiatingRunID: launch.initiatingRunID,
        initiatingRequestID: launch.initiatingRequestID,
        requestingStepID: launch.requestingStepID,
        capabilityCeiling: capabilityCeiling ?? launch.capabilityCeiling,
        budget: launch.budget,
        defaultModelPolicy: launch.defaultModelPolicy,
        toolPolicyDigest: launch.toolPolicyDigest,
        policySnapshotDigest: launch.policySnapshotDigest,
        runtimeRequirement: launch.runtimeRequirement,
        limits: launch.limits,
        approvalMode: launch.approvalMode,
        savedWorkflowOwners: launch.savedWorkflowOwners,
        savedWorkflowPins: launch.savedWorkflowPins
    )
}

private let ADWorkflowOwner = WorkflowScriptOwnerV1.personal(
    StableDigest.sha256(Data("agent-runtime-adversarial-workflow-owner".utf8))
)

private func ADStartedEvents(_ launch: WorkflowLaunchSnapshotV1) throws -> [WorkflowRunEventV1] {
    var events: [WorkflowRunEventV1] = []
    try ADAppend(.created(launch), runID: launch.runID, events: &events)
    try ADAppend(.launchApproved(ApprovalID()), runID: launch.runID, events: &events)
    try ADAppend(
        .stateChanged(from: .waitingForLaunchApproval, to: .queued, reason: nil),
        runID: launch.runID, events: &events
    )
    try ADAppend(
        .stateChanged(from: .queued, to: .running, reason: nil),
        runID: launch.runID, events: &events
    )
    return events
}

private func ADAppend(
    _ kind: WorkflowRunEventKindV1,
    runID: WorkflowRunID,
    events: inout [WorkflowRunEventV1]
) throws {
    events.append(try ADEvent(
        runID: runID,
        sequence: UInt64(events.count + 1),
        previous: events.last?.recordDigest,
        kind: kind
    ))
}

private func ADEvent(
    runID: WorkflowRunID,
    sequence: UInt64,
    previous: StableDigest?,
    kind: WorkflowRunEventKindV1
) throws -> WorkflowRunEventV1 {
    try WorkflowRunEventV1(
        eventID: WorkflowEventID(),
        runID: runID,
        sequence: sequence,
        timestamp: AgentTimestamp(rawValue: Int64(sequence)),
        previousDigest: previous,
        kind: kind
    )
}

private func ADDecode(_ value: CanonicalJSON) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: value.data)
}

private func ADEventually(
    iterations: Int = 1_000,
    condition: @escaping @Sendable () async throws -> Bool
) async throws -> Bool {
    for _ in 0 ..< iterations {
        if try await condition() { return true }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
}

private func ADAssertThrows<E: Error & Equatable>(
    _ expected: E,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func ADAssertThrowsAny(
    _ operation: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
