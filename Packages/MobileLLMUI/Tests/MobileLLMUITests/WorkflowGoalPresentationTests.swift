// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI

// TEST-ID: AHT-DYNAMIC-001
@MainActor
final class WorkflowGoalPresentationTests: XCTestCase {
    func testPlannedDependenciesAndReadyResultReflectDifferentRuntimeStates() throws {
        var graph = try graph()
        var goal = try presentation(graph)
        var dynamic = DynamicWorkflowPresentation(runID: WorkflowRunID(), state: .running, goal: goal)
        XCTAssertEqual(WorkflowGoalDisplay.levels(goal), ["source": 0, "review": 1])
        XCTAssertEqual(WorkflowGoalDisplay.status(graph.tasks[0], goal: goal, dynamic: dynamic, attached: true), "Ready")
        XCTAssertEqual(WorkflowGoalDisplay.status(graph.tasks[1], goal: goal, dynamic: dynamic, attached: true), "Waiting for inputs")
        let source = try call(graph.tasks[0], output: "source:1")
        try graph.claim(taskID: "source", expectedRevision: 1, call: source)
        try graph.settle(call: source, outcome: .completed(value: .inline(CanonicalJSON(.string("PRIVATE_FULL_REPORT"))), usage: .zero))
        let review = try call(graph.tasks[1], inputs: ["source:1"], output: "review:1")
        try graph.claim(taskID: "review", expectedRevision: 1, call: review)
        goal = try presentation(graph)
        let ready = child(review, status: .completed, prepared: 4, settled: 5)
        dynamic = DynamicWorkflowPresentation(runID: WorkflowRunID(), state: .running, childCalls: [ready], goal: goal)
        XCTAssertEqual(WorkflowGoalDisplay.status(graph.tasks[1], goal: goal, dynamic: dynamic, attached: true), "Result ready")
        XCTAssertEqual(WorkflowGoalDisplay.summary(goal), "2 tasks · 1 completed")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(goal), as: UTF8.self).contains("PRIVATE_FULL_REPORT"),
                       "The presentation cache must retain references rather than result bodies")

        let original = child(source, status: .completed, prepared: 1, settled: 2)
        let impostor = try call(graph.tasks[0], output: "source:1")
        let rejected = child(impostor, status: .failed, prepared: 3, settled: 3)
        XCTAssertEqual(WorkflowDisplay.inputs(for: ready, in: [original, rejected, ready], goal: goal).map(\.callID), [source.callID],
                       "A later rejected call cannot replace the exact source artifact")
    }

    func testViewingGoalNeverResumesAndExplicitUpdateIsSavedBeforeResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory)
        let id = UUID()
        let goal = try presentation(graph())
        try await store.save(WorkflowSummary(id: id, title: "Goal", status: .running,
            dynamic: DynamicWorkflowPresentation(runID: WorkflowRunID(), state: .paused, goal: goal)))
        var events: [String] = []
        store.goalUpdateHandler = { workflow, _, text in
            XCTAssertEqual(workflow, id); XCTAssertEqual(text, "Use the corrected limit."); events.append("saved")
        }
        store.dynamicResumeHandler = { _ in events.append("resumed") }
        _ = store.messageRecord(workflowID: id)
        XCTAssertTrue(events.isEmpty)
        try await store.updateGoal(workflowID: id, id: MessageID(), text: "Use the corrected limit.", resumeAfterSave: true)
        XCTAssertEqual(events, ["saved", "resumed"])
        XCTAssertTrue(store.actioningWorkflowIDs.isEmpty)
    }

    private func graph() throws -> WorkflowTaskGraph {
        var value = try WorkflowTaskGraph(objective: "Produce and review evidence.")
        try value.update([WorkflowTaskUpdate(id: "source", expectedRevision: 0, agent: "researcher", instruction: "Produce evidence"),
            WorkflowTaskUpdate(id: "review", expectedRevision: 0, agent: "reviewer", instruction: "Review evidence", dependencies: ["source"])], expectedRevision: 1)
        return value
    }
    private func presentation(_ graph: WorkflowTaskGraph) throws -> WorkflowGoalPresentation {
        WorkflowGoalPresentation(graph: graph, budget: try AgentBudget.firstReleaseDefaults(
            contextTokensPerAttempt: 4096, outputTokens: 1024, peakMemoryBytes: 1024), usage: .zero)
    }
    private func call(_ task: WorkflowTaskNode, inputs: [String] = [], output: String) throws -> WorkflowAgentCallV1 {
        try WorkflowAgentCallV1(callID: WorkflowAgentCallID(), ordinal: 1, attempt: 1,
            prefixKey: StableDigest.sha256(Data(output.utf8)), promptDigest: StableDigest.sha256(Data(task.instruction.utf8)),
            options: WorkflowAgentOptionsV1(task: WorkflowTaskDescriptorV1(taskID: task.id, instruction: task.instruction,
                inputArtifactIDs: inputs, outputArtifactID: output, expectedRevision: task.revision), sessionKey: task.agent), childRunID: AgentRunID())
    }
    private func child(_ call: WorkflowAgentCallV1, status: DynamicWorkflowChildStatus, prepared: UInt64, settled: UInt64) -> DynamicWorkflowChildPresentation {
        DynamicWorkflowChildPresentation(callID: call.callID, ordinal: call.ordinal, attempt: call.attempt,
            childRunID: call.childRunID, status: status, task: call.options.task, preparedSequence: prepared, settledSequence: settled)
    }
}
