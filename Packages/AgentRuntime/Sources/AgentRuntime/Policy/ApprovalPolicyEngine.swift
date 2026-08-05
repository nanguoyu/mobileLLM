// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

public struct ApprovalPolicyEvaluation: Sendable {
    public let authorization: ApprovalAuthorizationOutcome
    public let presentation: ApprovalPresentationOutcome
    public let matchingReceipt: ApprovalReceipt?
}

public extension ApprovalPolicyEngine {
    /// Evaluates one prepared operation under the run's frozen approval mode. Full access and the Safe
    /// preset return an auto-authorization (the caller still records a durable local-policy bind);
    /// `.ask` and anything not covered by the preset fall through to the normal policy evaluation.
    func evaluate(
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority?,
        interaction: ApprovalInteractionContext,
        candidateReceipts: [ApprovalReceipt],
        at timestamp: AgentTimestamp,
        approvalMode: AgentApprovalMode
    ) -> ApprovalPolicyEvaluation {
        let autoApprove = approvalMode == .fullAccess
            || (approvalMode == .safePreset
                && ApprovalPresentationOutcome.isSafePresetOperation(prepared.plan))
        if autoApprove {
            return ApprovalPolicyEvaluation(
                authorization: ApprovalAuthorizationOutcome.authorizedByApprovalMode(),
                presentation: ApprovalPresentationOutcome.authorizedByApprovalMode(),
                matchingReceipt: nil
            )
        }
        return evaluate(
            prepared: prepared,
            trustedRunAuthority: trustedRunAuthority,
            feature: .enabled,
            interaction: interaction,
            candidateReceipts: candidateReceipts,
            at: timestamp
        )
    }

    /// Binds a durable authorization for an operation auto-approved by the run's approval mode
    /// (fullAccess / safePreset). Unlike `bindLocalPolicy`, this is valid for ANY effect class — the
    /// mode already decided to skip the user prompt — while the prepared request and run ceiling still
    /// enforce the exact scope and authority.
    func bindApprovalMode(
        prepared: PreparedExternalOperationRequest,
        approvalID: ApprovalID,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        let receipt = try ApprovalReceipt(
            id: approvalID,
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: policyVersion,
            decidedAt: timestamp
        )
        return try await bind(
            prepared: prepared,
            receipt: receipt,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
    }
}

public enum ApprovalPolicyEngineError: Error, Hashable, Sendable {
    case invalidPolicyVersion
    case missingEffects
    case notLocallyAuthorizable
    case authorizationNotGranted
}

public protocol ApprovalPolicyEngine: AgentAuthorizationPolicyValidating, Sendable {
    var policyVersion: UInt32 { get }

    func evaluate(
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority?,
        feature: ApprovalFeatureState,
        interaction: ApprovalInteractionContext,
        candidateReceipts: [ApprovalReceipt],
        at timestamp: AgentTimestamp
    ) -> ApprovalPolicyEvaluation

