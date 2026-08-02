// SPDX-License-Identifier: MIT

import AgentContracts

/// Validation result for a command envelope before command-specific routing.
public enum AgentCommandWireValidity: String, CaseIterable, Hashable, Codable, Sendable {
    case valid
    case unsupportedVersion
    case malformed
}

/// Result of resolving a command's run identity.
public enum AgentRunLookupResult: String, CaseIterable, Hashable, Codable, Sendable {
    case found
    case missing
}

/// Result of comparing a command identity with the durable deduplication index.
public enum AgentCommandDeduplication: String, CaseIterable, Hashable, Codable, Sendable {
    case unseen
    case identicalReplay
    case conflictingReuse
}

/// Whether the target run is already terminal.
public enum AgentRunTerminality: String, CaseIterable, Hashable, Codable, Sendable {
    case nonterminal
    case terminal
}

/// Compare-and-swap version relationship for an incoming command.
public enum AgentExpectedVersionMatch: String, CaseIterable, Hashable, Codable, Sendable {
    case matching
    case stale
}

/// Complete finite-domain input for command admission.
public struct AgentCommandAdmissionInput: Hashable, Codable, Sendable {
    public let wireValidity: AgentCommandWireValidity
    public let runLookup: AgentRunLookupResult
    public let deduplication: AgentCommandDeduplication
    public let terminality: AgentRunTerminality
    public let expectedVersion: AgentExpectedVersionMatch

    public init(
        wireValidity: AgentCommandWireValidity,
        runLookup: AgentRunLookupResult,
        deduplication: AgentCommandDeduplication,
        terminality: AgentRunTerminality,
        expectedVersion: AgentExpectedVersionMatch
    ) {
        self.wireValidity = wireValidity
        self.runLookup = runLookup
        self.deduplication = deduplication
        self.terminality = terminality
        self.expectedVersion = expectedVersion
    }
}

/// User command routed through the pause/cancel table.
public enum AgentPauseCancelCommand: String, CaseIterable, Hashable, Codable, Sendable {
    case pause
    case cancel
}

/// Stable-boundary condition observed while routing pause or cancellation.
public enum AgentPauseCancelGuard: String, CaseIterable, Hashable, Codable, Sendable {
    case safeBoundary
    case cancellableWork
    case noncancellableExternalIntent
    case unresolvedExternalOutcome
}

/// Complete finite-domain input for pause/cancel routing.
public struct AgentPauseCancelInput: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let command: AgentPauseCancelCommand
    public let guardCondition: AgentPauseCancelGuard

    public init(
        state: AgentRunState,
        command: AgentPauseCancelCommand,
        guardCondition: AgentPauseCancelGuard
    ) {
        self.state = state
        self.command = command
        self.guardCondition = guardCondition
    }
}

/// Dependency/lifecycle guard used by explicit resume.
public enum AgentResumeGuard: String, CaseIterable, Hashable, Codable, Sendable {
    case ready
    case foregroundUnavailable
    case dependencyUnavailable
}

/// Complete finite-domain input for resume routing.
public struct AgentResumeInput: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let guardCondition: AgentResumeGuard

    public init(state: AgentRunState, guardCondition: AgentResumeGuard) {
        self.state = state
        self.guardCondition = guardCondition
    }
}

/// Result of validating a user approval command and any required system permission.
public enum AgentApprovalCommandGuard: String, CaseIterable, Hashable, Codable, Sendable {
    case exactApproved
    case conversationReadApproved
    case denied
    case cancelled
    case expired
    case invalidScope
    case planChanged
    case systemPermissionReady
    case systemPermissionPromptForeground
    case systemPermissionPromptBackground
    case systemPermissionDenied
}

/// Complete finite-domain input for approval-command routing.
public struct AgentApprovalCommandInput: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let guardCondition: AgentApprovalCommandGuard

    public init(state: AgentRunState, guardCondition: AgentApprovalCommandGuard) {
        self.state = state
        self.guardCondition = guardCondition
    }
}

