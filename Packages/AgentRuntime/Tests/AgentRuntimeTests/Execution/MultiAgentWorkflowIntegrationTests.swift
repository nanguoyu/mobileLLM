// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-SPAWNER-001
// TEST-ID: AHT-PARALLEL-001
// TEST-ID: AHT-WORKFLOW-001
final class MultiAgentWorkflowIntegrationTests: XCTestCase {
    // MARK: - Subagent spawner (real executor)

    func testSubagentSpawnerCreatesAttenuatedChildAndCollectsResult() async throws {
        let model = try ExecutorTestModelDefinition(offset: 401)
        let parentCeiling = try RunCapabilityCeiling(
            authority: AgentAuthorityScope(
                capabilities: AgentCapabilitySet([.localRead, .localWrite])
            )
        )
        let gate = BlockingModelGate()
        let provider = try BlockingCompletionModelProvider(
            model: model,
            answer: "parent answer",
            gate: gate
        )
        let harness = try ExecutorTestHarness(
            offset: 401,
            provider: provider,
            model: model,
            capabilityCeiling: parentCeiling
        )
        let spawner = DurableSubagentSpawner(
            executor: harness.executor,
            repository: harness.repository
        )

        let parentHandleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(401)
        )
        try await waitForGateEntry(gate)

        let childBudget = try attenuatedChildBudget(parent: harness.request.budget)
        let childCeiling = try RunCapabilityCeiling(
            authority: AgentAuthorityScope(
                capabilities: AgentCapabilitySet([.localRead])
            )
        )
        let childRunID = ExecutorTestID.run(402)
        let spawnRequest = try SubagentSpawnRequest(
            parentRunID: harness.request.runID,
            parentRequestID: harness.request.id,
            requestingStepID: ExecutionStableID.step(runID: harness.request.runID, attempt: 1),
            childRunID: childRunID,
            role: "subagent",
            instruction: "Answer the delegated question.",
            outputRequirement: .text,
            modelPolicy: harness.request.modelPolicy,
            capabilityCeiling: childCeiling,
            budget: childBudget,
            source: .parentAgent
        )

        let childHandleID = try await spawner.spawn(spawnRequest)

        // The child is durably submitted under the reserved parent identity with strict attenuation.
        let childFactsValue = try await harness.repository.loadRunFacts(for: childRunID)
        let childFacts = try XCTUnwrap(childFactsValue)
        let childPayload = try XCTUnwrap(childFacts.submission?.request.payload)
        XCTAssertEqual(childPayload.parent?.runID, harness.request.runID)
        XCTAssertEqual(childPayload.provenance.parentRequestID, harness.request.id)
        XCTAssertEqual(childPayload.provenance.source, .parentAgent)
        XCTAssertEqual(childPayload.capabilityCeiling, childCeiling)
        XCTAssertEqual(childPayload.budget, childBudget)

        // Release both parent and child generations; the child result is collected durably.
        await gate.release()
        let childResult = try await spawner.collect(childHandleID)
        guard case .completed(let answer, _) = childResult.outcome else {
            return XCTFail("expected child completion, got \(childResult.outcome)")
        }
        XCTAssertEqual(answer.text, "parent answer")
        XCTAssertEqual(childResult.runID, childRunID)

