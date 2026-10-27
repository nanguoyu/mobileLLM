// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

extension WorkflowSandboxEvidence {
    static func read(_ outcome: AgentToolInvocationOutcome, prepared: PreparedExternalOperationRequest) -> Self? {
        guard prepared.plan.kind == .sandbox, prepared.plan.effects == [.codeExecution],
              prepared.plan.executionConstraintDigest != nil,
              prepared.capabilityGrant.authority.workspaceIDs.count == 1,
              let workspace = prepared.capabilityGrant.authority.workspaceIDs.first,
              let operation = OpenSandboxToolOperation.allCases.first(where: {
                  (try? AgentToolLogicalID(providerID: "sandbox", name: $0.rawValue).description) == prepared.plan.subjectID
              }) else { return nil }
        let source = SandboxSourceObservation.read(outcome, prepared: prepared)?.digest
        guard case .completed(let values) = outcome else {
            if let source { return Self(workspaceID: workspace, sourceDigest: source, operation: operation.rawValue) }
            // The authenticated gateway can reject an owned operation before submitting a command.
            // Bind that rejection to this scope; arbitrary tool/provider claims remain untrusted.
            if case .failed(let failure) = outcome, failure.code == "sandbox.opensandbox.execution",
               failure.externalEffect == .confirmedNone,
               failure.details["sandbox.workspace"] == workspace.description,
               let id = failure.details["sandbox.operation"], UUID(uuidString: id) != nil {
                return Self(workspaceID: workspace, sourceDigest: nil, operation: operation.rawValue)
            }
            return nil
        }
        for value in values {
            guard case .structured(let data) = value,
                  case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data.value.data),
                  object["workspaceID"] == .string(workspace.description),
                  object["operation"] == .string(operation.rawValue) else { continue }
            let port: Int? = if case .integer(let number)? = object["port"] { Int(exactly: number) } else { nil }
            let process: String? = if case .string(let text)? = object["processID"] { text } else { nil }
            let running: Bool? = if case .bool(let flag)? = object["running"] { flag } else { nil }
            let artifacts = values.compactMap { content -> ArtifactReference? in
                switch content { case .image(let artifact), .artifact(let artifact): artifact; default: nil }
            }
            return Self(workspaceID: workspace, sourceDigest: source, operation: operation.rawValue,
                port: port, processID: process, running: running, artifacts: artifacts)
        }
        return nil
    }
}
