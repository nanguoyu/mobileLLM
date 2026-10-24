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

    func testHistoricalConsumerKeepsTheOriginalResultAfterAnUpstreamRetry() throws {
        var original = try call(1, taskID: "source", output: "source:1")
        original.preparedSequence = 1; original.settledSequence = 2
        var firstConsumer = try call(2, taskID: "plan", output: "plan:2", inputs: ["source:1"])
        firstConsumer.preparedSequence = 3; firstConsumer.settledSequence = 4
        var retried = try call(1, taskID: "source", output: "source:1", attempt: 2)
        retried.preparedSequence = 5; retried.settledSequence = 6
        var secondConsumer = try call(2, taskID: "plan", output: "plan:2", inputs: ["source:1"], attempt: 2)
        secondConsumer.preparedSequence = 7
        let history = [original, firstConsumer, retried, secondConsumer]
        XCTAssertEqual(WorkflowDisplay.inputs(for: firstConsumer, in: history).map(\.callID), [original.callID])
        XCTAssertEqual(WorkflowDisplay.inputs(for: secondConsumer, in: history).map(\.callID), [retried.callID])
    }

    private func call(_ ordinal: UInt32, taskID: String?, output: String?, inputs: [String] = [],
                      type: String = "workflow-worker", status: DynamicWorkflowChildStatus = .completed,
                      attempt: UInt16 = 1) throws -> DynamicWorkflowChildPresentation {
        let task: WorkflowTaskDescriptorV1? = try taskID.flatMap { id in
            guard let output else { return nil }
            return try WorkflowTaskDescriptorV1(taskID: id, instruction: "Work on \(id)", inputArtifactIDs: inputs, outputArtifactID: output)
        }
        return DynamicWorkflowChildPresentation(callID: WorkflowAgentCallID(), ordinal: ordinal, attempt: attempt,
            childRunID: AgentRunID(), status: status, task: task, agentType: type)
    }
}
