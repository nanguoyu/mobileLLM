// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Instruction-only skill content frozen at goal admission. It grants no tools or execution rights.
public struct WorkflowSkillDefinition: Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let instructions: String
    public var digest: StableDigest { StableDigest.sha256(Data(instructions.utf8)) }

    public init(id: String, name: String, summary: String, instructions: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128, !name.isEmpty, name.utf8.count <= 256,
              summary.utf8.count <= 2_048, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.utf8.count <= 65_536 else { throw ContextCompilationError.invalidInput("skill definition") }
        self.id = id; self.name = name; self.summary = summary; self.instructions = instructions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), name: values.decode(String.self, forKey: .name),
            summary: values.decode(String.self, forKey: .summary), instructions: values.decode(String.self, forKey: .instructions))
    }

    public var catalogEntry: JSONValue {
        .object(["id": .string(id), "name": .string(name), "summary": .string(summary), "digest": .string(digest.rawValue)])
    }
}

public enum WorkflowAgentProfileError: Error, LocalizedError, Sendable {
    case unavailableTool(String)
    case unavailableSkill(String)
    case reasoningCeiling
    public var errorDescription: String? {
        switch self {
        case .unavailableTool(let name): "Tool is outside this task's allowed policy: \(name)."
        case .unavailableSkill(let id): "Skill is unavailable or ambiguous in this task: \(id)."
        case .reasoningCeiling: "The requested reasoning effort is unsupported or exceeds the user's setting."
        }
    }
}