/// Result of binding and validating a durable user-input response.
public enum AgentResponseCommandGuard: String, CaseIterable, Hashable, Codable, Sendable {
    case valid
    case targetMismatch
    case schemaInvalid
}

/// Complete finite-domain input for response-command routing.
public struct AgentResponseCommandInput: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let guardCondition: AgentResponseCommandGuard

    public init(state: AgentRunState, guardCondition: AgentResponseCommandGuard) {
        self.state = state
        self.guardCondition = guardCondition
    }
}

/// Proof result supplied for an uncertain external outcome.
public enum AgentReconciliationCommandGuard: String, CaseIterable, Hashable, Codable, Sendable {
    case succeededProof
    case failedProof
    case abandonedConfirmed
    case targetMismatch
    case proofInsufficient
}

/// Complete finite-domain input for reconciliation-command routing.
public struct AgentReconciliationCommandInput: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let guardCondition: AgentReconciliationCommandGuard

    public init(state: AgentRunState, guardCondition: AgentReconciliationCommandGuard) {
        self.state = state
        self.guardCondition = guardCondition
    }
}

/// Trusted internal progress signal emitted at a stable execution boundary.
public enum AgentTrustedProgressTrigger: String, CaseIterable, Hashable, Codable, Sendable {
    case beginPreparation
    case contextCommitted
    case recoveredToolBatchPending
    case recoveredToolBatchFailed
    case modelLeaseGranted
    case modelAttemptCompleted
    case modelRetryScheduled
    case finalAnswerCommitted
    case toolBatchNeedsApproval
    case toolBatchAuthorized
    case userInputRequested
    case repairScheduled
    case repairExhausted
    case nextToolNeedsApproval
    case toolBatchCompleted
    case toolBatchStopped
    case externalOutcomeUnknown
    case foregroundLost
    case systemPermissionResolved
}

/// Validation result shared by trusted asynchronous runtime callbacks.
public enum AgentTrustedCallbackGuard: String, CaseIterable, Hashable, Codable, Sendable {
    case valid
    case duplicateOutcome
    case staleVersion
    case targetMismatch
    case budgetUnavailable
    case dependencyUnavailable
    case externalIntentOutstanding
    case retryBudgetRemaining
    case retryBudgetExhausted
    case effectOutcomeUncertain
    case foregroundUnavailable
    case systemPermissionGranted
    case systemPermissionDenied
    case systemPermissionPromptRequiredInBackground
}

/// Complete finite-domain input for trusted progress routing.
public struct AgentTrustedProgressInput: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let trigger: AgentTrustedProgressTrigger
    public let callbackGuard: AgentTrustedCallbackGuard

    public init(
        state: AgentRunState,
        trigger: AgentTrustedProgressTrigger,
        callbackGuard: AgentTrustedCallbackGuard
    ) {
        self.state = state
        self.trigger = trigger
        self.callbackGuard = callbackGuard
    }
}

/// Validation result for a quiescence callback.
public enum AgentQuiescenceCallbackGuard: String, CaseIterable, Hashable, Codable, Sendable {
    case valid
    case duplicateOutcome
    case staleVersion
    case targetMismatch
    case externalIntentOutstanding
}

/// Stable result of cooperatively releasing active runtime resources.
public enum AgentQuiescenceOutcome: String, CaseIterable, Hashable, Codable, Sendable {
    case userPause
    case foregroundLost
    case backgroundExpired
    case cancelled
    case resourcePressurePaused
    case resourcePressureForeground
    case externalOutcomeUncertain
}

/// Complete finite-domain input for quiescence routing.
public struct AgentQuiescenceInput: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let outcome: AgentQuiescenceOutcome
    public let callbackGuard: AgentQuiescenceCallbackGuard

    public init(
        state: AgentRunState,
        outcome: AgentQuiescenceOutcome,
        callbackGuard: AgentQuiescenceCallbackGuard
    ) {
        self.state = state
        self.outcome = outcome
        self.callbackGuard = callbackGuard
    }
}

/// Validation result for a generic terminal-failure callback.
public enum AgentTerminalFailureCallbackGuard: String, CaseIterable, Hashable, Codable, Sendable {
    case valid
    case duplicateOutcome
    case staleVersion
    case targetMismatch
    case externalIntentOutstanding
}