        _ = try await collectTerminalEvents(
            from: try await harness.executor.attach(to: parentHandleID)
        )
        let parentResult = try await harness.executor.attach(to: parentHandleID).result()
        XCTAssertEqual(parentResult?.status.state, .completed)
    }

    func testSubagentSpawnerRejectsTerminalParentAndNonAttenuatedRequests() async throws {
        let model = try ExecutorTestModelDefinition(offset: 403)
        let parentCeiling = try RunCapabilityCeiling(
            authority: AgentAuthorityScope(
                capabilities: AgentCapabilitySet([.localRead, .localWrite])
            )
        )
        let gate = BlockingModelGate()
        let provider = try BlockingCompletionModelProvider(
            model: model,
            answer: "parent answer",
            gate: gate
        )
        let harness = try ExecutorTestHarness(
            offset: 403,
            provider: provider,
            model: model,
            capabilityCeiling: parentCeiling
        )
        let spawner = DurableSubagentSpawner(
            executor: harness.executor,
            repository: harness.repository
        )
        try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(403))
        try await waitForGateEntry(gate)

        let equalCeiling = try RunCapabilityCeiling(
            authority: AgentAuthorityScope(
                capabilities: AgentCapabilitySet([.localRead, .localWrite])
            )
        )
        let childBudget = try attenuatedChildBudget(parent: harness.request.budget)
        let equalCeilingRequest = try SubagentSpawnRequest(
            parentRunID: harness.request.runID,
            parentRequestID: harness.request.id,
            requestingStepID: ExecutionStableID.step(runID: harness.request.runID, attempt: 1),
            childRunID: ExecutorTestID.run(404),
            role: "subagent",
            instruction: "child",
            outputRequirement: .text,
            modelPolicy: harness.request.modelPolicy,
            capabilityCeiling: equalCeiling,
            budget: childBudget,
            source: .parentAgent
        )
        do {
            _ = try await spawner.spawn(equalCeilingRequest)
            XCTFail("equal ceiling must be rejected")
        } catch SubagentSpawnError.ceilingNotStrictlyAttenuated {
        }

        let widenedBudget = try AgentBudget(
            limits: BudgetQuantities(
                Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                    ($0, harness.request.budget.limits[$0])
                })
            ),
            maximumThermalState: harness.request.budget.maximumThermalState,
            memoryPressureResponse: harness.request.budget.memoryPressureResponse
        )
        _ = try harness.request.budget.attenuating(to: widenedBudget) // equal is allowed by the budget type
        let widenedRequest = try SubagentSpawnRequest(
            parentRunID: harness.request.runID,
            parentRequestID: harness.request.id,
            requestingStepID: ExecutionStableID.step(runID: harness.request.runID, attempt: 1),
            childRunID: ExecutorTestID.run(405),
            role: "subagent",
            instruction: "child",
            outputRequirement: .text,
            modelPolicy: harness.request.modelPolicy,
            capabilityCeiling: try RunCapabilityCeiling(
                authority: AgentAuthorityScope(capabilities: AgentCapabilitySet([.localRead]))
            ),
            budget: try AgentBudget(
                limits: BudgetQuantities(
                    Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                        ($0, harness.request.budget.limits[$0] + 1)
                    })
                ),
                maximumThermalState: harness.request.budget.maximumThermalState,
                memoryPressureResponse: harness.request.budget.memoryPressureResponse
            ),
            source: .parentAgent
        )
        do {
            _ = try await spawner.spawn(widenedRequest)
            XCTFail("widened budget must be rejected")
        } catch SubagentSpawnError.budgetNotAttenuated {
        }
        await gate.release()
    }

    func testSubagentSpawnerRejectsTerminalParent() async throws {
        let model = try ExecutorTestModelDefinition(offset: 406)
        let harness = try ExecutorTestHarness(
            offset: 406,
            provider: try FixedCompletionModelProvider(model: model, answer: "done"),
            model: model
        )
        let spawner = DurableSubagentSpawner(
            executor: harness.executor,
            repository: harness.repository
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(406)
        )
        _ = try await collectTerminalEvents(from: try await harness.executor.attach(to: handleID))

        let request = try SubagentSpawnRequest(
            parentRunID: harness.request.runID,
            parentRequestID: harness.request.id,
            requestingStepID: ExecutionStableID.step(runID: harness.request.runID, attempt: 1),
            childRunID: ExecutorTestID.run(408),
            role: "subagent",
            instruction: "child",
            outputRequirement: .text,
            modelPolicy: harness.request.modelPolicy,
            capabilityCeiling: try RunCapabilityCeiling(
                authority: AgentAuthorityScope(capabilities: AgentCapabilitySet([.localRead]))
            ),
            budget: try attenuatedChildBudget(parent: harness.request.budget),
            source: .parentAgent
        )
        do {
            _ = try await spawner.spawn(request)
            XCTFail("terminal parent must be rejected")
        } catch SubagentSpawnError.parentTerminal {
        }
    }

    // MARK: - Parallel tool batches (real executor)

    func testParallelToolBatchExecutesConcurrentlyThenDeterministicBarrier() async throws {
        let model = try ExecutorTestModelDefinition(
            offset: 410,
            additionalCapabilities: [.multipleToolCalls]
        )
        let definitionA = try ExecutorTestToolDefinition(name: "parallel-a")
        let definitionB = try ExecutorTestToolDefinition(name: "parallel-b")
        let calls = [try definitionA.call(offset: 410), try definitionB.call(offset: 411)]
        let probe = ParallelOverlapProbe()
        let toolA = ParallelProbeTool(
            definition: definitionA,
            name: "a",
            mode: .complete("A"),
            probe: probe,
            delayMilliseconds: 200
        )
        let toolB = ParallelProbeTool(
            definition: definitionB,
            name: "b",
            mode: .complete("B"),
            probe: probe,
            delayMilliseconds: 200
        )
        let provider = try ParallelToolModelProvider(
            model: model,
            calls: calls,
            answer: "parallel answer"
        )
        let harness = try ExecutorTestHarness(
            offset: 410,
            provider: provider,
            model: model,
            toolDescriptors: [definitionA.descriptor, definitionB.descriptor],
            tools: PairToolCatalog(tools: [toolA, toolB]),
            explicitlyRequestedToolIDs: [
                definitionA.descriptor.id.logicalID,
                definitionB.descriptor.id.logicalID,
            ],
            parallelToolBatchLimit: 4
        )

        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(410)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()

        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.answer?.text, "parallel answer")
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 2)
        let overlapped = await probe.overlapped()
        XCTAssertTrue(overlapped, "the two tool bodies must execute concurrently")

        let outcomes = events.filter {
            if case .toolOutcomeRecorded = $0.payload.event { return true }
            return false
        }
        XCTAssertEqual(outcomes.count, 2)
        // The LAST waitingForModel is the deterministic barrier after the fan-out; the earlier one
        // belongs to the initial model pass before the batch was admitted.
        let barrierIndex = events.lastIndex { event in
            if case .statusChanged(let status) = event.payload.event,
               status.state == .waitingForModel
            {
                return true
            }
            return false
        }
        let barrier = try XCTUnwrap(barrierIndex)
        XCTAssertTrue(
            outcomes.allSatisfy { event in
                events.firstIndex(of: event)! < barrier
            },
            "the barrier transition must come after every fan-out outcome"
        )
    }

    func testParallelToolBatchWithFailedToolSynthesizesAfterBarrier() async throws {
        let model = try ExecutorTestModelDefinition(
            offset: 412,
            additionalCapabilities: [.multipleToolCalls]
        )
        let definitionA = try ExecutorTestToolDefinition(name: "parallel-ok")
        let definitionB = try ExecutorTestToolDefinition(name: "parallel-fail")
        let calls = [try definitionA.call(offset: 412), try definitionB.call(offset: 413)]
        let toolA = ParallelProbeTool(
            definition: definitionA,
            name: "ok",
            mode: .complete("A"),
            probe: ParallelOverlapProbe(),
            delayMilliseconds: 20
        )
        let toolB = ParallelProbeTool(
            definition: definitionB,
            name: "fail",
            mode: .fail,
            probe: ParallelOverlapProbe(),
            delayMilliseconds: 20
        )
        let provider = try ParallelToolModelProvider(
            model: model,
            calls: calls,
            answer: "answer after failure"
        )
        let harness = try ExecutorTestHarness(
            offset: 412,
            provider: provider,
            model: model,
            toolDescriptors: [definitionA.descriptor, definitionB.descriptor],
            tools: PairToolCatalog(tools: [toolA, toolB]),
            explicitlyRequestedToolIDs: [
                definitionA.descriptor.id.logicalID,
                definitionB.descriptor.id.logicalID,
            ],
            parallelToolBatchLimit: 4
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(412)
        )
        let events = try await collectTerminalEvents(
            from: try await harness.executor.attach(to: handleID)
        )
        let result = try await harness.executor.attach(to: handleID).result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.status.terminalReason, .completedWithFailures)
        XCTAssertEqual(result?.answer?.text, "answer after failure")
        // Barrier must have gone through synthesizing, not straight to waitingForModel.
        XCTAssertTrue(events.contains { event in
            if case .statusChanged(let status) = event.payload.event,
               status.state == .synthesizing
            {
                return true
            }
            return false
        })
    }

    func testParallelToolBatchWithUncertainToolStopsAtReconciliation() async throws {
        let model = try ExecutorTestModelDefinition(
            offset: 414,
            additionalCapabilities: [.multipleToolCalls]
        )
        let definitionA = try ExecutorTestToolDefinition(name: "parallel-safe")
        let definitionB = try ExecutorTestToolDefinition(
            name: "parallel-uncertain"
        )
        let calls = [try definitionA.call(offset: 414), try definitionB.call(offset: 415)]
        let toolA = ParallelProbeTool(
            definition: definitionA,
            name: "safe",
            mode: .complete("A"),
            probe: ParallelOverlapProbe(),
            delayMilliseconds: 20
        )
        let toolB = ParallelProbeTool(
            definition: definitionB,
            name: "uncertain",
            mode: .uncertain,
            probe: ParallelOverlapProbe(),
            delayMilliseconds: 20
        )
        let provider = try ParallelToolModelProvider(
            model: model,
            calls: calls,
            answer: "unused"
        )
        let harness = try ExecutorTestHarness(
            offset: 414,
            provider: provider,
            model: model,
            toolDescriptors: [definitionA.descriptor, definitionB.descriptor],
            tools: PairToolCatalog(tools: [toolA, toolB]),
            explicitlyRequestedToolIDs: [
                definitionA.descriptor.id.logicalID,
                definitionB.descriptor.id.logicalID,
            ],
            parallelToolBatchLimit: 4
        )
        let handleID = try await harness.executor.submit(
            harness.request,
            commandID: ExecutorTestID.command(414)
        )
        let handle = try await harness.executor.attach(to: handleID)
        let status = try await waitForStatus(.waitingForReconciliation, handle: handle)
        let reconciliationID = try XCTUnwrap(
            status.blockingReason,
            "reconciliation wait must carry the uncertain invocation"
        )
        guard case .reconciliation(let invocationID) = reconciliationID else {
            return XCTFail("expected reconciliation block, got \(reconciliationID)")
        }
        XCTAssertEqual(invocationID, calls[1].invocationID)
        // Resolve the uncertain outcome as failed-proof: synthesis pass then completed-with-failures.
        _ = try await handle.send(try AgentCommandEnvelope(payload: try AgentCommand(
            commandID: ExecutorTestID.command(415),
            runID: harness.request.runID,
            expectedRunStateVersion: status.stateVersion,
            action: .reconcile(
                invocationID: invocationID,
                decision: .failed
            ),
            issuedAt: try AgentTimestamp(rawValue: 50_000)
        )))
        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.status.terminalReason, .completedWithFailures)
        XCTAssertTrue(events.contains { event in
            if case .statusChanged(let value) = event.payload.event,
               value.state == .synthesizing
            {
                return true
            }
            return false
        })
    }

    // MARK: - Workflow orchestrator

    func testWorkflowRunsPhasesWritesRecordsAndHandoffs() async throws {
        let parent = makeWorkflowParent()
        let plan = try WorkflowPlan(
            goal: "Research and summarize",
            phases: [
                WorkflowPhasePlan(
                    sequence: 1,
                    title: "Research",
                    acceptanceCriteria: "Two sources gathered",
                    childInstructions: ["Find source A", "Find source B"],
                    handoff: WorkflowHandoff(
                        taskBrief: "Research the topic",
                        acceptanceCriteria: "Two sources gathered"
                    )
                ),
                WorkflowPhasePlan(
                    sequence: 2,
                    title: "Synthesize",
                    acceptanceCriteria: "One combined answer",
                    childInstructions: ["Combine the sources"],
                    handoff: WorkflowHandoff(
                        taskBrief: "Synthesize the sources",
                        acceptanceCriteria: "One combined answer"
                    )
                ),
            ]
        )
        let spawner = FakeSubagentSpawner(results: [
            .completed(answer: try AgentAnswer(text: "source A", artifacts: [makeArtifactReference(1)]),
                       usage: usage(input: 10, output: 2, tools: 1, active: 100)),
            .completed(answer: try AgentAnswer(text: "source B", artifacts: [makeArtifactReference(2)]),
                       usage: usage(input: 20, output: 3, tools: 2, active: 200)),
            .completed(answer: try AgentAnswer(text: "combined"),
                       usage: usage(input: 30, output: 4, tools: 0, active: 300)),
        ])
        let recording = InMemoryWorkflowRecording()
        let orchestrator = WorkflowOrchestrator(spawner: spawner, recording: recording)

        let summary = try await orchestrator.start(
            workflowID: UUID(),
            title: "Research task",
            plan: plan,
            parent: parent,
            ceilingAttenuator: { ceiling, _, _ in
                try ceiling.attenuating(
                    to: AgentAuthorityScope(
                        capabilities: AgentCapabilitySet([.networkRead])
                    ),
                    requireStrict: true
                )
            },
            budgetAttenuator: { budget, _, _ in
                try budget.attenuating(
                    to: try AgentBudget(
                        limits: BudgetQuantities(
                            Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                                ($0, $0 == .modelAttempts ? 2 : budget.limits[$0])
                            })
                        ),
                        maximumThermalState: budget.maximumThermalState,
                        memoryPressureResponse: budget.memoryPressureResponse
                    ),
                    requireStrict: true
                )
            }
        )

        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(summary.phases.count, 2)
        XCTAssertEqual(summary.phases[0].status, .completed)
        XCTAssertEqual(summary.phases[0].childRunIDs.count, 2)
        XCTAssertEqual(summary.phases[0].stats.subagentCount, 2)
        XCTAssertEqual(summary.phases[0].completedChildCount, 2)
        XCTAssertEqual(summary.phases[0].stats.inputTokens, 30)
        XCTAssertEqual(summary.phases[0].outputArtifactReferences.count, 2)
        XCTAssertEqual(summary.phases[1].status, .completed)
        XCTAssertEqual(summary.phases[1].completedChildCount, 1)
        XCTAssertEqual(summary.aggregated.subagentCount, 3)
        XCTAssertEqual(summary.aggregated.toolInvocationCount, 3)
        XCTAssertEqual(summary.completedPhaseCount, 2)
        XCTAssertEqual(summary.totalPhaseCount, 2)
        XCTAssertEqual(summary.finalAnswer, "combined")
        let handoff = try XCTUnwrap(summary.phases[0].handoff)
        XCTAssertEqual(handoff.upstreamArtifactReferences.count, 2)
        XCTAssertTrue(handoff.taskBrief.contains("Synthesize"))
        XCTAssertTrue(handoff.keyDecisions.contains("source A"))
        XCTAssertEqual(spawner.spawnedRequests.count, 3)
        // Live progress: the store must have saved after each child, not only at phase boundaries.
        let snapshots = await recording.savedSnapshots
        XCTAssertTrue(snapshots.contains { $0.aggregated.subagentCount == 1
            && $0.phases[0].completedChildCount == 1 })
        XCTAssertTrue(snapshots.contains { $0.aggregated.subagentCount == 2
            && $0.phases[0].completedChildCount == 2 })
    }

    func testWorkflowFailsWhenChildFails() async throws {
        let parent = makeWorkflowParent()
        let plan = try WorkflowPlan(
            goal: "Single phase",
            phases: [
                WorkflowPhasePlan(
                    sequence: 1,
                    title: "Phase",
                    acceptanceCriteria: "Success",
                    childInstructions: ["Do it"]
                ),
            ]
        )
        let spawner = FakeSubagentSpawner(results: [
            .failed(
                failure: try AgentFailure(
                    code: "test.child-failed",
                    classification: .permanent,
                    safeMessage: "child failed",
                    retryAdvice: .never,
                    externalEffect: .confirmedNone,
                    requiredUserAction: .none,
                    redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
                ),
                usage: .zero
            ),
        ])
        let recording = InMemoryWorkflowRecording()
        let orchestrator = WorkflowOrchestrator(spawner: spawner, recording: recording)

        do {
            _ = try await orchestrator.start(
                workflowID: UUID(),
                title: "Failing",
                plan: plan,
                parent: parent,
                ceilingAttenuator: { ceiling, _, _ in
                    try ceiling.attenuating(
                        to: AgentAuthorityScope(capabilities: AgentCapabilitySet([.localRead])),
                        requireStrict: true
                    )
                },
                budgetAttenuator: { budget, _, _ in
                    try budget.attenuating(
                        to: try AgentBudget(
                            limits: BudgetQuantities(
                                Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                                    ($0, $0 == .modelAttempts ? 2 : budget.limits[$0])
                                })
                            ),
                            maximumThermalState: budget.maximumThermalState,
                            memoryPressureResponse: budget.memoryPressureResponse
                        ),
                        requireStrict: true
                    )
                }
            )
            XCTFail("expected child failure")
        } catch WorkflowOrchestratorError.childFailed {
        }
        let lastSaved = await recording.lastSaved
        let summary = try XCTUnwrap(lastSaved)
        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.phases[0].status, .failed)
    }

    func testWorkflowAdvanceResumesFromDurableRecording() async throws {
        let parent = makeWorkflowParent()
        let plan = try WorkflowPlan(
            goal: "Two phases",
            phases: [
                WorkflowPhasePlan(
                    sequence: 1,
                    title: "First",
                    acceptanceCriteria: "First done",
                    childInstructions: ["First child"]
                ),
                WorkflowPhasePlan(
                    sequence: 2,
                    title: "Second",
                    acceptanceCriteria: "Second done",
                    childInstructions: ["Second child"]
                ),
            ]
        )
        let workflowID = UUID()
        let spawner = FakeSubagentSpawner(results: [
            .completed(answer: try AgentAnswer(text: "first"), usage: usage(input: 1, output: 1, tools: 0, active: 1)),
        ])
        let recording = InMemoryWorkflowRecording()
        var seeded = WorkflowSummary(
            id: workflowID,
            title: "Resumable",
            plan: plan,
            rootRunID: parent.runID,
            phases: [
                WorkflowPhaseRecord(
                    sequence: 1,
                    title: "First",
                    status: .completed,
                    acceptanceCriteria: "First done",
                    endTime: Date(),
                    childRunIDs: [ExecutorTestID.run(431)],
                    stats: WorkflowAggregatedStats(
                        subagentCount: 1,
                        elapsedMilliseconds: 100,
                        inputTokens: 10,
                        outputTokens: 2,
                        toolInvocationCount: 1
                    )
                ),
                WorkflowPhaseRecord(
                    sequence: 2,
                    title: "Second",
                    acceptanceCriteria: "Second done"
                ),
            ]
        )
        seeded.refreshAggregates()
        try await recording.save(seeded)
        let orchestrator = WorkflowOrchestrator(spawner: spawner, recording: recording)

        let summary = try await orchestrator.advance(
            workflowID: workflowID,
            plan: plan,
            parent: parent,
            ceilingAttenuator: { ceiling, _, _ in
                try ceiling.attenuating(
                    to: AgentAuthorityScope(capabilities: AgentCapabilitySet([.localRead])),
                    requireStrict: true
                )
            },
            budgetAttenuator: { budget, _, _ in
                try budget.attenuating(
                    to: try AgentBudget(
                        limits: BudgetQuantities(
                            Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                                ($0, $0 == .modelAttempts ? 2 : budget.limits[$0])
                            })
                        ),
                        maximumThermalState: budget.maximumThermalState,
                        memoryPressureResponse: budget.memoryPressureResponse
                    ),
                    requireStrict: true
                )
            }
        )

        XCTAssertEqual(summary.phases[1].status, .completed)
        XCTAssertEqual(summary.status, .running, "one more advance is needed for the final phase gate")
        let final = try await orchestrator.advance(
            workflowID: workflowID,
            plan: plan,
            parent: parent,
            ceilingAttenuator: { ceiling, _, _ in
                try ceiling.attenuating(
                    to: AgentAuthorityScope(capabilities: AgentCapabilitySet([.localRead])),
                    requireStrict: true
                )
            },
            budgetAttenuator: { budget, _, _ in
                try budget.attenuating(
                    to: try AgentBudget(
                        limits: BudgetQuantities(
                            Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                                ($0, $0 == .modelAttempts ? 2 : budget.limits[$0])
                            })
                        ),
                        maximumThermalState: budget.maximumThermalState,
                        memoryPressureResponse: budget.memoryPressureResponse
                    ),
                    requireStrict: true
                )
            }
        )
        XCTAssertEqual(final.status, .completed)
        XCTAssertEqual(final.aggregated.subagentCount, 2)
    }

    func testStructuredPlanDecodesAndSchemaValidates() throws {
        let json: JSONValue = .object([
            "goal": .string("Deploy Kimi K3 on iPhone 16 Pro"),
            "phases": .array([
                .object([
                    "sequence": .integer(1),
                    "title": .string("Explore"),
                    "acceptanceCriteria": .string("Facts gathered"),
                    "childInstructions": .array([
                        .string("Search iPhone 16 Pro RAM"),
                        .string("Search Kimi K3 quantizations"),
                    ]),
                ]),
                .object([
                    "sequence": .integer(2),
                    "title": .string("Plan"),
                    "acceptanceCriteria": .string("Plan written"),
                    "childInstructions": .array([
                        .string("Write the deployment plan"),
                    ]),
                ]),
            ]),
        ])
        let plan = try WorkflowPlan.decode(from: json)
        XCTAssertEqual(plan.phases.count, 2)
        XCTAssertEqual(plan.phases[0].childInstructions.count, 2)
        XCTAssertEqual(plan.phases[1].childInstructions.count, 1)

        let data = try CanonicalJSON(json).data
        let instance = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        XCTAssertTrue(try WorkflowPlanSchema.document.validates(instance: instance))
    }

    func testFallbackQualityLoopAuditFeedsReviseAndDeliverFinalPlan() async throws {
        let parent = makeWorkflowParent()
        let plan = try WorkflowPlan.fallback(goal: "Deploy Kimi K3 on iPhone 16 Pro")
        XCTAssertEqual(plan.phases.count, 6)
        XCTAssertEqual(
            plan.phases.map(\.title),
            ["Explore", "Plan", "Audit", "Revise", "Verify", "Deliver"]
        )

        let spawner = FakeSubagentSpawner(results: [
            .completed(answer: try AgentAnswer(text: "facts gathered"),
                       usage: usage(input: 1, output: 1, tools: 1, active: 1)),
            .completed(answer: try AgentAnswer(text: "plan draft"),
                       usage: usage(input: 1, output: 1, tools: 0, active: 1)),
            .completed(answer: try AgentAnswer(text: "finding: memory risk"),
                       usage: usage(input: 1, output: 1, tools: 1, active: 1)),
            .completed(answer: try AgentAnswer(text: "finding: approval risk"),
                       usage: usage(input: 1, output: 1, tools: 1, active: 1)),
            .completed(answer: try AgentAnswer(text: "revised plan addressing findings"),
                       usage: usage(input: 1, output: 1, tools: 0, active: 1)),
            .completed(answer: try AgentAnswer(text: "verification passed"),
                       usage: usage(input: 1, output: 1, tools: 0, active: 1)),
            .completed(answer: try AgentAnswer(text: "FINAL DELIVERED PLAN"),
                       usage: usage(input: 1, output: 1, tools: 1, active: 1)),
        ])
        let recording = InMemoryWorkflowRecording()
        let orchestrator = WorkflowOrchestrator(spawner: spawner, recording: recording)

        let summary = try await orchestrator.start(
            workflowID: UUID(),
            title: "Kimi K3 study",
            plan: plan,
            conversationID: UUID(),
            parent: parent,
            ceilingAttenuator: { ceiling, _, _ in
                try ceiling.attenuating(
                    to: AgentAuthorityScope(
                        capabilities: AgentCapabilitySet([.networkRead])
                    ),
                    requireStrict: true
                )
            },
            budgetAttenuator: { budget, _, _ in
                try budget.attenuating(
                    to: try AgentBudget(
                        limits: BudgetQuantities(
                            Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                                ($0, $0 == .toolInvocations ? 2 : budget.limits[$0])
                            })
                        ),
                        maximumThermalState: budget.maximumThermalState,
                        memoryPressureResponse: budget.memoryPressureResponse
                    ),
                    requireStrict: true
                )
            }
        )

        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(summary.phases.count, 6)
        XCTAssertTrue(summary.phases.allSatisfy { $0.status == .completed })
        XCTAssertEqual(summary.aggregated.subagentCount, 7)
        XCTAssertEqual(summary.aggregated.toolInvocationCount, 4)
        // The final answer is the DELIVER phase output, not the audit's findings.
        XCTAssertEqual(summary.finalAnswer, "FINAL DELIVERED PLAN")
        XCTAssertEqual(summary.completedPhaseCount, 6)
        XCTAssertEqual(summary.completedSubagentCount, 7)
        XCTAssertEqual(summary.totalSubagentCount, 7)

        // The Revise child (index 4 of spawned requests) received BOTH audit findings via the
        // upstream handoff — the harness actually fixes the plan after auditing it.
        XCTAssertEqual(spawner.spawnedRequests.count, 7)
        let reviseRequest = spawner.spawnedRequests[4]
        XCTAssertTrue(reviseRequest.instruction.contains("finding: memory risk"))
        XCTAssertTrue(reviseRequest.instruction.contains("finding: approval risk"))
    }

    // MARK: - Fixtures

    private func makeWorkflowParent() -> WorkflowParentContext {
        WorkflowParentContext(
            runID: ExecutorTestID.run(420),
            requestID: ExecutorTestID.request(420),
            requestingStepID: ExecutionStableID.step(runID: ExecutorTestID.run(420), attempt: 1),
            capabilityCeiling: try! RunCapabilityCeiling(
                authority: AgentAuthorityScope(
                    capabilities: AgentCapabilitySet([.networkRead, .localRead, .localWrite])
                )
            ),
            budget: try! AgentBudget.firstReleaseDefaults(
                contextTokensPerAttempt: 4_096,
                outputTokens: 1_024,
                peakMemoryBytes: 1_073_741_824
            ),
            modelPolicy: try! AgentModelPolicy(
                localOnly: true,
                allowedSelections: [try! ExecutorTestModelDefinition(offset: 420).selection],
                strategy: .pinned,
                requiredCapabilities: .init([])
            ),
            approvalMode: .safePreset
        )
    }

    private func attenuatedChildBudget(parent: AgentBudget) throws -> AgentBudget {
        let values = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
            ($0, parent.limits[$0])
        })
        var attenuated = values
        attenuated[.modelAttempts] = 2
        attenuated[.activeMilliseconds] = parent.limits[.activeMilliseconds] / 2
        let child = try AgentBudget(
            limits: BudgetQuantities(attenuated),
            maximumThermalState: parent.maximumThermalState,
            memoryPressureResponse: parent.memoryPressureResponse
        )
        _ = try parent.attenuating(to: child, requireStrict: true)
        return child
    }

    private func makeArtifactReference(_ value: Int) -> ArtifactReference {
        try! ArtifactReference(
            id: ArtifactID(rawValue: ExecutorTestID.uuid(value)),
            contentDigest: StableDigest.sha256(Data("artifact-\(value)".utf8)),
            byteCount: 8,
            mimeType: "text/plain",
            semanticType: "test.artifact",
            provenance: ArtifactProvenance(runID: ExecutorTestID.run(420)),
            createdAt: AgentTimestamp(rawValue: 50_000),
            retentionPolicy: .conversation,
            locator: try! ArtifactLocator(
                kind: .managedRelativePath,
                value: "workflow-test/artifact-\(value).txt"
            ),
            sensitivity: .publicMetadata,
            integrityStatus: .verified
        )
    }

    private func usage(
        input: UInt64,
        output: UInt64,
        tools: UInt64,
        active: UInt64
    ) -> AgentUsage {
        AgentUsage(quantities: BudgetQuantities([
            .inputTokens: input,
            .outputTokens: output,
            .toolInvocations: tools,
            .activeMilliseconds: active,
        ]))
    }

    private func waitForGateEntry(_ gate: BlockingModelGate) async throws {
        for _ in 0 ..< 1_000 {
            if await gate.hasEntered() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ExecutorIntegrationTestError.timeout
    }
}

