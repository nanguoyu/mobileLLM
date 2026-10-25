// SPDX-License-Identifier: MIT

import Foundation

/// Recorded display data for an assigned task. It never grants capabilities or changes replay identity.
/// Artifact IDs name the exact results supplied to the worker, including continued task history.
public struct WorkflowTaskDescriptorV1: Hashable, Codable, Sendable {
    public let taskID: String
    public let instruction: String
    public let inputArtifactIDs: [String]
    public let outputArtifactID: String
    /// Present only for a task graph claim. Old display-only descriptors retain their semantics.
    public let expectedRevision: UInt64?
    public let goalAmendmentCount: Int?

    public init(taskID: String, instruction: String, inputArtifactIDs: [String], outputArtifactID: String,
                expectedRevision: UInt64? = nil, goalAmendmentCount: Int? = nil) throws {
        guard AgentWireValidation.isNonblankControlFree(taskID, maximumLength: 128),
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instruction.utf8.count <= 16_384,
              inputArtifactIDs.count <= 32,
              Set(inputArtifactIDs).count == inputArtifactIDs.count,
              inputArtifactIDs.allSatisfy({ AgentWireValidation.isNonblankControlFree($0, maximumLength: 128) }),
              AgentWireValidation.isNonblankControlFree(outputArtifactID, maximumLength: 128),
              !inputArtifactIDs.contains(outputArtifactID),
              goalAmendmentCount.map({ (0...64).contains($0) }) ?? true
        else { throw AgentContractError.invalidName("workflow task descriptor") }
        self.taskID = taskID
        self.instruction = instruction
        self.inputArtifactIDs = inputArtifactIDs
        self.outputArtifactID = outputArtifactID
        self.expectedRevision = expectedRevision
        self.goalAmendmentCount = goalAmendmentCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            taskID: values.decode(String.self, forKey: .taskID),
            instruction: values.decode(String.self, forKey: .instruction),
            inputArtifactIDs: values.decode([String].self, forKey: .inputArtifactIDs),
            outputArtifactID: values.decode(String.self, forKey: .outputArtifactID),
            expectedRevision: values.decodeIfPresent(UInt64.self, forKey: .expectedRevision),
            goalAmendmentCount: values.decodeIfPresent(Int.self, forKey: .goalAmendmentCount)
        )
    }
}
