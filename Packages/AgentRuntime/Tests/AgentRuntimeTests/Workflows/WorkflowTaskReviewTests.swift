// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import XCTest

// TEST-ID: AHT-DYNAMIC-001
final class WorkflowTaskReviewTests: XCTestCase {
    func testParallelReviewFailureReopensOnlyItsProducerAndKeepsOtherAcceptedBranch() throws {
        var graph = try WorkflowTaskGraph(objective: "Produce two checked artifacts.")
        try graph.update([work("a"), work("b"), review("check-a", target: "a"), review("check-b", target: "b")], expectedRevision: 1)
        XCTAssertEqual(Set(graph.readyTasks.map(\.id)), ["a", "b"])
        _ = try complete("a", graph: &graph)
        _ = try complete("b", graph: &graph)
        XCTAssertEqual(Set(graph.readyTasks.map(\.id)), ["check-a", "check-b"])
        let checkA = try complete("check-a", graph: &graph)
        let checkB = try complete("check-b", graph: &graph)
        try graph.recordReview(callID: checkB.callID, report: report(.pass), toolEvidence: [], goalAmendmentCount: 0)
        try graph.recordReview(callID: checkA.callID, report: report(.revise), toolEvidence: [], goalAmendmentCount: 0)
        XCTAssertEqual(graph.tasks.first { $0.id == "a" }?.state, .pending)
        XCTAssertEqual(graph.tasks.first { $0.id == "check-a" }?.state, .needsReview)
        XCTAssertEqual(graph.tasks.first { $0.id == "b" }?.state, .completed)
        XCTAssertEqual(graph.tasks.first { $0.id == "check-b" }?.state, .completed)
        XCTAssertEqual(graph.artifacts.count, 4)
        XCTAssertEqual(graph.tasks.first { $0.id == "a" }?.artifactInputs?.count, 2)
        XCTAssertThrowsError(try graph.requireAcceptedReviews())
        _ = try complete("a", graph: &graph)
        let fresh = try complete("check-a", graph: &graph)
        try graph.recordReview(callID: fresh.callID, report: report(.pass), toolEvidence: [], goalAmendmentCount: 0)
        XCTAssertNoThrow(try graph.requireAcceptedReviews())
        XCTAssertEqual(graph.artifacts.count, 6)
        XCTAssertEqual(graph.artifacts.first { $0.callID == checkA.callID }?.reviewResult?.status, .revise)
    }

    func testClaimsCannotReplaceMissingToolExecutionOrUnreviewedRequiredWork() throws {
        var graph = try WorkflowTaskGraph(objective: "Check the calculation using Calculator.")
        try graph.update([work("a"), review("check-a", target: "a", tools: ["builtin.calculator"])], expectedRevision: 1)
        _ = try complete("a", graph: &graph)
        let call = try complete("check-a", graph: &graph)
        try graph.recordReview(callID: call.callID, report: report(.pass), toolEvidence: [], goalAmendmentCount: 0)
        XCTAssertEqual(graph.artifacts.last?.reviewResult?.status, .blocked)
        XCTAssertEqual(graph.artifacts.last?.reviewResult?.missingTools, ["builtin.calculator"])
        XCTAssertThrowsError(try graph.requireAcceptedReviews())
        XCTAssertEqual(graph.tasks.first?.state, .completed, "A capability blocker must not trigger pointless producer retries")

        var partial = try WorkflowTaskGraph(objective: "Check both outputs.")
        try partial.update([work("a"), work("b"), review("check-a", target: "a", dependencies: ["a", "b"])], expectedRevision: 1)
        _ = try complete("a", graph: &partial); _ = try complete("b", graph: &partial)
        let partialCheck = try complete("check-a", graph: &partial)
        try partial.recordReview(callID: partialCheck.callID, report: report(.pass), toolEvidence: [], goalAmendmentCount: 0)
        XCTAssertThrowsError(try partial.requireAcceptedReviews(), "Merely reading B is not a declared review of B")
    }

    func testReviewCriteriaAndIndependentReviewerCannotBeSilentlyReplaced() throws {
        var graph = try WorkflowTaskGraph(objective: "Independently inspect the result.")
        try graph.update([work("a"), review("check-a", target: "a")], expectedRevision: 1)
        let saved = graph
        XCTAssertThrowsError(try graph.update([work("check-a", revision: 1)], expectedRevision: graph.revision))
        XCTAssertThrowsError(try graph.update([WorkflowTaskUpdate(id: "a", expectedRevision: 1, agent: "check-a", instruction: "Self-review")], expectedRevision: graph.revision))
        XCTAssertEqual(graph, saved)
        _ = try complete("a", graph: &graph)
        let call = try complete("check-a", graph: &graph)
        XCTAssertThrowsError(try graph.recordReview(callID: call.callID, report: .init(checks: []), toolEvidence: [], goalAmendmentCount: 0))
        XCTAssertThrowsError(try graph.requireAcceptedReviews())
    }