// MARK: - Parallel tool fixtures

actor ParallelOverlapProbe {
    struct Interval: Sendable {
        let name: String
        let start: Date
        let end: Date
    }

    private var starts: [String: Date] = [:]
    private var intervals: [Interval] = []

    func enter(_ name: String) -> Date {
        let now = Date()
        starts[name] = now
        return now
    }

    func exit(_ name: String) -> Date {
        let now = Date()
        if let start = starts[name] {
            intervals.append(Interval(name: name, start: start, end: now))
        }
        return now
    }

    func overlapped() -> Bool {
        for lhs in intervals {
            for rhs in intervals where lhs.name != rhs.name {
                if lhs.start < rhs.end && rhs.start < lhs.end { return true }
            }
        }
        return false
    }
}

enum ParallelProbeMode: Sendable {
    case complete(String)
    case fail
    case uncertain
}

struct ParallelProbeTool: ToolV2, Sendable {
    let descriptor: AgentToolDescriptor
    let name: String
    let mode: ParallelProbeMode
    let probe: ParallelOverlapProbe
    let delayMilliseconds: UInt64

    init(
        definition: ExecutorTestToolDefinition,
        name: String,
        mode: ParallelProbeMode,
        probe: ParallelOverlapProbe,
        delayMilliseconds: UInt64
    ) {
        descriptor = definition.descriptor
        self.name = name
        self.mode = mode
        self.probe = probe
        self.delayMilliseconds = delayMilliseconds
    }

