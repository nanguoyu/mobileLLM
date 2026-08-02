// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public enum ApprovalAuthorityValidity: String, CaseIterable, Hashable, Codable, Sendable {
    case valid
    case missingStepGrant
    case outsideRunCeiling
    case planOutsideStepGrant
    case policyRevokedOrUnavailable
}

public enum ApprovalReceiptValidity: String, CaseIterable, Hashable, Codable, Sendable {
    case none
    case usableExact
    case usableConversationRead
    case deniedCurrentRequest
    case cancelledCurrentRequest
    case expired
    case notYetValid
    case policyMismatch
    case conversationMismatch
    case requestMismatch
    case invocationMismatch
    case planFingerprintMismatch
    case previewMismatch
    case argumentsMismatch
    case destinationMismatch
    case redirectsMismatch
    case fallbacksMismatch
    case dataCategoriesMismatch
    case artifactsMismatch
    case workspaceMismatch
    case authorityConstraintsMismatch
    case effectsMismatch
    case payloadMismatch
    case executionConstraintsMismatch
    case descriptorMismatch
    case schemaMismatch
    case trustRevisionMismatch
    case idempotencyKeyMismatch
    case credentialReferenceMismatch
    case preparedRequestMismatch
    case stepGrantMismatch
    case runCeilingMismatch
}

public enum ApprovalEffectClass: String, CaseIterable, Hashable, Codable, Sendable {
    case localPure
    case appLocalRead
    case appLocalWrite
    case externalRead
    case externalWrite
    case strongExact
    case codeExecution
    case unknownExternal

    public static func highestRisk(in effects: some Sequence<AgentEffect>) -> Self? {
        let classes = effects.map { effect -> Self in
            switch effect {
            case .localPure: .localPure
            case .localRead: .appLocalRead
            case .localWrite: .appLocalWrite
            case .privateDataRead, .networkRead: .externalRead
            case .externalWrite: .externalWrite
            case .externalCommunication, .destructive, .financial: .strongExact
            case .codeExecution: .codeExecution
            case .unknownExternal: .unknownExternal
            }
        }
        return classes.max { riskRank($0) < riskRank($1) }
    }

    private static func riskRank(_ effectClass: Self) -> Int {
        switch effectClass {
        case .localPure: 1
        case .appLocalRead: 2
        case .appLocalWrite: 3
        case .externalRead: 4
        case .externalWrite: 5
        case .codeExecution: 6
        case .strongExact: 7
        case .unknownExternal: 8
        }
    }
}

public enum ApprovalFeatureState: String, CaseIterable, Hashable, Codable, Sendable {
    case notApplicable
    case enabled
    case disabled
}

public enum ApprovalInteractionContext: String, CaseIterable, Hashable, Codable, Sendable {
    case foregroundInteractive
    case background
}

public struct ApprovalAuthorizationInput: Hashable, Codable, Sendable {
    public let authority: ApprovalAuthorityValidity
    public let receipt: ApprovalReceiptValidity
    public let effectClass: ApprovalEffectClass
    public let feature: ApprovalFeatureState
    public let interaction: ApprovalInteractionContext

    public init(
        authority: ApprovalAuthorityValidity,
        receipt: ApprovalReceiptValidity,
        effectClass: ApprovalEffectClass,
        feature: ApprovalFeatureState,
        interaction: ApprovalInteractionContext
    ) {
        self.authority = authority
        self.receipt = receipt
        self.effectClass = effectClass
        self.feature = feature
        self.interaction = interaction
    }
}

public enum ApprovalAuthorizationDecision: String, CaseIterable, Hashable, Codable, Sendable {
    case authorizeLocalPolicy
    case authorizeMatchingReceipt
    case requireApproval
    case deny
}

public enum ApprovalGrantScope: String, CaseIterable, Hashable, Codable, Sendable {
    case none
    case exactInvocation
    case boundedConversationRead
}

public enum ApprovalPolicyDiagnostic: String, CaseIterable, Hashable, Codable, Sendable {
    case missingStepGrant
    case outsideRunCeiling
    case planOutsideStepGrant
    case policyUnavailable
    case featureDisabled
    case approvalDenied
    case approvalCancelled
    case systemPermissionDenied
    case systemAccessTemporarilyUnavailable
    case systemPromptRequiresForeground
    case confirmedOperationFailure
    case unknownExternalOutcome
    case strongEffectOutcomeUnknown
    case codeExecutionOutcomeUnknown
    case externalWriteOutcomeUnknown
    case externalReadTransportLost
    case unexpectedLocalTransportLoss
    case noMatchingRule
}

