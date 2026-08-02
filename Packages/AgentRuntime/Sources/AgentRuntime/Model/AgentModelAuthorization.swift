// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// A prepared attempt paired with a live, non-serializable authorization gate.
public struct AuthorizedAgentModelAttempt: Sendable {
    public let preparedAttempt: PreparedAgentModelAttempt
    public let request: AuthorizedModelRequest

    fileprivate init(
        preparedAttempt: PreparedAgentModelAttempt,
        request: AuthorizedModelRequest
    ) {
        self.preparedAttempt = preparedAttempt
        self.request = request
    }
}

/// The sole runtime path from a durable prepared model request to executable authorization.
public struct AgentModelAuthorizationBinder: Sendable {
    public init() {}

    public func authorizeLocal(
        _ preparedAttempt: PreparedAgentModelAttempt,
        approvalID: ApprovalID,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp,
        policyEngine: any ApprovalPolicyEngine,
        clock: any AgentAuthorizationClock,
        attemptLedger: any ExternalOperationAttemptClaiming
    ) async throws -> AuthorizedAgentModelAttempt {
        let prepared = preparedAttempt.preparedRequest
        guard preparedAttempt.providerDescriptor.location == .onDevice,
              prepared.request.selection.providerID == preparedAttempt.providerDescriptor.id,
              prepared.request.selection.capabilityVersion
                == preparedAttempt.providerDescriptor.capabilityVersion,
              prepared.externalOperation.plan.kind == .localPure,
              prepared.externalOperation.plan.subjectID
                == preparedAttempt.providerDescriptor.id.rawValue,
              prepared.externalOperation.payload.value
                == (try prepared.request.authorizationPayload())
        else { throw AgentModelRuntimeError.authorizationBindingMismatch }

        let authorization = try await policyEngine.bindLocalPolicy(
            prepared: prepared.externalOperation,
            approvalID: approvalID,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
        let authorized = try AuthorizedModelRequest(
            request: prepared.request,
            authorization: authorization,
            clock: clock,
            policyValidator: policyEngine,
            attemptLedger: attemptLedger
        )
        return AuthorizedAgentModelAttempt(
            preparedAttempt: preparedAttempt,
            request: authorized
        )
    }
}