    func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation {
        let plan = try ExternalOperationPlan(
            kind: .localPure,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments,
            destination: nil,
            dataCategories: [],
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: [.localPure],
            requiredCapabilities: AgentCapabilitySet([]),
            maximumRequestBytes: 1_024,
            maximumResponseBytes: 1_024,
            timeoutMilliseconds: descriptor.timeoutPolicy.maximumMilliseconds,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: "",
            descriptorID: descriptor.id.description,
            schemaDigest: descriptor.id.schemaDigest,
            trustRevision: descriptor.id.trustRevision
        )
        return try PreparedToolInvocation(request: request, context: context, plan: plan)
    }

    func execute(
        prepared: AuthorizedToolInvocation,
        context: ToolExecutionContext
    ) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                _ = await probe.enter(name)
                try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
                _ = await probe.exit(name)
                switch mode {
                case .complete(let text):
                    continuation.yield(.completed(try ToolResultCollection([
                        .text(try ToolTextResult(text)),
                    ])))
                case .fail:
                    continuation.yield(.failed(try AgentFailure(
                        code: "test.parallel-failed",
                        classification: .permanent,
                        safeMessage: "parallel tool failed",
                        retryAdvice: .never,
                        externalEffect: .confirmedNone,
                        requiredUserAction: .none,
                        redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
                    )))
                case .uncertain:
                    continuation.yield(.failed(try AgentFailure(
                        code: "test.parallel-uncertain",
                        classification: .potentiallySideEffecting,
                        safeMessage: "parallel tool crossed an uncertain boundary",
                        retryAdvice: .never,
                        externalEffect: .uncertain,
                        requiredUserAction: .reconcile,
                        redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
                    )))
                }
                continuation.finish()
            }
        }
    }
}

