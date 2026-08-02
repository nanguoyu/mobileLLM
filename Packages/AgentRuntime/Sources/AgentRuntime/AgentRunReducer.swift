// SPDX-License-Identifier: MIT

import AgentContracts

/// Pure, compiled implementation of the nine run-transition decision tables.
///
/// The production reducer deliberately has no registry loader. Versioned JSON registries are an
/// independent test oracle; unknown and impossible inputs are denied explicitly.
public enum AgentRunReducer {
    /// Reduces one typed decision-table input to a deterministic outcome.
    public static func reduce(_ input: AgentRunDecisionInput) -> AgentRunDecision {
        switch input {
        case .commandAdmission(let input):
            commandAdmission(input)
        case .pauseCancel(let input):
            pauseCancel(input)
        case .resume(let input):
            resume(input)
        case .approvalCommand(let input):
            approvalCommand(input)
        case .responseCommand(let input):
            responseCommand(input)
        case .reconciliationCommand(let input):
            reconciliationCommand(input)
        case .trustedProgress(let input):
            trustedProgress(input)
        case .quiescence(let input):
            quiescence(input)
        case .terminalFailure(let input):
            terminalFailure(input)
        case .unknown:
            .rejected(.unknownDomainValue)
        }
    }

    private static func commandAdmission(_ input: AgentCommandAdmissionInput) -> AgentRunDecision {
        switch input.wireValidity {
        case .malformed:
            return .rejected(.malformedCommandEnvelope)
        case .unsupportedVersion:
            return .rejected(.unsupportedProtocolVersion)
        case .valid:
            break
        }
        guard input.runLookup == .found else { return .rejected(.runNotFound) }
        switch input.deduplication {
        case .conflictingReuse:
            return .rejected(.duplicateCommandConflict)
        case .identicalReplay:
            return .replayOriginalReceipt
        case .unseen:
            break
        }
        guard input.terminality == .nonterminal else { return .rejected(.terminalRunImmutable) }
        guard input.expectedVersion == .matching else { return .stale }
        return .proceed
    }

    private static func pauseCancel(_ input: AgentPauseCancelInput) -> AgentRunDecision {
        let quiescible: Set<AgentRunState> = [
            .preparing, .waitingForModel, .generating, .validatingAction, .executingTools,
            .synthesizing,
        ]
        let canQuiesceOrFinishCancellation = quiescible.union([.pausing])

        if input.guardCondition == .unresolvedExternalOutcome,
           quiescible.contains(input.state)
                || (input.state == .pausing && input.command == .cancel)
        {
            return .accepted(.waitingForReconciliation)
        }
        if input.command == .cancel, input.guardCondition == .unresolvedExternalOutcome {
            return .rejected(.reconciliationRequiredBeforeCancellation)
        }
        if input.command == .pause, quiescible.contains(input.state) {
            return .accepted(.pausing)
        }
        if input.command == .cancel, canQuiesceOrFinishCancellation.contains(input.state) {
            return .accepted(.pausing)
        }
        if input.command == .cancel,
           [
               AgentRunState.created, .waitingForApproval, .waitingForUser, .paused,
               .waitingForForeground,
           ].contains(input.state)
        {
            return .accepted(.cancelled, terminalReason: .cancelledByUser)
        }
        return .rejected(.invalidPauseOrCancelForState)
    }

    private static func resume(_ input: AgentResumeInput) -> AgentRunDecision {
        guard input.guardCondition == .ready,
              input.state == .paused || input.state == .waitingForForeground
        else { return .rejected(.resumePreconditionFailed) }
        return .accepted(.preparing)
    }