public struct ApprovalAuthorizationOutcome: Hashable, Codable, Sendable {
    public let decision: ApprovalAuthorizationDecision
    public let grantScope: ApprovalGrantScope
    public let uncertainOnTransportLoss: Bool
    public let runState: AgentRunState?
    public let diagnostic: ApprovalPolicyDiagnostic?
    public let matchedRuleID: String

    fileprivate init(
        decision: ApprovalAuthorizationDecision,
        grantScope: ApprovalGrantScope,
        uncertainOnTransportLoss: Bool = false,
        runState: AgentRunState? = nil,
        diagnostic: ApprovalPolicyDiagnostic? = nil,
        matchedRuleID: String
    ) {
        self.decision = decision
        self.grantScope = grantScope
        self.uncertainOnTransportLoss = uncertainOnTransportLoss
        self.runState = runState
        self.diagnostic = diagnostic
        self.matchedRuleID = matchedRuleID
    }
}

public enum ApprovalPresentationDecision: String, CaseIterable, Hashable, Codable, Sendable {
    case presentApproval
    case deferApproval
    case noPresentation
}

/// Registry-normalized authorization state used only to decide presentation behavior.
public enum ApprovalPresentationAuthorization: String, CaseIterable, Hashable, Codable, Sendable {
    case authorized
    case approvalRequired
    case denied
}

public struct ApprovalPresentationOutcome: Hashable, Codable, Sendable {
    public let decision: ApprovalPresentationDecision
    public let runState: AgentRunState?
    public let matchedRuleID: String
}

public enum SystemAccessState: String, CaseIterable, Hashable, Codable, Sendable {
    case notRequired
    case granted
    case promptRequired
    case denied
    case temporarilyUnavailable
}

public enum SystemAccessDecision: String, CaseIterable, Hashable, Codable, Sendable {
    case `continue`
    case deny
    case waitForForeground
    case requestSystemPrompt
}

public struct SystemAccessOutcome: Hashable, Codable, Sendable {
    public let decision: SystemAccessDecision
    public let runState: AgentRunState?
    public let diagnostic: ApprovalPolicyDiagnostic?
    public let matchedRuleID: String
}

public enum ExternalTransportOutcome: String, CaseIterable, Hashable, Codable, Sendable {
    case confirmedSuccess
    case confirmedFailure
    case transportLost
}

public enum ExternalRetryDecision: String, CaseIterable, Hashable, Codable, Sendable {
    case complete
    case retrySameOperation
    case failKnownNoEffect
    case waitForReconciliation
}

public struct ExternalRetryInput: Hashable, Codable, Sendable {
    public let effectClass: ApprovalEffectClass
    public let idempotency: ExternalIdempotency
    public let retry: ExternalRetryPolicy.Kind
    public let transportOutcome: ExternalTransportOutcome

    public init(
        effectClass: ApprovalEffectClass,
        idempotency: ExternalIdempotency,
        retry: ExternalRetryPolicy.Kind,
        transportOutcome: ExternalTransportOutcome
    ) {
        self.effectClass = effectClass
        self.idempotency = idempotency
        self.retry = retry
        self.transportOutcome = transportOutcome
    }
}

public struct ExternalRetryOutcome: Hashable, Codable, Sendable {
    public let decision: ExternalRetryDecision
    public let retryDirective: ExternalRetryPolicy.Kind?
    public let uncertainOnTransportLoss: Bool
    public let runState: AgentRunState?
    public let diagnostic: ApprovalPolicyDiagnostic?
    public let matchedRuleID: String
}

/// Compiled, pure implementation of the version-1 approval semantic registry.
public enum ApprovalDecisionTables {
    public static let registryVersion: UInt16 = 1
    public static let authorizationCellCount = 7_680
    public static let approvalPresentationCellCount = 6
    public static let systemAccessCellCount = 10
    public static let retryAndTransportLossCellCount = 192