actor ParallelToolModelScript {
    private var passes = 0

    func next(calls: [ProposedToolCall], answer: AgentAnswer) -> AgentAction {
        passes += 1
        return passes == 1 ? .callTools(calls) : .finalAnswer(answer)
    }
}

struct ParallelToolModelProvider: AgentModelProvider, Sendable {
    let descriptor: AgentModelProviderDescriptor
    let capabilitiesValue: AgentModelCapabilities
    let calls: [ProposedToolCall]
    let answer: AgentAnswer
    let script: ParallelToolModelScript

    init(
        model: ExecutorTestModelDefinition,
        calls: [ProposedToolCall],
        answer: String
    ) throws {
        descriptor = model.descriptor
        capabilitiesValue = model.capabilities
        self.calls = calls
        self.answer = try AgentAnswer(text: answer)
        script = ParallelToolModelScript()
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
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let action = await script.next(calls: calls, answer: answer)
        let completion = try AgentModelCompletion(
            action: action,
            usage: modelUsage(input: 11, output: 2, milliseconds: 6, memory: 80)
        )
        try await emitter.emit(.completed(completion), responseBytes: 12)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}

struct PairToolCatalog: ExecutableToolCatalog, Sendable {
    let tools: [any ToolV2]

    func localSnapshot() async throws -> ToolCatalogSnapshot {
        try ToolCatalogSnapshot(revision: 1, descriptors: tools.map(\.descriptor))
    }