    private static func approvalCommand(_ input: AgentApprovalCommandInput) -> AgentRunDecision {
        switch input.guardCondition {
        case .expired:
            return .rejected(.approvalExpired)
        case .invalidScope:
            return .rejected(.approvalScopeInvalid)
        case .planChanged:
            return .rejected(.preparedPlanChanged)
        case .systemPermissionDenied:
            return .rejected(.systemPermissionDenied)
        default:
            break
        }
        guard input.state == .waitingForApproval else {
            return .rejected(.invalidApprovalCommandForState)
        }
        switch input.guardCondition {
        case .exactApproved, .conversationReadApproved, .systemPermissionReady:
            return .accepted(.executingTools)
        case .denied, .cancelled:
            return .accepted(.synthesizing)
        case .systemPermissionPromptForeground:
            return .accepted(.waitingForApproval)
        case .systemPermissionPromptBackground:
            return .accepted(.waitingForForeground)
        case .expired, .invalidScope, .planChanged, .systemPermissionDenied:
            return .rejected(.invalidApprovalCommandForState)
        }
    }

    private static func responseCommand(_ input: AgentResponseCommandInput) -> AgentRunDecision {
        switch input.guardCondition {
        case .targetMismatch:
            return .rejected(.interactionTargetMismatch)
        case .schemaInvalid:
            return .rejected(.interactionResponseSchemaInvalid)
        case .valid:
            guard input.state == .waitingForUser else {
                return .rejected(.invalidResponseForState)
            }
            return .accepted(.waitingForModel)
        }
    }

    private static func reconciliationCommand(
        _ input: AgentReconciliationCommandInput
    ) -> AgentRunDecision {
        switch input.guardCondition {
        case .targetMismatch:
            return .rejected(.reconciliationTargetMismatch)
        case .proofInsufficient:
            return .rejected(.reconciliationProofInsufficient)
        default:
            break
        }
        guard input.state == .waitingForReconciliation else {
            return .rejected(.reconciliationRequired)
        }
        switch input.guardCondition {
        case .succeededProof, .failedProof:
            return .accepted(.synthesizing)
        case .abandonedConfirmed:
            return .accepted(.failed, terminalReason: .externalResultUncertain)
        case .targetMismatch, .proofInsufficient:
            return .rejected(.reconciliationRequired)
        }
    }

    private static func trustedProgress(_ input: AgentTrustedProgressInput) -> AgentRunDecision {
        if let rejection = progressGuardRejection(input.callbackGuard) { return rejection }
        switch (input.state, input.trigger, input.callbackGuard) {
        case (.created, .beginPreparation, .valid):
            return .accepted(.preparing)
        case (.preparing, .contextCommitted, .valid):
            return .accepted(.waitingForModel)
        case (.preparing, .recoveredToolBatchPending, .valid):
            return .accepted(.executingTools)
        case (.preparing, .recoveredToolBatchFailed, .valid):
            return .accepted(.synthesizing)
        case (.waitingForModel, .modelLeaseGranted, .valid),
             (.synthesizing, .modelLeaseGranted, .valid):
            return .accepted(.generating)
        case (.generating, .modelAttemptCompleted, .valid):
            return .accepted(.validatingAction)
        case (.generating, .modelRetryScheduled, .retryBudgetRemaining):
            return .accepted(.waitingForModel)
        case (.validatingAction, .finalAnswerCommitted, .valid):
            return .accepted(.completed, terminalReason: .completed)
        case (.validatingAction, .toolBatchNeedsApproval, .valid):
            return .accepted(.waitingForApproval)
        case (.validatingAction, .toolBatchAuthorized, .valid):
            return .accepted(.executingTools)
        case (.validatingAction, .userInputRequested, .valid):
            return .accepted(.waitingForUser)
        case (.validatingAction, .repairScheduled, .retryBudgetRemaining):
            return .accepted(.waitingForModel)
        case (.validatingAction, .repairExhausted, .retryBudgetExhausted):
            return .accepted(.failed, terminalReason: .internalFailure)
        case (.executingTools, .nextToolNeedsApproval, .valid):
            return .accepted(.waitingForApproval)
        case (.executingTools, .toolBatchCompleted, .valid):
            return .accepted(.waitingForModel)
        case (.executingTools, .toolBatchStopped, .valid):
            return .accepted(.synthesizing)
        case (.executingTools, .externalOutcomeUnknown, .effectOutcomeUncertain):
            return .accepted(.waitingForReconciliation)
        case (.preparing, .foregroundLost, .foregroundUnavailable),
             (.waitingForModel, .foregroundLost, .foregroundUnavailable),
             (.generating, .foregroundLost, .foregroundUnavailable),
             (.synthesizing, .foregroundLost, .foregroundUnavailable):
            return .accepted(.waitingForForeground)
        case (
            .waitingForApproval,
            .systemPermissionResolved,
            .systemPermissionPromptRequiredInBackground
        ):
            return .accepted(.waitingForForeground)
        case (.waitingForForeground, .systemPermissionResolved, .systemPermissionGranted):
            return .accepted(.preparing)
        case (.waitingForForeground, .systemPermissionResolved, .systemPermissionDenied):
            return .accepted(.failed, terminalReason: .permissionDenied)
        default:
            return .rejected(.invalidTrustedProgress)
        }
    }