/// Non-cancellation failure reasons accepted by generic terminal-failure routing.
public enum AgentRunFailureReason: String, CaseIterable, Hashable, Codable, Sendable {
    case budgetExceeded
    case noProgress
    case permissionDenied
    case toolUnavailable
    case modelUnavailable
    case contextUnsatisfiable
    case internalFailure

    /// Terminal contract reason represented by this failure input.
    public var terminalReason: AgentTerminalReason {
        switch self {
        case .budgetExceeded: .budgetExceeded
        case .noProgress: .noProgress
        case .permissionDenied: .permissionDenied
        case .toolUnavailable: .toolUnavailable
        case .modelUnavailable: .modelUnavailable
        case .contextUnsatisfiable: .contextUnsatisfiable
        case .internalFailure: .internalFailure
        }
    }
}

/// Complete finite-domain input for terminal-failure routing.
public struct AgentTerminalFailureInput: Hashable, Codable, Sendable {
    public let state: AgentRunState
    public let failureReason: AgentRunFailureReason
    public let callbackGuard: AgentTerminalFailureCallbackGuard

    public init(
        state: AgentRunState,
        failureReason: AgentRunFailureReason,
        callbackGuard: AgentTerminalFailureCallbackGuard
    ) {
        self.state = state
        self.failureReason = failureReason
        self.callbackGuard = callbackGuard
    }
}

/// One of the nine versioned run-transition decision-table inputs.
public enum AgentRunDecisionInput: Hashable, Codable, Sendable {
    case commandAdmission(AgentCommandAdmissionInput)
    case pauseCancel(AgentPauseCancelInput)
    case resume(AgentResumeInput)
    case approvalCommand(AgentApprovalCommandInput)
    case responseCommand(AgentResponseCommandInput)
    case reconciliationCommand(AgentReconciliationCommandInput)
    case trustedProgress(AgentTrustedProgressInput)
    case quiescence(AgentQuiescenceInput)
    case terminalFailure(AgentTerminalFailureInput)

    /// Explicit fail-closed representation for an unknown table, field, or future domain value.
    case unknown(table: String, field: String, value: String)

    /// State against which a stateful decision is routed.
    public var sourceState: AgentRunState? {
        switch self {
        case .commandAdmission, .unknown:
            nil
        case .pauseCancel(let input):
            input.state
        case .resume(let input):
            input.state
        case .approvalCommand(let input):
            input.state
        case .responseCommand(let input):
            input.state
        case .reconciliationCommand(let input):
            input.state
        case .trustedProgress(let input):
            input.state
        case .quiescence(let input):
            input.state
        case .terminalFailure(let input):
            input.state
        }
    }
}

/// Stable disposition emitted by a run decision table.
public enum AgentRunDecisionDisposition: String, CaseIterable, Hashable, Codable, Sendable {
    case accepted
    case proceed
    case rejected
    case replayOriginalReceipt
    case stale
}

/// Stable diagnostic emitted for a denied or stale decision.
public enum AgentRunDecisionDiagnostic: String, CaseIterable, Hashable, Codable, Sendable {
    case approvalExpired
    case approvalScopeInvalid
    case budgetUnavailable
    case callbackTargetMismatch
    case dependencyUnavailable
    case duplicateCommandConflict
    case duplicateFailureOutcome
    case duplicateOutcome
    case duplicateQuiescenceOutcome
    case explicitReconciliationRequired
    case externalIntentMustBecomeUncertain
    case externalIntentOutstanding
    case failureTargetMismatch
    case interactionResponseSchemaInvalid
    case interactionTargetMismatch
    case invalidApprovalCommandForState
    case invalidPauseOrCancelForState
    case invalidQuiescenceOutcome
    case invalidResponseForState
    case invalidTrustedProgress
    case malformedCommandEnvelope
    case preparedPlanChanged
    case quiescenceTargetMismatch
    case reconciliationProofInsufficient
    case reconciliationRequired
    case reconciliationRequiredBeforeCancellation
    case reconciliationTargetMismatch
    case resumePreconditionFailed
    case runNotFound
    case staleCallbackVersion
    case staleExpectedVersion
    case staleFailureVersion
    case staleQuiescenceVersion
    case systemPermissionDenied
    case terminalRunImmutable
    case uncertainExternalIntentCannotFailClosed
    case unknownDomainValue
    case unsupportedProtocolVersion
}

