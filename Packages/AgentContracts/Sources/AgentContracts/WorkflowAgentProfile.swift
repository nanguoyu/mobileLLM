// SPDX-License-Identifier: MIT

import Foundation

public enum AgentModelReasoningEffort: String, CaseIterable, Hashable, Codable, Sendable, Comparable {
    case low, medium, high
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let rank: [Self: Int] = [.low: 0, .medium: 1, .high: 2]
        return rank[lhs]! < rank[rhs]!
    }
}

/// A role's requested subset of the frozen parent policy. Empty lists inherit the parent tools
/// and retain the user's explicitly active skill. They never grant a new external capability.
public struct WorkflowAgentProfileV1: Hashable, Codable, Sendable {
    public let toolNames: [String]
    public let skillIDs: [String]
    public let reasoningEffort: AgentModelReasoningEffort?

    public init(toolNames: [String] = [], skillIDs: [String] = [], reasoningEffort: AgentModelReasoningEffort? = nil) throws {
        guard toolNames.count <= 32, skillIDs.count <= 8,
              Set(toolNames).count == toolNames.count, Set(skillIDs).count == skillIDs.count,
              (toolNames + skillIDs).allSatisfy({ AgentWireValidation.isNonblankControlFree($0, maximumLength: 256) })
        else { throw AgentContractError.invalidName("agent profile") }
        self.toolNames = toolNames.sorted(); self.skillIDs = skillIDs.sorted(); self.reasoningEffort = reasoningEffort
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(toolNames: values.decodeIfPresent([String].self, forKey: .toolNames) ?? [],
            skillIDs: values.decodeIfPresent([String].self, forKey: .skillIDs) ?? [],
            reasoningEffort: values.decodeIfPresent(AgentModelReasoningEffort.self, forKey: .reasoningEffort))
    }

    public var digest: StableDigest {
        try! CanonicalJSON(.object(["tools": .array(toolNames.map(JSONValue.string)), "skills": .array(skillIDs.map(JSONValue.string)),
            "reasoningEffort": reasoningEffort.map { .string($0.rawValue) } ?? .null])).fingerprint
    }
}
