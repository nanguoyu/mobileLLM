// SPDX-License-Identifier: MIT

import XCTest
@testable import AgentContracts

final class WorkflowTaskDescriptorTests: XCTestCase {
    func testDisplayMetadataRoundTripsWithoutChangingExecutionIdentity() throws {
        let old = try WorkflowAgentOptionsV1(label: "plan", requestedAgentType: "workflow-worker")
        let task = try WorkflowTaskDescriptorV1(
            taskID: "plan", instruction: "Use the two completed investigations.\nReturn a plan.",
            inputArtifactIDs: ["storage:1", "sync:2"], outputArtifactID: "plan:3"
        )
        let enriched = try WorkflowAgentOptionsV1(label: "plan", requestedAgentType: "workflow-worker", task: task)
        XCTAssertEqual(try old.outputIdentity(), try enriched.outputIdentity())
        let encoder = JSONEncoder()
        XCTAssertEqual(try JSONDecoder().decode(WorkflowAgentOptionsV1.self, from: encoder.encode(enriched)), enriched)
        let oldData = try encoder.encode(old)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("\"task\""))
        XCTAssertNil(try JSONDecoder().decode(WorkflowAgentOptionsV1.self, from: oldData).task)
    }

    func testTaskMetadataRejectsUnboundedOrAmbiguousReferencesOnDecode() throws {
        XCTAssertThrowsError(try WorkflowTaskDescriptorV1(taskID: "x", instruction: String(repeating: "x", count: 16_385), inputArtifactIDs: [], outputArtifactID: "x:1"))
        for inputs in [["a:1", "a:1"], ["x:2"]] {
            let value: [String: Any] = ["taskID": "x", "instruction": "Continue", "inputArtifactIDs": inputs, "outputArtifactID": "x:2"]
            XCTAssertThrowsError(try JSONDecoder().decode(WorkflowTaskDescriptorV1.self, from: JSONSerialization.data(withJSONObject: value)))
        }
    }
}
