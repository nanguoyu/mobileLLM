// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI

final class WorkflowTaskPresentationTests: XCTestCase {
    func testTaskGroupsExcludeCoordinationAndKeepContinuationHistory() throws {
        let source = try call(1, taskID: "source", output: "source:1")
        let coordinator = try call(2, taskID: nil, output: nil, type: "workflow-supervisor")
        let continued = try call(3, taskID: "source", output: "source:2", inputs: ["source:1"], status: .failed)
        let groups = WorkflowDisplay.tasks([continued, coordinator, source])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.calls.count, 2)
        XCTAssertEqual(groups.first?.latest.status, .failed, "Earlier success must not hide the current failure")
        XCTAssertEqual(WorkflowDisplay.inputs(for: continued, in: [source, continued]).map(\.callID), [source.callID])
    }

    func testActualWaitStatesAndUnattachedRunsDoNotClaimActiveWork() throws {
        var item = try call(1, taskID: "task", output: "task:1", status: .submitted)
        item.executionState = .waitingForApproval
        XCTAssertEqual(item.statusText(workflowState: .running, attached: true), "Needs approval")
        XCTAssertEqual(item.statusText(workflowState: .running, attached: false), "Needs resume")
        item.executionState = .completed
        XCTAssertEqual(item.statusText(workflowState: .running, attached: true), "Saving outcome")
        XCTAssertEqual(item.statusText(workflowState: .paused, attached: false), "Paused")
    }

    func testFailureEvidenceRemainsAnInspectableInput() throws {
        let failed = try call(1, taskID: "probe", output: "probe:1", status: .failed)
        let recovery = try call(2, taskID: "repair", output: "repair:2", inputs: ["probe:1"])
        XCTAssertEqual(WorkflowDisplay.inputs(for: recovery, in: [failed, recovery]).first?.status, .failed)
    }

    private func call(_ ordinal: UInt32, taskID: String?, output: String?, inputs: [String] = [],
                      type: String = "workflow-worker", status: DynamicWorkflowChildStatus = .completed) throws -> DynamicWorkflowChildPresentation {
        let task: WorkflowTaskDescriptorV1? = try taskID.flatMap { id in
            guard let output else { return nil }
            return try WorkflowTaskDescriptorV1(taskID: id, instruction: "Work on \(id)", inputArtifactIDs: inputs, outputArtifactID: output)
        }
        return DynamicWorkflowChildPresentation(callID: WorkflowAgentCallID(), ordinal: ordinal, attempt: 1,
            childRunID: AgentRunID(), status: status, task: task, agentType: type)
    }
}