    private static func progressGuardRejection(
        _ guardCondition: AgentTrustedCallbackGuard
    ) -> AgentRunDecision? {
        switch guardCondition {
        case .duplicateOutcome:
            .rejected(.duplicateOutcome)
        case .staleVersion:
            .rejected(.staleCallbackVersion)
        case .targetMismatch:
            .rejected(.callbackTargetMismatch)
        case .budgetUnavailable:
            .rejected(.budgetUnavailable)
        case .dependencyUnavailable:
            .rejected(.dependencyUnavailable)
        case .externalIntentOutstanding:
            .rejected(.externalIntentOutstanding)
        case .valid, .retryBudgetRemaining, .retryBudgetExhausted, .effectOutcomeUncertain,
             .foregroundUnavailable, .systemPermissionGranted, .systemPermissionDenied,
             .systemPermissionPromptRequiredInBackground:
            nil
        }
    }

    private static func quiescence(_ input: AgentQuiescenceInput) -> AgentRunDecision {
        switch input.callbackGuard {
        case .duplicateOutcome:
            return .rejected(.duplicateQuiescenceOutcome)
        case .staleVersion:
            return .rejected(.staleQuiescenceVersion)
        case .targetMismatch:
            return .rejected(.quiescenceTargetMismatch)
        case .externalIntentOutstanding:
            return .rejected(.externalIntentMustBecomeUncertain)
        case .valid:
            break
        }
        guard input.state == .pausing, input.callbackGuard == .valid else {
            return .rejected(.invalidQuiescenceOutcome)
        }
        switch input.outcome {
        case .userPause, .resourcePressurePaused:
            return .accepted(.paused)
        case .foregroundLost, .backgroundExpired, .resourcePressureForeground:
            return .accepted(.waitingForForeground)
        case .cancelled:
            return .accepted(.cancelled, terminalReason: .cancelledByUser)
        case .externalOutcomeUncertain:
            return .accepted(.waitingForReconciliation)
        }
    }

    private static func terminalFailure(_ input: AgentTerminalFailureInput) -> AgentRunDecision {
        switch input.callbackGuard {
        case .duplicateOutcome:
            return .rejected(.duplicateFailureOutcome)
        case .staleVersion:
            return .rejected(.staleFailureVersion)
        case .targetMismatch:
            return .rejected(.failureTargetMismatch)
        case .externalIntentOutstanding:
            return .rejected(.uncertainExternalIntentCannotFailClosed)
        case .valid:
            break
        }
        if input.state == .waitingForReconciliation {
            return .rejected(.explicitReconciliationRequired)
        }
        if input.state.isTerminal { return .rejected(.terminalRunImmutable) }
        return .accepted(.failed, terminalReason: input.failureReason.terminalReason)
    }
}
