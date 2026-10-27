// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// State evidence belongs to an admitted sandbox operation, not to model-authored progress notes.
struct SandboxSourceObservation: Equatable {
    let workspace: SandboxWorkspaceHandleID
    let digest: StableDigest

    static func read(_ outcome: AgentToolInvocationOutcome, prepared: PreparedExternalOperationRequest) -> Self? {
        guard prepared.plan.kind == .sandbox, prepared.plan.effects == [.codeExecution],
              prepared.plan.executionConstraintDigest != nil,
              prepared.capabilityGrant.authority.workspaceIDs.count == 1,
              let workspace = prepared.capabilityGrant.authority.workspaceIDs.first else { return nil }
        switch outcome {
        case .completed(let values):
            for value in values {
                guard case .structured(let structured) = value,
                      let json = try? JSONDecoder().decode(JSONValue.self, from: structured.value.data),
                      case .object(let fields) = json,
                      fields["workspaceID"] == .string(workspace.description),
                      case .string(let text)? = fields["sourceDigest"], let digest = try? StableDigest(rawValue: text) else { continue }
                return Self(workspace: workspace, digest: digest)
            }
        case .failed(let failure):
            guard failure.externalEffect == .confirmedApplied,
                  failure.details["sandbox.workspace"] == workspace.description,
                  let text = failure.details["sandbox.source"], let digest = try? StableDigest(rawValue: text) else { return nil }
            return Self(workspace: workspace, digest: digest)
        case .uncertain: break
        }
        return nil
    }
}