    func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)? {
        tools.first { $0.descriptor.id == descriptorID }
    }
}

// MARK: - Workflow fixtures

final class FakeSubagentSpawner: SubagentSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SubagentOutcome]
    private var spawned: [SubagentSpawnRequest] = []

    init(results: [SubagentOutcome]) {
        self.results = results
    }

    var spawnedRequests: [SubagentSpawnRequest] {
        lock.withLock { spawned }
    }

    func spawn(_ request: SubagentSpawnRequest) async throws -> AgentExecutionHandleID {
        lock.withLock {
            spawned.append(request)
        }
        return AgentExecutionHandleID(rawValue: ExecutorTestID.uuid(900))
    }

    func collect(_ handleID: AgentExecutionHandleID) async throws -> SubagentResult {
        let outcome = lock.withLock { () -> SubagentOutcome in
            guard !results.isEmpty else {
                return .cancelled
            }
            return results.removeFirst()
        }
        return SubagentResult(
            runID: ExecutorTestID.run(430),
            handleID: handleID,
            outcome: outcome
        )
    }
}

actor InMemoryWorkflowRecording: WorkflowRecording {
    private var summaries: [UUID: WorkflowSummary] = [:]
    private(set) var lastSaved: WorkflowSummary?
    private(set) var savedSnapshots: [WorkflowSummary] = []

    func load(workflowID: UUID) async throws -> WorkflowSummary? {
        summaries[workflowID]
    }

    func save(_ summary: WorkflowSummary) async throws {
        summaries[summary.id] = summary
        lastSaved = summary
        savedSnapshots.append(summary)
    }
}
