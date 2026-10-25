// SPDX-License-Identifier: MIT

import Foundation

/// The durable choice made by waitAny. Completion timing must never choose a different replay path.
public struct WorkflowWaitSelection: Hashable, Codable, Sendable {
    public let index: UInt32
    public let candidates: [WorkflowAgentCallID]
    public let selected: WorkflowAgentCallID

    public init(index: UInt32, candidates: [WorkflowAgentCallID], selected: WorkflowAgentCallID) throws {
        guard index > 0, !candidates.isEmpty, candidates.count <= 1_000,
              Set(candidates).count == candidates.count, candidates.contains(selected)
        else { throw AgentContractError.invalidName("workflow wait selection") }
        self.index = index
        self.candidates = candidates
        self.selected = selected
    }
}