    func testTwoAutomaticCorrectionsAreBoundedAndOldReviewCannotAcceptAnAmendment() throws {
        var graph = try WorkflowTaskGraph(objective: "Revise within the same goal budget.")
        try graph.update([work("a"), review("check-a", target: "a")], expectedRevision: 1)
        for _ in 0..<3 {
            _ = try complete("a", graph: &graph)
            let review = try complete("check-a", graph: &graph)
            try graph.recordReview(callID: review.callID, report: report(.revise), toolEvidence: [], goalAmendmentCount: 0)
        }
        XCTAssertTrue(graph.readyTasks.isEmpty)
        XCTAssertEqual(graph.tasks.first?.reviewCorrectionBudget?.attempts, 2)
        XCTAssertThrowsError(try graph.requireAcceptedReviews())
        let restored = try JSONDecoder().decode(WorkflowTaskGraph.self, from: JSONEncoder().encode(graph))
        XCTAssertEqual(restored, graph)

        var changed = try WorkflowTaskGraph(objective: "Check the current requirement.")
        try changed.update([work("a"), review("check-a", target: "a")], expectedRevision: 1)
        _ = try complete("a", graph: &changed)
        let old = try complete("check-a", graph: &changed)
        try changed.amend(.init(id: MessageID(), text: "Use the revised requirement.", acceptedAt: AgentTimestamp(rawValue: 1)))
        try changed.recordReview(callID: old.callID, report: report(.pass), toolEvidence: [], goalAmendmentCount: 0)
        XCTAssertEqual(changed.tasks.last?.state, .needsReview)
        XCTAssertThrowsError(try changed.requireAcceptedReviews())
    }

    func testAnAmendmentInvalidatesAnAlreadyAcceptedReviewWithoutErasingItsEvidence() throws {
        var graph = try WorkflowTaskGraph(objective: "Use the current policy.")
        try graph.update([work("a"), review("check-a", target: "a")], expectedRevision: 1)
        _ = try complete("a", graph: &graph)
        let checked = try complete("check-a", graph: &graph)
        try graph.recordReview(callID: checked.callID, report: report(.pass), toolEvidence: [], goalAmendmentCount: 0)
        XCTAssertNoThrow(try graph.requireAcceptedReviews())
        let original = graph.artifacts.last
        try graph.amend(.init(id: MessageID(), text: "Apply the new policy instead.", acceptedAt: AgentTimestamp(rawValue: 2)))
        XCTAssertEqual(graph.readyTasks.map(\.id), ["check-a"])
        XCTAssertEqual(graph.artifacts.last, original)
        XCTAssertThrowsError(try graph.requireAcceptedReviews())
    }

    private func work(_ id: String, revision: UInt64 = 0) -> WorkflowTaskUpdate {
        .init(id: id, expectedRevision: revision, agent: id, instruction: "Produce " + id)
    }
    private func review(_ id: String, target: String, tools: [String] = [], dependencies: [String]? = nil) -> WorkflowTaskUpdate {
        .init(id: id, expectedRevision: 0, agent: id, instruction: "Check " + target,
            dependencies: dependencies ?? [target], review: .init(criteria: [
                .init(id: "correctness", requirement: "Preserve the supplied requirement", targetTaskIDs: [target])
            ], requiredTools: tools))
    }
    private func report(_ status: WorkflowReviewStatus) -> WorkflowReviewReport {
        .init(checks: [.init(id: "correctness", status: status, detail: status == .pass ? "The current artifact meets this requirement." : "Correct the omitted required value.")])
    }
    private func complete(_ id: String, graph: inout WorkflowTaskGraph) throws -> WorkflowAgentCallV1 {
        let task = try XCTUnwrap(graph.tasks.first { $0.id == id })
        let inputs = task.dependencies.compactMap { dependency in graph.tasks.first { $0.id == dependency }?.outputArtifactID } + (task.artifactInputs ?? [])
        let output = "\(id):\(task.revision)"
        let call = try WorkflowAgentCallV1(callID: WorkflowAgentCallID(), ordinal: 1, attempt: 1,
            prefixKey: StableDigest.sha256(Data(output.utf8)), promptDigest: StableDigest.sha256(Data(task.instruction.utf8)),
            options: .init(task: .init(taskID: id, instruction: task.instruction,
                inputArtifactIDs: inputs, outputArtifactID: output, expectedRevision: task.revision), sessionKey: task.agent), childRunID: AgentRunID())
        try graph.claim(taskID: id, expectedRevision: task.revision, call: call)
        try graph.settle(call: call, outcome: .completed(value: .inline(try CanonicalJSON(.string(output))), usage: .zero))
        return call
    }
}
