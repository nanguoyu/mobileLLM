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
        let arguments = prepared.plan.canonicalArguments.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0.value.data) }
        let requestedPort: Int? = if case .object(let fields)? = arguments, case .integer(let number)? = fields["port"] { Int(exactly: number) } else { nil }
        guard case .completed(let values) = outcome else {
            var artifacts: [ArtifactReference] = []
            if case .failed(let failure) = outcome, let text = failure.details["sandbox.screenshotReference"],
               let reference = try? JSONDecoder().decode(ArtifactReference.self, from: Data(text.utf8)),
               reference.provenance.runID == prepared.runID, reference.provenance.invocationID == prepared.invocationID,
               reference.semanticType == "sandbox.browser-failure", reference.mimeType == "image/jpeg" { artifacts = [reference] }
            if let source { return Self(workspaceID: workspace, sourceDigest: source, operation: operation.rawValue,
                port: requestedPort, artifacts: artifacts) }
            // A settled command can fail before producing a source snapshot, or be rejected before
            // submission. Both are known outcomes in this scope; uncertain transport is excluded.
            if case .failed(let failure) = outcome, failure.code == "sandbox.opensandbox.execution",
               [.confirmedNone, .confirmedApplied].contains(failure.externalEffect),
               failure.details["sandbox.workspace"] == workspace.description,
               let id = failure.details["sandbox.operation"], UUID(uuidString: id) != nil {
                return Self(workspaceID: workspace, sourceDigest: nil, operation: operation.rawValue,
                    port: requestedPort, artifacts: artifacts)
            }
            return nil
        }
        for value in values {
            guard case .structured(let data) = value,
                  case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data.value.data),
                  object["workspaceID"] == .string(workspace.description),
                  object["operation"] == .string(operation.rawValue) else { continue }
            let port: Int? = if case .integer(let number)? = object["port"] { Int(exactly: number) } else { nil }
            if let requestedPort, requestedPort != port { return nil }
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