    public static func authorize(_ input: ApprovalAuthorizationInput) -> ApprovalAuthorizationOutcome {
        switch input.authority {
        case .missingStepGrant:
            return deny("AH-APPROVAL-AUTHORITY-001", .missingStepGrant)
        case .outsideRunCeiling:
            return deny("AH-APPROVAL-AUTHORITY-002", .outsideRunCeiling)
        case .planOutsideStepGrant:
            return deny("AH-APPROVAL-AUTHORITY-003", .planOutsideStepGrant)
        case .policyRevokedOrUnavailable:
            return deny("AH-APPROVAL-AUTHORITY-004", .policyUnavailable)
        case .valid:
            break
        }
        if input.feature == .disabled {
            return deny("AH-APPROVAL-AUTHORITY-005", .featureDisabled)
        }
        switch input.receipt {
        case .deniedCurrentRequest:
            return deny("AH-APPROVAL-AUTHORITY-006", .approvalDenied)
        case .cancelledCurrentRequest:
            return deny("AH-APPROVAL-AUTHORITY-007", .approvalCancelled)
        case .usableExact:
            switch input.effectClass {
            case .externalRead:
                return receipt("AH-APPROVAL-AUTHORITY-008", .exactInvocation, false)
            case .externalWrite:
                return receipt("AH-APPROVAL-AUTHORITY-009", .exactInvocation, true)
            case .strongExact:
                return receipt("AH-APPROVAL-AUTHORITY-010", .exactInvocation, true)
            case .codeExecution:
                return receipt("AH-APPROVAL-AUTHORITY-011", .exactInvocation, true)
            case .unknownExternal:
                return receipt("AH-APPROVAL-AUTHORITY-012", .exactInvocation, true)
            case .localPure, .appLocalRead, .appLocalWrite:
                break
            }
        case .usableConversationRead where input.effectClass == .externalRead:
            return receipt("AH-APPROVAL-AUTHORITY-013", .boundedConversationRead, false)
        default:
            break
        }
        switch input.effectClass {
        case .localPure:
            return local("AH-APPROVAL-AUTHORITY-014")
        case .appLocalRead:
            return local("AH-APPROVAL-AUTHORITY-015")
        case .appLocalWrite:
            return local("AH-APPROVAL-AUTHORITY-016")
        case .externalRead:
            return approval("AH-APPROVAL-AUTHORITY-017", .boundedConversationRead, false)
        case .externalWrite:
            return approval("AH-APPROVAL-AUTHORITY-018", .exactInvocation, true)
        case .strongExact:
            return approval("AH-APPROVAL-AUTHORITY-019", .exactInvocation, true)
        case .codeExecution:
            return approval("AH-APPROVAL-AUTHORITY-020", .exactInvocation, true)
        case .unknownExternal:
            return approval("AH-APPROVAL-AUTHORITY-021", .exactInvocation, true)
        }
    }

    public static func presentation(
        for authorization: ApprovalPresentationAuthorization,
        interaction: ApprovalInteractionContext
    ) -> ApprovalPresentationOutcome {
        switch authorization {
        case .approvalRequired where interaction == .foregroundInteractive:
            return ApprovalPresentationOutcome(
                decision: .presentApproval,
                runState: .waitingForApproval,
                matchedRuleID: "AH-APPROVAL-PRESENTATION-001"
            )
        case .approvalRequired:
            return ApprovalPresentationOutcome(
                decision: .deferApproval,
                runState: .waitingForApproval,
                matchedRuleID: "AH-APPROVAL-PRESENTATION-002"
            )
        case .authorized:
            return ApprovalPresentationOutcome(
                decision: .noPresentation,
                runState: nil,
                matchedRuleID: "AH-APPROVAL-PRESENTATION-003"
            )
        case .denied:
            return ApprovalPresentationOutcome(
                decision: .noPresentation,
                runState: nil,
                matchedRuleID: "AH-APPROVAL-PRESENTATION-004"
            )
        }
    }

    public static func systemAccess(
        _ state: SystemAccessState,
        interaction: ApprovalInteractionContext
    ) -> SystemAccessOutcome {
        switch state {
        case .notRequired:
            return SystemAccessOutcome(
                decision: .continue, runState: nil, diagnostic: nil,
                matchedRuleID: "AH-APPROVAL-SYSTEM-001"
            )
        case .granted:
            return SystemAccessOutcome(
                decision: .continue, runState: nil, diagnostic: nil,
                matchedRuleID: "AH-APPROVAL-SYSTEM-002"
            )
        case .denied:
            return SystemAccessOutcome(
                decision: .deny, runState: nil, diagnostic: .systemPermissionDenied,
                matchedRuleID: "AH-APPROVAL-SYSTEM-003"
            )
        case .temporarilyUnavailable:
            return SystemAccessOutcome(
                decision: .waitForForeground,
                runState: .waitingForForeground,
                diagnostic: .systemAccessTemporarilyUnavailable,
                matchedRuleID: "AH-APPROVAL-SYSTEM-004"
            )
        case .promptRequired where interaction == .foregroundInteractive:
            return SystemAccessOutcome(
                decision: .requestSystemPrompt, runState: nil, diagnostic: nil,
                matchedRuleID: "AH-APPROVAL-SYSTEM-005"
            )
        case .promptRequired:
            return SystemAccessOutcome(
                decision: .waitForForeground,
                runState: .waitingForForeground,
                diagnostic: .systemPromptRequiresForeground,
                matchedRuleID: "AH-APPROVAL-SYSTEM-006"
            )
        }
    }