/// Structural validation failure for a decision value decoded or constructed across a boundary.
public enum AgentRunDecisionContractError: Error, Hashable, Sendable {
    case invalidOutcome
}

/// Pure output from one compiled run-transition table decision.
public struct AgentRunDecision: Hashable, Codable, Sendable {
    public let disposition: AgentRunDecisionDisposition
    public let nextState: AgentRunState?
    public let terminalReason: AgentTerminalReason?
    public let diagnostic: AgentRunDecisionDiagnostic?

    public init(
        disposition: AgentRunDecisionDisposition,
        nextState: AgentRunState? = nil,
        terminalReason: AgentTerminalReason? = nil,
        diagnostic: AgentRunDecisionDiagnostic? = nil
    ) throws {
        switch disposition {
        case .accepted:
            guard let nextState, diagnostic == nil else {
                throw AgentRunDecisionContractError.invalidOutcome
            }
            switch nextState {
            case .completed:
                guard terminalReason == .completed else {
                    throw AgentRunDecisionContractError.invalidOutcome
                }
            case .cancelled:
                guard terminalReason == .cancelledByUser else {
                    throw AgentRunDecisionContractError.invalidOutcome
                }
            case .failed:
                guard let terminalReason,
                      terminalReason != .completed,
                      terminalReason != .cancelledByUser
                else { throw AgentRunDecisionContractError.invalidOutcome }
            case .created, .preparing, .waitingForModel, .generating, .validatingAction,
                 .waitingForApproval, .executingTools, .waitingForUser, .synthesizing,
                 .pausing, .paused, .waitingForForeground, .waitingForReconciliation:
                guard terminalReason == nil else {
                    throw AgentRunDecisionContractError.invalidOutcome
                }
            @unknown default:
                throw AgentRunDecisionContractError.invalidOutcome
            }
        case .rejected:
            guard nextState == nil, terminalReason == nil, diagnostic != nil else {
                throw AgentRunDecisionContractError.invalidOutcome
            }
        case .stale:
            guard nextState == nil, terminalReason == nil, diagnostic == .staleExpectedVersion else {
                throw AgentRunDecisionContractError.invalidOutcome
            }
        case .proceed, .replayOriginalReceipt:
            guard nextState == nil, terminalReason == nil, diagnostic == nil else {
                throw AgentRunDecisionContractError.invalidOutcome
            }
        }
        self.disposition = disposition
        self.nextState = nextState
        self.terminalReason = terminalReason
        self.diagnostic = diagnostic
    }

    static func accepted(
        _ nextState: AgentRunState,
        terminalReason: AgentTerminalReason? = nil
    ) -> Self {
        try! Self(disposition: .accepted, nextState: nextState, terminalReason: terminalReason)
    }

    static func rejected(_ diagnostic: AgentRunDecisionDiagnostic) -> Self {
        try! Self(disposition: .rejected, diagnostic: diagnostic)
    }

    static let proceed = try! Self(disposition: .proceed)
    static let replayOriginalReceipt = try! Self(disposition: .replayOriginalReceipt)
    static let stale = try! Self(disposition: .stale, diagnostic: .staleExpectedVersion)

    /// Decodes and revalidates the disposition/output shape.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                disposition: container.decode(AgentRunDecisionDisposition.self, forKey: .disposition),
                nextState: container.decodeIfPresent(AgentRunState.self, forKey: .nextState),
                terminalReason: container.decodeIfPresent(
                    AgentTerminalReason.self,
                    forKey: .terminalReason
                ),
                diagnostic: container.decodeIfPresent(
                    AgentRunDecisionDiagnostic.self,
                    forKey: .diagnostic
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case disposition, nextState, terminalReason, diagnostic
    }
}
