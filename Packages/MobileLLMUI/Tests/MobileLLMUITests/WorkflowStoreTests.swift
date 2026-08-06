// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI

// TEST-ID: AHT-WORKFLOW-001
@MainActor
final class WorkflowStoreTests: XCTestCase {
    func testSaveLoadRoundTripAndRunningFlag() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory)
        let workflowID = UUID()
        let summary = WorkflowSummary(
            id: workflowID,
            title: "Research",
            conversationID: UUID(),
            plan: try WorkflowPlan(
                goal: "Research",
                phases: [WorkflowPhasePlan(
                    sequence: 1,
                    title: "Goal",
                    acceptanceCriteria: "Done",
                    childInstructions: ["Research"]
                )]
            ),
            status: .running,
            rootRunID: AgentRunID(rawValue: UUID())
        )

        try await store.save(summary)
        XCTAssertTrue(store.hasRunningWorkflow)
        XCTAssertEqual(store.messageRecord(workflowID: workflowID)?.title, "Research")

        let reloaded = WorkflowStore(directory: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.summary(workflowID: workflowID), summary)
        XCTAssertTrue(reloaded.hasRunningWorkflow)
    }

    func testCompletedWorkflowStopsRunningAndRefreshFires() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowStore(directory: directory)
        let workflowID = UUID()
        var changed: [UUID] = []
        store.onWorkflowChanged = { changed.append($0) }

        try await store.save(WorkflowSummary(id: workflowID, title: "T", status: .running))
        var completed = try XCTUnwrap(store.summary(workflowID: workflowID))
        completed.status = .completed
        completed.endTime = Date()
        try await store.save(completed)

        XCTAssertEqual(changed, [workflowID, workflowID])
        XCTAssertFalse(store.hasRunningWorkflow)
        XCTAssertEqual(store.messageRecord(workflowID: workflowID)?.status, .completed)
    }
}