    public static func retry(_ input: ExternalRetryInput) -> ExternalRetryOutcome {
        if input.transportOutcome == .confirmedSuccess {
            return retryOutcome("AH-APPROVAL-RETRY-001", .complete)
        }
        if input.transportOutcome == .confirmedFailure {
            if input.effectClass == .externalRead,
               input.idempotency == .pureRead,
               input.retry == .boundedExponential
            {
                return retryOutcome(
                    "AH-APPROVAL-RETRY-002",
                    .retrySameOperation,
                    retry: .boundedExponential
                )
            }
            return retryOutcome(
                "AH-APPROVAL-RETRY-003",
                .failKnownNoEffect,
                diagnostic: .confirmedOperationFailure
            )
        }
        switch input.effectClass {
        case .unknownExternal:
            return reconciliation("AH-APPROVAL-RETRY-004", .unknownExternalOutcome)
        case .strongExact:
            return reconciliation("AH-APPROVAL-RETRY-005", .strongEffectOutcomeUnknown)
        case .codeExecution:
            return reconciliation("AH-APPROVAL-RETRY-006", .codeExecutionOutcomeUnknown)
        case .externalWrite:
            if input.idempotency == .idempotencyKeyRequired,
               input.retry == .boundedExponential
            {
                return retryOutcome(
                    "AH-APPROVAL-RETRY-007",
                    .retrySameOperation,
                    retry: .boundedExponential
                )
            }
            return reconciliation("AH-APPROVAL-RETRY-008", .externalWriteOutcomeUnknown)
        case .externalRead:
            if input.idempotency == .pureRead,
               input.retry == .boundedExponential
            {
                return retryOutcome(
                    "AH-APPROVAL-RETRY-009",
                    .retrySameOperation,
                    retry: .boundedExponential
                )
            }
            return retryOutcome(
                "AH-APPROVAL-RETRY-010",
                .failKnownNoEffect,
                diagnostic: .externalReadTransportLost
            )
        case .localPure:
            return retryOutcome(
                "AH-APPROVAL-RETRY-011",
                .failKnownNoEffect,
                diagnostic: .unexpectedLocalTransportLoss
            )
        case .appLocalRead:
            return retryOutcome(
                "AH-APPROVAL-RETRY-012",
                .failKnownNoEffect,
                diagnostic: .unexpectedLocalTransportLoss
            )
        case .appLocalWrite:
            return retryOutcome(
                "AH-APPROVAL-RETRY-013",
                .failKnownNoEffect,
                diagnostic: .unexpectedLocalTransportLoss
            )
        }
    }

    private static func deny(
        _ ruleID: String,
        _ diagnostic: ApprovalPolicyDiagnostic
    ) -> ApprovalAuthorizationOutcome {
        ApprovalAuthorizationOutcome(
            decision: .deny,
            grantScope: .none,
            diagnostic: diagnostic,
            matchedRuleID: ruleID
        )
    }

    private static func local(_ ruleID: String) -> ApprovalAuthorizationOutcome {
        ApprovalAuthorizationOutcome(
            decision: .authorizeLocalPolicy,
            grantScope: .none,
            matchedRuleID: ruleID
        )
    }

    private static func receipt(
        _ ruleID: String,
        _ scope: ApprovalGrantScope,
        _ uncertain: Bool
    ) -> ApprovalAuthorizationOutcome {
        ApprovalAuthorizationOutcome(
            decision: .authorizeMatchingReceipt,
            grantScope: scope,
            uncertainOnTransportLoss: uncertain,
            matchedRuleID: ruleID
        )
    }

    private static func approval(
        _ ruleID: String,
        _ scope: ApprovalGrantScope,
        _ uncertain: Bool
    ) -> ApprovalAuthorizationOutcome {
        ApprovalAuthorizationOutcome(
            decision: .requireApproval,
            grantScope: scope,
            uncertainOnTransportLoss: uncertain,
            runState: .waitingForApproval,
            matchedRuleID: ruleID
        )
    }

    private static func retryOutcome(
        _ ruleID: String,
        _ decision: ExternalRetryDecision,
        retry: ExternalRetryPolicy.Kind? = nil,
        diagnostic: ApprovalPolicyDiagnostic? = nil
    ) -> ExternalRetryOutcome {
        ExternalRetryOutcome(
            decision: decision,
            retryDirective: retry,
            uncertainOnTransportLoss: false,
            runState: nil,
            diagnostic: diagnostic,
            matchedRuleID: ruleID
        )
    }

    private static func reconciliation(
        _ ruleID: String,
        _ diagnostic: ApprovalPolicyDiagnostic
    ) -> ExternalRetryOutcome {
        ExternalRetryOutcome(
            decision: .waitForReconciliation,
            retryDirective: nil,
            uncertainOnTransportLoss: true,
            runState: .waitingForReconciliation,
            diagnostic: diagnostic,
            matchedRuleID: ruleID
        )
    }
}