    func bind(
        prepared: PreparedExternalOperationRequest,
        receipt: ApprovalReceipt,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest

    func bindLocalPolicy(
        prepared: PreparedExternalOperationRequest,
        approvalID: ApprovalID,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest
}

/// Deny-by-default local policy implementation. It never presents system UI or executes an
/// operation; it only classifies and constructs non-serializable authorization-bound requests.
public struct DefaultApprovalPolicyEngine: ApprovalPolicyEngine, Sendable {
    public let policyVersion: UInt32
    private let sanitizationValidator: any SanitizationAttestationValidating

    public init(
        policyVersion: UInt32 = 1,
        sanitizationValidator: any SanitizationAttestationValidating
    ) throws {
        guard policyVersion > 0 else { throw ApprovalPolicyEngineError.invalidPolicyVersion }
        self.policyVersion = policyVersion
        self.sanitizationValidator = sanitizationValidator
    }

    public func evaluate(
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority?,
        feature: ApprovalFeatureState,
        interaction: ApprovalInteractionContext,
        candidateReceipts: [ApprovalReceipt],
        at timestamp: AgentTimestamp
    ) -> ApprovalPolicyEvaluation {
        let authority = authorityValidity(
            prepared: prepared,
            trustedRunAuthority: trustedRunAuthority
        )
        let classified = classifyReceipts(
            candidateReceipts,
            for: prepared,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
        // ExternalOperationPlan validation guarantees at least one effect. Keep a conservative
        // fallback here as defense in depth so future decoding/migration mistakes cannot crash the
        // policy boundary or accidentally lower risk.
        let effectClass: ApprovalEffectClass
        if let classified = ApprovalEffectClass.highestRisk(in: prepared.plan.effects) {
            effectClass = classified
        } else {
            effectClass = .unknownExternal
        }
        let authorization = ApprovalDecisionTables.authorize(
            ApprovalAuthorizationInput(
                authority: authority,
                receipt: classified.validity,
                effectClass: effectClass,
                feature: feature,
                interaction: interaction
            )
        )
        return ApprovalPolicyEvaluation(
            authorization: authorization,
            presentation: ApprovalDecisionTables.presentation(
                for: presentationAuthorization(for: authorization.decision),
                interaction: interaction
            ),
            matchingReceipt: authorization.decision == .authorizeMatchingReceipt
                ? classified.receipt
                : nil
        )
    }

    private func presentationAuthorization(
        for decision: ApprovalAuthorizationDecision
    ) -> ApprovalPresentationAuthorization {
        switch decision {
        case .authorizeLocalPolicy, .authorizeMatchingReceipt: .authorized
        case .requireApproval: .approvalRequired
        case .deny: .denied
        }
    }

    public func bind(
        prepared: PreparedExternalOperationRequest,
        receipt: ApprovalReceipt,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        try await validateCurrentAuthorization(
            receipt: receipt,
            prepared: prepared,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
        return try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trustedRunAuthority
        )
    }

    public func bindLocalPolicy(
        prepared: PreparedExternalOperationRequest,
        approvalID: ApprovalID,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws -> AuthorizedExternalOperationRequest {
        let effectClass = ApprovalEffectClass.highestRisk(in: prepared.plan.effects)
        guard effectClass == .localPure || effectClass == .appLocalRead || effectClass == .appLocalWrite
        else { throw ApprovalPolicyEngineError.notLocallyAuthorizable }
        guard authorityValidity(
            prepared: prepared,
            trustedRunAuthority: trustedRunAuthority
        ) == .valid else { throw ApprovalPolicyEngineError.authorizationNotGranted }
        let receipt = try ApprovalReceipt(
            id: approvalID,
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: policyVersion,
            decidedAt: timestamp
        )
        return try await bind(
            prepared: prepared,
            receipt: receipt,
            trustedRunAuthority: trustedRunAuthority,
            at: timestamp
        )
    }

    public func validateCurrentAuthorization(
        receipt: ApprovalReceipt,
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws {
        guard receipt.policyVersion == policyVersion,
              trustedRunAuthority.policyRevision == UInt64(policyVersion),
              receipt.isUsable(at: timestamp),
              trustedRunAuthority.validates(runID: prepared.runID, grant: prepared.capabilityGrant)
        else { throw AgentContractError.authorizationDenied }
        do {
            try validateSanitizationAttestations(prepared)
        } catch {
            throw AgentContractError.authorizationDenied
        }
        _ = try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trustedRunAuthority
        )
    }

    private func authorityValidity(
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority?
    ) -> ApprovalAuthorityValidity {
        guard let trustedRunAuthority else { return .missingStepGrant }
        guard trustedRunAuthority.policyRevision == UInt64(policyVersion) else {
            return .policyRevokedOrUnavailable
        }
        guard trustedRunAuthority.runID == prepared.runID,
              trustedRunAuthority.ceiling == prepared.capabilityGrant.runCeiling
        else { return .outsideRunCeiling }
        guard trustedRunAuthority.validates(
            runID: prepared.runID,
            grant: prepared.capabilityGrant
        ), prepared.plan.isWithin(prepared.capabilityGrant.authority)
        else { return .planOutsideStepGrant }
        guard (try? validateSanitizationAttestations(prepared)) != nil else {
            return .policyRevokedOrUnavailable
        }
        return .valid
    }

    private func validateSanitizationAttestations(
        _ prepared: PreparedExternalOperationRequest
    ) throws {
        try sanitizationValidator.validate(prepared.payload)
        if let arguments = prepared.plan.canonicalArguments {
            try sanitizationValidator.validate(arguments)
        }
    }

    private func classifyReceipts(
        _ receipts: [ApprovalReceipt],
        for prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority?,
        at timestamp: AgentTimestamp
    ) -> (validity: ApprovalReceiptValidity, receipt: ApprovalReceipt?) {
        // A durable denial/cancellation for this exact request always wins, independent of caller
        // ordering or the presence of an older reusable grant.
        for receipt in receipts
            where receipt.conversationID == prepared.conversationID
                && receipt.requestID == prepared.requestID
        {
            if receipt.decision == .denied { return (.deniedCurrentRequest, receipt) }
            if receipt.decision == .cancelled { return (.cancelledCurrentRequest, receipt) }
        }
        var fallback: ApprovalReceiptValidity = .none
        for receipt in receipts {
            guard receipt.conversationID == prepared.conversationID else {
                fallback = fallback == .none ? .conversationMismatch : fallback
                continue
            }
            guard receipt.policyVersion == policyVersion else {
                fallback = fallback == .none ? .policyMismatch : fallback
                continue
            }
            guard timestamp >= receipt.decidedAt else {
                fallback = fallback == .none ? .notYetValid : fallback
                continue
            }
            guard receipt.expiresAt.map({ timestamp <= $0 }) ?? true else {
                fallback = fallback == .none ? .expired : fallback
                continue
            }
            guard receipt.decision == .approved, let trustedRunAuthority else { continue }
            do {
                _ = try AuthorizedExternalOperationRequest(
                    prepared: prepared,
                    authorization: receipt,
                    trustedRunAuthority: trustedRunAuthority
                )
                return (
                    receipt.scope == .exactInvocation ? .usableExact : .usableConversationRead,
                    receipt
                )
            } catch {
                fallback = fallback == .none
                    ? detailedMismatch(receipt: receipt, prepared: prepared)
                    : fallback
            }
        }
        return (fallback, nil)
    }

    private func detailedMismatch(
        receipt: ApprovalReceipt,
        prepared: PreparedExternalOperationRequest
    ) -> ApprovalReceiptValidity {
        let plan = prepared.plan
        // Online-model conversation consent deliberately ignores the message-specific payload/fingerprint:
        // the user approved THIS conversation for THIS service, not one exact prompt.
        let modelConsent = receipt.scope == .conversation && plan.isModelProviderConsent
        if receipt.scope == .exactInvocation {
            if receipt.requestID != prepared.requestID { return .requestMismatch }
            if receipt.invocationID != prepared.invocationID { return .invocationMismatch }
        }
        if receipt.previewDigest != StableDigest.sha256(Data(plan.userPreview.utf8)) {
            return .previewMismatch
        }
        if receipt.argumentsDigest != plan.canonicalArguments?.fingerprint { return .argumentsMismatch }
        if receipt.destination != plan.destination { return .destinationMismatch }
        if receipt.allowedRedirects != plan.allowedRedirects { return .redirectsMismatch }
        if receipt.allowedFallbacks != plan.allowedFallbacks { return .fallbacksMismatch }
        if receipt.dataCategories != plan.dataCategories { return .dataCategoriesMismatch }
        if receipt.artifactIDs != plan.artifactIDs { return .artifactsMismatch }
        if receipt.workspaceID != plan.workspaceID { return .workspaceMismatch }
        if receipt.authorityConstraints != plan.authorityConstraints {
            return .authorityConstraintsMismatch
        }
        if receipt.effects != plan.effects { return .effectsMismatch }
        if !modelConsent, receipt.payloadDigest != plan.payloadDigest { return .payloadMismatch }
        if receipt.executionConstraintDigest != plan.executionConstraintDigest {
            return .executionConstraintsMismatch
        }
        if receipt.descriptorID != plan.descriptorID { return .descriptorMismatch }
        if receipt.schemaDigest != plan.schemaDigest { return .schemaMismatch }
        if receipt.trustRevision != plan.trustRevision { return .trustRevisionMismatch }
        if receipt.idempotencyKey != plan.idempotencyKey { return .idempotencyKeyMismatch }
        if receipt.credentialReference != plan.credentialReference {
            return .credentialReferenceMismatch
        }
        if !modelConsent, receipt.planFingerprint != plan.fingerprint {
            return .planFingerprintMismatch
        }
        if receipt.scope == .exactInvocation {
            if receipt.preparedRequestFingerprint != prepared.fingerprint {
                return .preparedRequestMismatch
            }
            if receipt.stepCapabilityGrantFingerprint != prepared.capabilityGrant.fingerprint {
                return .stepGrantMismatch
            }
            if receipt.runCapabilityCeilingFingerprint
                != prepared.capabilityGrant.runCeiling.fingerprint
            {
                return .runCeilingMismatch
            }
        }
        return .planFingerprintMismatch
    }
}
