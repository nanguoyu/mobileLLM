// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

// TEST-ID: AHT-DYNAMIC-001
final class WorkflowTaskGraphTests: XCTestCase {
    func testCycleAndStaleAssignmentRejectionLeaveTheWholeGraphUnchanged() throws {
        var graph = try WorkflowTaskGraph(objective: "Produce a checked maintenance plan.")
        try graph.update([update("source"), update("consumer", dependencies: ["source"])], expectedRevision: 1)
        let saved = graph
        XCTAssertThrowsError(try graph.update([update("source", revision: 1, dependencies: ["consumer"])], expectedRevision: 2)) {
            XCTAssertEqual($0 as? WorkflowTaskGraphError, .cycle)
        }
        XCTAssertEqual(graph, saved)
        XCTAssertThrowsError(try graph.update([update("source", revision: 0)], expectedRevision: 2))
        XCTAssertEqual(graph, saved)
        XCTAssertThrowsError(try graph.update([update("missing", dependencies: ["absent"])], expectedRevision: 2))
        XCTAssertEqual(graph, saved)
    }

    func testClaimOwnershipAndReopeningRetainOriginalArtifactsAndInvalidateConsumers() throws {
        var graph = try WorkflowTaskGraph(objective: "Build from verified source material.")
        try graph.update([update("source"), update("consumer", dependencies: ["source"])], expectedRevision: 1)
        let source = try call(graph.tasks[0], output: "source:v1")
        try graph.claim(taskID: "source", expectedRevision: 1, call: source)
        XCTAssertThrowsError(try graph.claim(taskID: "source", expectedRevision: 1, call: source))
        XCTAssertThrowsError(try graph.setGoalState(.completed, reason: "Looks done"))
        try graph.settle(call: source, outcome: completed("Exact original source bytes"))
        let consumer = try call(graph.tasks[1], inputs: ["source:v1"], output: "consumer:v1")
        try graph.claim(taskID: "consumer", expectedRevision: 1, call: consumer)
        try graph.update([update("source", revision: graph.tasks[0].revision)], expectedRevision: graph.revision)
        try graph.settle(call: consumer, outcome: completed("Based on source version 1"))
        XCTAssertEqual(graph.tasks[1].state, .needsReview)
        XCTAssertNil(graph.tasks[1].outputArtifactID)
        XCTAssertEqual(graph.artifacts[1].inputArtifactIDs, ["source:v1"])
        XCTAssertEqual(graph.artifacts[0].value, .inline(try CanonicalJSON(.string("Exact original source bytes"))))
        XCTAssertEqual(graph.readyTasks.map(\.id), ["source"])
        XCTAssertThrowsError(try graph.setGoalState(.completed, reason: nil))
    }

    func testGoalAmendmentAndModelUpdatesCannotRemoveOriginalRequirements() throws {
        var graph = try WorkflowTaskGraph(objective: "Use a seven-day retention window.")
        try graph.update([update("required")], expectedRevision: 1)
        let amendment = WorkflowGoalAmendment(id: MessageID(), text: "Change retention to fourteen days.", acceptedAt: AgentTimestamp(rawValue: 1))
        try graph.amend(amendment)
        let revision = graph.revision
        try graph.amend(amendment)
        XCTAssertEqual(graph.revision, revision)
        XCTAssertEqual(graph.objective, "Use a seven-day retention window.")
        XCTAssertThrowsError(try graph.update([WorkflowTaskUpdate(id: "required", expectedRevision: 1,
            agent: "owner", instruction: "Skip it", required: false)], expectedRevision: graph.revision))
        try graph.setGoalState(.blocked, reason: "Awaiting a missing input")
        XCTAssertEqual(graph.state, .blocked)
        XCTAssertEqual(graph.unfinishedRequiredTasks.map(\.id), ["required"])
        try graph.setGoalState(.active, reason: "Explicit user resume")
        XCTAssertEqual(graph.amendments, [amendment])
    }

    private func update(_ id: String, revision: UInt64 = 0, dependencies: [String] = []) -> WorkflowTaskUpdate {
        WorkflowTaskUpdate(id: id, expectedRevision: revision, agent: id, instruction: "Complete " + id, dependencies: dependencies)
    }

    private func call(_ task: WorkflowTaskNode, inputs: [String] = [], output: String) throws -> WorkflowAgentCallV1 {
        try WorkflowAgentCallV1(callID: WorkflowAgentCallID(), ordinal: 1, attempt: 1,
            prefixKey: StableDigest.sha256(Data(output.utf8)), promptDigest: StableDigest.sha256(Data(task.instruction.utf8)),
            options: WorkflowAgentOptionsV1(task: WorkflowTaskDescriptorV1(taskID: task.id, instruction: task.instruction,
                inputArtifactIDs: inputs, outputArtifactID: output, expectedRevision: task.revision), sessionKey: task.agent), childRunID: AgentRunID())
    }

    private func completed(_ text: String) throws -> WorkflowAgentOutcomeV1 {
        .completed(value: .inline(try CanonicalJSON(.string(text))), usage: .zero)
    }
}
