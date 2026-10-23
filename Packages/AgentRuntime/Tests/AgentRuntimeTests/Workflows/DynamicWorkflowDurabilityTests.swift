// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-DYNAMIC-001

final class DynamicWorkflowDurabilityTests: XCTestCase {
    func testShrinkingAdmissionWaitsForReservedCapacityButNotTrueExhaustion() async throws {
        let fixture = try makeFixture(body: "return null;")
        let created = try event(runID: fixture.launch.runID, sequence: 1, previous: nil, kind: .created(fixture.launch))
        let projection = try XCTUnwrap(WorkflowRunProjectionV1.replay([created]))
        let cursor = try WorkflowReplayCursor(launch: fixture.launch)
        var calls: [WorkflowAgentCallV1] = []
        for label in ["first", "waiting", "exhausted"] {
            guard case .execute(let call) = try await cursor.next(prompt: label, options: WorkflowAgentOptionsV1()) else { return XCTFail("new call") }
            calls.append(call)
        }
        let firstCall = calls[0], waitingCall = calls[1], lastCall = calls[2]
        let coordinator = try WorkflowBudgetCoordinator(projection: projection)
        let first = try await coordinator.admitAvailable(call: firstCall) { remaining in
            try fullCapacityRequest(fixture.launch, firstCall, remaining)
        }
        let blocked = expectation(description: "waiting on a reservation")
        let pending = Task {
            try await coordinator.admitAvailable(call: waitingCall) { remaining in
                if remaining.limits[.modelAttempts] == 0 {
                    blocked.fulfill()
                    throw AgentContractError.budgetExceeded(dimension: .modelAttempts, limit: 0, requested: 1)
                }
                return try fullCapacityRequest(fixture.launch, waitingCall, remaining)
            }
        }
        await fulfillment(of: [blocked], timeout: 2)
        _ = try await coordinator.settle(call: firstCall, admission: first.admission,
            actualUsage: AgentUsage(quantities: BudgetQuantities([.modelAttempts: 1])))
        let admitted = try await pending.value
        XCTAssertEqual(admitted.request.budget.limits[.modelAttempts], fixture.launch.budget.limits[.modelAttempts] - 1)
        _ = try await coordinator.settle(call: waitingCall, admission: admitted.admission,
            actualUsage: AgentUsage(quantities: BudgetQuantities([.modelAttempts: admitted.request.budget.limits[.modelAttempts]])))
        do {
            _ = try await coordinator.admitAvailable(call: lastCall) { _ in
                throw AgentContractError.budgetExceeded(dimension: .modelAttempts, limit: 0, requested: 1)
            }
            XCTFail("Consumed capacity must not be treated as a temporary reservation")
        } catch { XCTAssertEqual(error as? AgentContractError, .budgetExceeded(dimension: .modelAttempts, limit: 0, requested: 1)) }

        let cancellable = try WorkflowBudgetCoordinator(projection: projection)
        let held = try await cancellable.admitAvailable(call: firstCall) { try fullCapacityRequest(fixture.launch, firstCall, $0) }
        let waiting = expectation(description: "cancellable capacity wait")
        let cancelled = Task {
            try await cancellable.admitAvailable(call: waitingCall) { _ in
                waiting.fulfill()
                throw AgentContractError.budgetExceeded(dimension: .modelAttempts, limit: 0, requested: 1)
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Wait must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await cancellable.releaseUnsubmitted(held.admission)
    }

    func testFailedAdmissionIsDurableInsteadOfLeavingAnUnsettledPreparedCall() async throws {
        let fixture = try makeFixture(body: "try { await agent('no-capacity'); } catch(e) {} return 'handled';")
        let spawner = WorkflowFakeSpawner()
        let engine = DynamicWorkflowEngine(journal: InMemoryDynamicWorkflowJournal(), runtime: JavaScriptCoreWorkflowRuntime(),
            spawner: spawner, requestBuilder: ClosureWorkflowChildRequestBuilder { _, _, _ in
                throw AgentContractError.budgetExceeded(dimension: .modelAttempts, limit: 0, requested: 1)
            })
        _ = try await engine.prepareLaunch(script: fixture.saved, snapshot: fixture.launch)
        try await engine.approveLaunch(runID: fixture.launch.runID, approvalID: ApprovalID())
        _ = try await engine.runAndWait(runID: fixture.launch.runID)
        let loaded = try await engine.projection(runID: fixture.launch.runID)
        let projection = try XCTUnwrap(loaded)
        let call = try XCTUnwrap(projection.calls.first)
        guard case .failed(let failure, let usage) = projection.outcomes[call.callID] else { return XCTFail("Durable failure required") }
        XCTAssertEqual(failure.classification, .budgetRelated)
        XCTAssertEqual(usage, .zero)
        let count = await spawner.spawnCount
        XCTAssertEqual(count, 0)
    }

    func testRecoveredEvidenceContainsOnlyCallsReachedByTheReplayedPrefix() async throws {
        let fixture = try makeFixture(body: """
        await agent('one');
        const first = await webEvidence('one');
        const otherQuery = await webEvidence('two');
        await agent('two');
        const second = await webEvidence();
        return [first.sources.length, second.sources.length,
          first.observations[0].matchingExcerpts.length, otherQuery.observations[0].matchingExcerpts.length];
        """)
        let journal = InMemoryDynamicWorkflowJournal()
        try await journal.saveScript(fixture.saved)
        let cursor = try WorkflowReplayCursor(launch: fixture.launch)
        var events: [WorkflowRunEventV1] = []
        try appendEvent(.created(fixture.launch), runID: fixture.launch.runID, to: &events)
        try appendEvent(.launchApproved(ApprovalID()), runID: fixture.launch.runID, to: &events)
        try appendEvent(.stateChanged(from: .waitingForLaunchApproval, to: .queued, reason: nil), runID: fixture.launch.runID, to: &events)
        try appendEvent(.stateChanged(from: .queued, to: .running, reason: nil), runID: fixture.launch.runID, to: &events)
        var observations: [AgentExecutionHandleID: [WorkflowWebObservation]] = [:]
        for prompt in ["one", "two"] {
            guard case .execute(let call) = try await cursor.next(prompt: prompt, options: WorkflowAgentOptionsV1()) else {
                return XCTFail("Expected a new call")
            }
            let handle = AgentExecutionHandleID()
            observations[handle] = [WorkflowWebObservation(invocationID: prompt,
                toolID: try AgentToolLogicalID(providerID: "builtin", name: "fetch_webpage"),
                requestedURL: "https://example.edu/" + prompt, status: "completed", text: prompt)]
            try appendEvent(.agentCallPrepared(call), runID: fixture.launch.runID, to: &events)
            try appendEvent(.agentChildSubmitted(callID: call.callID, handleID: handle), runID: fixture.launch.runID, to: &events)
            try appendEvent(.agentCallSettled(callID: call.callID, outcome: .completed(
                value: .inline(try CanonicalJSON(.string(prompt))), usage: .zero)), runID: fixture.launch.runID, to: &events)
        }
        _ = try await journal.append(WorkflowEventAppendRequestV1(runID: fixture.launch.runID,
            expectedSequence: 0, expectedDigest: nil, events: events))
        let spawner = WorkflowFakeSpawner(observations: observations)
        let engine = DynamicWorkflowEngine(journal: journal, runtime: JavaScriptCoreWorkflowRuntime(),
            spawner: spawner, requestBuilder: childBuilder())
        let result = try await engine.runAndWait(runID: fixture.launch.runID)
        XCTAssertEqual(try decode(result), .array([.integer(1), .integer(2), .integer(1), .integer(0)]))
        let counts = await spawner.counts()
        XCTAssertEqual(counts.spawn, 0)
        XCTAssertEqual(counts.collect, 0)
    }

    func testSQLiteJournalIsLazyExactReplayCASAndReopensFromEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflows.sqlite3")
        let journal = SQLiteDynamicWorkflowJournal(databaseURL: url)
        XCTAssertFalse(journal.databaseExists())
        let absentProjection = try await journal.loadProjection(for: WorkflowRunID())
        XCTAssertNil(absentProjection)
        XCTAssertFalse(journal.databaseExists())

        let fixture = try makeFixture(body: "return 'ok';")
        try await journal.saveScript(fixture.saved)
        let created = try event(
            runID: fixture.launch.runID,
            sequence: 1,
            previous: nil,
            kind: .created(fixture.launch)
        )
        let request = try WorkflowEventAppendRequestV1(
            runID: fixture.launch.runID,
            expectedSequence: 0,
            expectedDigest: nil,
            events: [created]
        )
        let appended = try await journal.append(request)
        let replayed = try await journal.append(request)
        XCTAssertEqual(appended.disposition, .appended)
        XCTAssertEqual(replayed.disposition, .replayed)

        let conflicting = try event(
            runID: fixture.launch.runID,
            sequence: 1,
            previous: nil,
            kind: .created(fixture.launch)
        )
        await assertThrows(expected: WorkflowJournalError.stale(expectedSequence: 0, actualSequence: 1)) {
            _ = try await journal.append(try WorkflowEventAppendRequestV1(
                runID: fixture.launch.runID,
                expectedSequence: 0,
                expectedDigest: nil,
                events: [conflicting]
            ))
        }

        await journal.close()
        let reopened = SQLiteDynamicWorkflowJournal(databaseURL: url)
        let projection = try await reopened.loadProjection(for: fixture.launch.runID)
        XCTAssertEqual(projection?.lastDigest, created.recordDigest)
        let reopenedScript = try await reopened.loadScript(
            fixture.saved.script.reference,
            owners: [fixture.saved.owner]
        )
        XCTAssertEqual(reopenedScript, fixture.saved)
    }

    func testRollingPrefixReusesOnlyContiguousCompletedCallsAndContinuesUnsettledWork() async throws {
        let fixture = try makeFixture(body: "return null;")
        let initial = try WorkflowReplayCursor(launch: fixture.launch)
        let options = try WorkflowAgentOptionsV1()
        guard case .execute(let call1) = try await initial.next(prompt: "one", options: options),
              case .execute(let call2) = try await initial.next(prompt: "two", options: options),
              case .execute(let call3) = try await initial.next(prompt: "three", options: options)
        else { return XCTFail("initial calls must execute") }

        var events: [WorkflowRunEventV1] = []
        try appendEvent(.created(fixture.launch), runID: fixture.launch.runID, to: &events)
        try appendEvent(.launchApproved(ApprovalID()), runID: fixture.launch.runID, to: &events)
        try appendEvent(
            .stateChanged(from: .waitingForLaunchApproval, to: .queued, reason: nil),
            runID: fixture.launch.runID, to: &events
        )
        try appendEvent(
            .stateChanged(from: .queued, to: .running, reason: nil),
            runID: fixture.launch.runID, to: &events
        )
        try appendEvent(.agentCallPrepared(call1), runID: fixture.launch.runID, to: &events)
        try appendEvent(
            .agentCallSettled(callID: call1.callID, outcome: .completed(
                value: .inline(try CanonicalJSON(.string("one"))), usage: .zero
            )), runID: fixture.launch.runID, to: &events
        )
        try appendEvent(.agentCallPrepared(call2), runID: fixture.launch.runID, to: &events)
        try appendEvent(
            .agentCallSettled(callID: call2.callID, outcome: .completed(
                value: .inline(try CanonicalJSON(.string("two"))), usage: .zero
            )), runID: fixture.launch.runID, to: &events
        )
        try appendEvent(.agentCallPrepared(call3), runID: fixture.launch.runID, to: &events)
        let projection = try XCTUnwrap(WorkflowRunProjectionV1.replay(events))

        let resumed = try WorkflowReplayCursor(launch: fixture.launch, priorProjection: projection)
        guard case .reuse(let reused, _) = try await resumed.next(prompt: "one", options: options) else {
            return XCTFail("first completed call should be reused")
        }
        XCTAssertEqual(reused.callID, call1.callID)
        guard case .execute(let changed) = try await resumed.next(prompt: "changed", options: options) else {
            return XCTFail("changed call must execute")
        }
        XCTAssertEqual(changed.ordinal, 2)
        XCTAssertEqual(changed.attempt, 2)
        guard case .execute(let suffix) = try await resumed.next(prompt: "three", options: options) else {
            return XCTFail("suffix after a mismatch must not be reused")
        }
        XCTAssertEqual(suffix.ordinal, 3)
        XCTAssertEqual(suffix.attempt, 2)

        let continuing = try WorkflowReplayCursor(launch: fixture.launch, priorProjection: projection)
        _ = try await continuing.next(prompt: "one", options: options)
        _ = try await continuing.next(prompt: "two", options: options)
        guard case .continue(let unsettled) = try await continuing.next(prompt: "three", options: options) else {
            return XCTFail("prepared work must reattach instead of duplicate")
        }
        XCTAssertEqual(unsettled.callID, call3.callID)
    }

    func testDispatchSchedulerBoundsConcurrencyPreservesFIFOAndPausesAdmission() async throws {
        let scheduler = WorkflowDispatchScheduler(maximumConcurrentAgents: 2)
        let probe = SchedulerProbe()
        let tasks = (0 ..< 6).map { value in
            Task {
                try await scheduler.run {
                    await probe.started(value)
                    try await Task.sleep(nanoseconds: 20_000_000)
                    await probe.finished(value)
                    return value
                }
            }
        }
        let values = try await tasks.asyncMap { try await $0.value }
        XCTAssertEqual(values, Array(0 ..< 6))
        let snapshot = await probe.snapshot()
        XCTAssertLessThanOrEqual(snapshot.maximumActive, 2)
        XCTAssertEqual(Set(snapshot.starts), Set(0 ..< 6))

        await scheduler.pause()
        let blocked = Task { try await scheduler.run { 99 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waitingCount = await scheduler.waitingCount
        XCTAssertEqual(waitingCount, 1)
        await scheduler.resume()
        let unblocked = try await blocked.value
        XCTAssertEqual(unblocked, 99)
    }

    func testEngineRequiresLaunchApprovalRunsParallelAgentsAndCommitsOutput() async throws {
        let fixture = try makeFixture(body: """
        phase('Research');
        const values = await parallel([() => agent('one'), () => agent('two')]);
        return { values };
        """)
        let journal = InMemoryDynamicWorkflowJournal()
        let spawner = WorkflowFakeSpawner()
        let engine = DynamicWorkflowEngine(
            journal: journal,
            runtime: JavaScriptCoreWorkflowRuntime(),
            spawner: spawner,
            requestBuilder: childBuilder()
        )
        let preview = try await engine.prepareLaunch(script: fixture.saved, snapshot: fixture.launch)
        XCTAssertEqual(preview.metadata.name, "durability-test")
        await assertThrows(expected: DynamicWorkflowEngineError.launchApprovalRequired) {
            _ = try await engine.runAndWait(runID: fixture.launch.runID)
        }
        let preApprovalSpawns = await spawner.spawnCount
        XCTAssertEqual(preApprovalSpawns, 0)

        try await engine.approveLaunch(runID: fixture.launch.runID, approvalID: ApprovalID())
        let output = try await engine.runAndWait(runID: fixture.launch.runID)
        XCTAssertEqual(try decode(output), .object([
            "values": .array([.string("one"), .string("two")])
        ]))
        let loadedProjection = try await engine.projection(runID: fixture.launch.runID)
        let projection = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(projection.state, .completed)
        XCTAssertEqual(projection.calls.map(\.ordinal), [1, 2])
        XCTAssertEqual(projection.currentPhase, "Research")
        let completedSpawns = await spawner.spawnCount
        XCTAssertEqual(completedSpawns, 2)
    }

    func testEngineRecoveryCollectsSubmittedChildWithoutSpawningAgain() async throws {
        let fixture = try makeFixture(body: "return await agent('recover-me');")
        let journal = InMemoryDynamicWorkflowJournal()
        try await journal.saveScript(fixture.saved)
        let cursor = try WorkflowReplayCursor(launch: fixture.launch)
        guard case .execute(let call) = try await cursor.next(
            prompt: "recover-me", options: try WorkflowAgentOptionsV1()
        ) else { return XCTFail("expected call") }
        let handle = AgentExecutionHandleID()
        var events: [WorkflowRunEventV1] = []
        try appendEvent(.created(fixture.launch), runID: fixture.launch.runID, to: &events)
        try appendEvent(.launchApproved(ApprovalID()), runID: fixture.launch.runID, to: &events)
        try appendEvent(
            .stateChanged(from: .waitingForLaunchApproval, to: .queued, reason: nil),
            runID: fixture.launch.runID, to: &events
        )
        try appendEvent(
            .stateChanged(from: .queued, to: .running, reason: nil),
            runID: fixture.launch.runID, to: &events
        )
        try appendEvent(.agentCallPrepared(call), runID: fixture.launch.runID, to: &events)
        try appendEvent(
            .agentChildSubmitted(callID: call.callID, handleID: handle),
            runID: fixture.launch.runID, to: &events
        )
        _ = try await journal.append(try WorkflowEventAppendRequestV1(
            runID: fixture.launch.runID,
            expectedSequence: 0,
            expectedDigest: nil,
            events: events
        ))
        let spawner = WorkflowFakeSpawner(preexisting: [handle: (call.childRunID, "recovered")])
        let engine = DynamicWorkflowEngine(
            journal: journal,
            runtime: JavaScriptCoreWorkflowRuntime(),
            spawner: spawner,
            requestBuilder: childBuilder()
        )
        let recovered = try await engine.runAndWait(runID: fixture.launch.runID)
        XCTAssertEqual(try decode(recovered), .string("recovered"))
        let recoveryCounts = await spawner.counts()
        XCTAssertEqual(recoveryCounts.spawn, 0)
        XCTAssertEqual(recoveryCounts.collect, 1)
    }
}

private struct WorkflowFixture {
    let saved: SavedWorkflowScriptV1
    let launch: WorkflowLaunchSnapshotV1
}

private func fullCapacityRequest(_ launch: WorkflowLaunchSnapshotV1, _ call: WorkflowAgentCallV1, _ budget: AgentBudget) throws -> SubagentSpawnRequest {
    try SubagentSpawnRequest(parentRunID: launch.initiatingRunID, parentRequestID: launch.initiatingRequestID,
        requestingStepID: launch.requestingStepID, childRunID: call.childRunID, role: "budget-probe",
        instruction: "Exercise admission only", outputRequirement: .text, modelPolicy: launch.defaultModelPolicy,
        capabilityCeiling: RunCapabilityCeiling(capabilities: AgentCapabilitySet([])), budget: budget,
        source: .workflow, approvalMode: launch.approvalMode)
}

private func makeFixture(body: String) throws -> WorkflowFixture {
    let conversationID = ConversationID()
    let source = "export const meta = { name: 'durability-test', description: 'Durability test' };\n" + body
    let script = try WorkflowScriptV1(scriptID: WorkflowScriptID(), version: 1, source: source)
    let saved = SavedWorkflowScriptV1(
        script: script,
        metadata: try WorkflowScriptMetadataV1(name: "durability-test", description: "Durability test"),
        owner: .conversation(conversationID),
        createdAt: AgentTimestamp(rawValue: 1)
    )
    let selection = AgentModelSelection(
        providerID: try AgentModelProviderID("test.local"),
        modelID: try AgentModelID("test-model"),
        variantID: try AgentModelVariantID("v1"),
        capabilityVersion: try SemanticVersion(major: 1, minor: 0, patch: 0)
    )
    let policy = try AgentModelPolicy(
        localOnly: true,
        allowedSelections: [selection],
        strategy: .pinned,
        requiredCapabilities: AgentModelCapabilitySet([])
    )
    let budget = try AgentBudget.firstReleaseDefaults(
        contextTokensPerAttempt: 4_096,
        outputTokens: 1_024,
        peakMemoryBytes: 256 * 1_024 * 1_024
    )
    let launch = WorkflowLaunchSnapshotV1(
        runID: WorkflowRunID(),
        scriptReference: script.reference,
        args: nil,
        conversationID: conversationID,
        initiatingRunID: AgentRunID(),
        initiatingRequestID: AgentRequestID(),
        requestingStepID: AgentStepID(),
        capabilityCeiling: RunCapabilityCeiling(capabilities: AgentCapabilitySet([.localRead])),
        budget: budget,
        defaultModelPolicy: policy,
        toolPolicyDigest: StableDigest.sha256(Data("tools".utf8)),
        policySnapshotDigest: StableDigest.sha256(Data("policy".utf8)),
        limits: try WorkflowRunLimitsV1(
            maximumConcurrentAgents: 2,
            maximumAgentCalls: 32,
            maximumCollectionItems: 32,
            maximumWallClockMilliseconds: 5_000,
            maximumScriptSteps: 100_000,
            maximumLogLines: 100,
            maximumPhaseEntries: 100,
            maximumSerializedValueBytes: 1_048_576
        )
    )
    return WorkflowFixture(saved: saved, launch: launch)
}

private func childBuilder() -> ClosureWorkflowChildRequestBuilder {
    ClosureWorkflowChildRequestBuilder { launch, call, prompt in
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
            budget: try workflowChildBudget(parent: launch.budget),
            source: .workflow,
            approvalMode: launch.approvalMode
        )
    }
}

private actor WorkflowFakeSpawner: SubagentSpawning {
    private var promptsByHandle: [AgentExecutionHandleID: (AgentRunID, String)]
    private(set) var spawnCount = 0
    private(set) var collectCount = 0
    private let observations: [AgentExecutionHandleID: [WorkflowWebObservation]]

    init(preexisting: [AgentExecutionHandleID: (AgentRunID, String)] = [:],
         observations: [AgentExecutionHandleID: [WorkflowWebObservation]] = [:]) {
        promptsByHandle = preexisting
        self.observations = observations
    }

    func webObservations(_ handleID: AgentExecutionHandleID) async throws -> [WorkflowWebObservation] {
        observations[handleID, default: []]
    }

    func spawn(_ request: SubagentSpawnRequest) async throws -> AgentExecutionHandleID {
        spawnCount += 1
        let handle = AgentExecutionHandleID()
        promptsByHandle[handle] = (request.childRunID, request.instruction)
        return handle
    }

    func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult {
        collectCount += 1
        guard let (runID, prompt) = promptsByHandle[handleID] else {
            throw DynamicWorkflowEngineError.outputUnavailable
        }
        return SubagentResult(
            runID: runID,
            handleID: handleID,
            outcome: .completed(answer: try AgentAnswer(text: prompt), usage: .zero)
        )
    }

    func counts() -> (spawn: Int, collect: Int) { (spawnCount, collectCount) }
}

private func workflowChildBudget(parent: AgentBudget) throws -> AgentBudget {
    let child = try AgentBudget(
        // The fixture launches two children concurrently. Pure floor sharing is important here:
        // promoting a zero cumulative share to one would over-reserve parent dimensions whose
        // total budget is one (for example structured-output repairs).
        limits: parent.limits.sharingCumulativeCapacity(among: 2),
        maximumThermalState: parent.maximumThermalState,
        memoryPressureResponse: parent.memoryPressureResponse
    )
    _ = try parent.attenuating(to: child, requireStrict: true)
    return child
}

private actor SchedulerProbe {
    private var active = 0
    private var maximum = 0
    private var order: [Int] = []
    func started(_ value: Int) { active += 1; maximum = max(maximum, active); order.append(value) }
    func finished(_: Int) { active -= 1 }
    func snapshot() -> (maximumActive: Int, starts: [Int]) { (maximum, order) }
}

private func event(
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

private func appendEvent(
    _ kind: WorkflowRunEventKindV1,
    runID: WorkflowRunID,
    to events: inout [WorkflowRunEventV1]
) throws {
    events.append(try event(
        runID: runID,
        sequence: UInt64(events.count + 1),
        previous: events.last?.recordDigest,
        kind: kind
    ))
}

private func decode(_ value: CanonicalJSON) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: value.data)
}

private extension Array where Element: Sendable {
    func asyncMap<T: Sendable>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}

private func assertThrows<E: Error & Equatable>(
    expected: E,
    _ operation: () async throws -> Void,
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
