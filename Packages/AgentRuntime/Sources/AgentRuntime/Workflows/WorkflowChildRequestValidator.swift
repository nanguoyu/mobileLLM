// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Fail-closed reasons why trusted workflow policy produced a child request that no longer matches
/// the immutable launch envelope. These are runtime/policy integration faults, never script errors.
public enum WorkflowChildRequestValidationError: Error, Hashable, Sendable {
    case parentIdentityMismatch
    case childIdentityMismatch
    case provenanceMismatch
    case authorityNotAttenuated
    case budgetNotAttenuated
    case modelPolicyWidened
    case requestedModelNotHonored(String)
    case requestedAgentTypeNotHonored(String)
    case outputRequirementMismatch
    case isolationRequirementMismatch
    case approvalModeMismatch
}

/// Revalidates every security- and output-affecting field returned by a
/// ``WorkflowChildRequestBuilding`` implementation. The builder is trusted policy, but its output
/// is still checked here so stale aliases or future integration regressions cannot widen a frozen
/// workflow launch.
public struct WorkflowChildRequestValidator: Sendable {
    public init() {}

    public func validate(
        _ request: SubagentSpawnRequest,
        launch: WorkflowLaunchSnapshotV1,
        call: WorkflowAgentCallV1
    ) throws {
        guard request.parentRunID == launch.initiatingRunID,
              request.parentRequestID == launch.initiatingRequestID,
              request.requestingStepID == launch.requestingStepID
        else { throw WorkflowChildRequestValidationError.parentIdentityMismatch }
        guard request.childRunID == call.childRunID else {
            throw WorkflowChildRequestValidationError.childIdentityMismatch
        }
        guard request.source == .workflow else {
            throw WorkflowChildRequestValidationError.provenanceMismatch
        }

        do {
            // Empty authority is the irreducible least-authority scope. Requiring a mathematically
            // strict subset at that bottom element would make pure computation impossible.
            if launch.capabilityCeiling.authority == .empty {
                guard request.capabilityCeiling.authority == .empty else {
                    throw WorkflowChildRequestValidationError.authorityNotAttenuated
                }
            } else {
                _ = try launch.capabilityCeiling.attenuating(
                    to: request.capabilityCeiling.authority,
                    requireStrict: true
                )
            }
        } catch is WorkflowChildRequestValidationError {
            throw WorkflowChildRequestValidationError.authorityNotAttenuated
        } catch {
            throw WorkflowChildRequestValidationError.authorityNotAttenuated
        }
        guard request.artifactReferences.allSatisfy({
            launch.capabilityCeiling.authority.artifactIDs.contains($0.id)
        }) else {
            throw WorkflowChildRequestValidationError.authorityNotAttenuated
        }

        do {
            _ = try launch.budget.attenuating(to: request.budget, requireStrict: true)
        } catch {
            throw WorkflowChildRequestValidationError.budgetNotAttenuated
        }
        if let maximum = call.options.maximumToolCalls, request.budget.limits[.toolInvocations] > maximum {
            throw WorkflowChildRequestValidationError.budgetNotAttenuated
        }

        guard Self.isModelPolicy(request.modelPolicy, attenuatedFrom: launch.defaultModelPolicy) else {
            throw WorkflowChildRequestValidationError.modelPolicyWidened
        }
        if let requestedModel = call.options.requestedModel,
           (request.modelPolicy.strategy != .pinned
               || request.modelPolicy.allowedSelections.count != 1)
        {
            // The string is a policy-owned alias, not a provider/model wire identifier. Requiring
            // the builder to resolve it to one pinned in-ceiling selection prevents silently
            // ignoring the request without coupling the runtime to an app alias namespace.
            throw WorkflowChildRequestValidationError.requestedModelNotHonored(requestedModel)
        }
        if let requestedAgentType = call.options.requestedAgentType,
           request.role != requestedAgentType
        {
            throw WorkflowChildRequestValidationError.requestedAgentTypeNotHonored(requestedAgentType)
        }

        let expectedOutput: AgentOutputRequirement = if let schema = call.options.schema {
            .structured(schema)
        } else {
            .text
        }
        guard request.outputRequirement == expectedOutput else {
            throw WorkflowChildRequestValidationError.outputRequirementMismatch
        }

        let canWriteLocally = request.capabilityCeiling.capabilities.contains(.localWrite)
        if canWriteLocally && !call.options.requiresIsolatedWorkspace {
            // The current ABI has no declarative disjoint-write ownership contract. Parallel local
            // writes are therefore legal only in a provider-created isolated workspace.
            throw WorkflowChildRequestValidationError.isolationRequirementMismatch
        }
        if call.options.requiresIsolatedWorkspace {
            guard let sandbox = request.sandboxRequirement,
                  sandbox.workspaceID == nil,
                  sandbox.checkpointID == nil,
                  sandbox.authority.isSubset(of: request.capabilityCeiling.authority),
                  sandbox.authority.isSubset(of: launch.capabilityCeiling.authority),
                  (try? request.budget.attenuating(to: sandbox.budget)) != nil,
                  !canWriteLocally || sandbox.authority.capabilities.contains(.localWrite)
            else { throw WorkflowChildRequestValidationError.isolationRequirementMismatch }
        }

        guard request.approvalMode == launch.approvalMode else {
            throw WorkflowChildRequestValidationError.approvalModeMismatch
        }
    }

    private static func isModelPolicy(
        _ child: AgentModelPolicy,
        attenuatedFrom parent: AgentModelPolicy
    ) -> Bool {
        if parent.localOnly && !child.localOnly { return false }
        guard Set(child.allowedSelections).isSubset(of: Set(parent.allowedSelections)),
              Set(parent.requiredCapabilities.values).isSubset(
                  of: Set(child.requiredCapabilities.values)
              )
        else { return false }
        switch parent.strategy {
        case .pinned:
            return child.strategy == .pinned && child.allowedSelections == parent.allowedSelections
        case .deterministicLocalPolicy:
            return child.strategy == .deterministicLocalPolicy || (
                child.strategy == .pinned && child.allowedSelections.count == 1
            )
        }
    }
}
