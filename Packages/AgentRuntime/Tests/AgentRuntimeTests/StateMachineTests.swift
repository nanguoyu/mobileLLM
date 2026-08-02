// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class StateMachineTests: XCTestCase {
    func testOnlyRegisteredSelfTransitionsAreAcceptedAndAdvanceVersion() throws {
        for guardCondition in [
            AgentPauseCancelGuard.safeBoundary,
            .cancellableWork,
            .noncancellableExternalIntent,
        ] {
            let input = AgentRunDecisionInput.pauseCancel(
                AgentPauseCancelInput(
                    state: .pausing,
                    command: .cancel,
                    guardCondition: guardCondition
                )
            )
            XCTAssertTrue(AgentRunStateMachine.allows(input, from: .pausing, to: .pausing))
            let next = try AgentRunStateMachine.applying(
                input,
                to: try AgentRunStateSnapshot(state: .pausing, stateVersion: 41)
            )
            XCTAssertEqual(next.state, .pausing)
            XCTAssertEqual(next.stateVersion, 42)
        }

        let approval = AgentRunDecisionInput.approvalCommand(
            AgentApprovalCommandInput(
                state: .waitingForApproval,
                guardCondition: .systemPermissionPromptForeground
            )
        )
        XCTAssertTrue(
            AgentRunStateMachine.allows(
                approval,
                from: .waitingForApproval,
                to: .waitingForApproval
            )
        )
        let next = try AgentRunStateMachine.applying(
            approval,
            to: try AgentRunStateSnapshot(state: .waitingForApproval, stateVersion: 7)
        )
        XCTAssertEqual(next.stateVersion, 8)

        let ordinary = AgentRunDecisionInput.trustedProgress(
            AgentTrustedProgressInput(
                state: .created,
                trigger: .beginPreparation,
                callbackGuard: .valid
            )
        )
        XCTAssertFalse(AgentRunStateMachine.allows(ordinary, from: .created, to: .created))
        XCTAssertFalse(AgentRunStateMachine.allows(ordinary, from: .created, to: .generating))
    }

    func testTerminalStatesRejectEveryStatefulDecisionFamily() {
        for state in [AgentRunState.completed, .failed, .cancelled] {
            let inputs: [AgentRunDecisionInput] = [
                .pauseCancel(
                    AgentPauseCancelInput(
                        state: state,
                        command: .cancel,
                        guardCondition: .safeBoundary
                    )
                ),
                .resume(AgentResumeInput(state: state, guardCondition: .ready)),
                .approvalCommand(
                    AgentApprovalCommandInput(state: state, guardCondition: .exactApproved)
                ),
                .responseCommand(
                    AgentResponseCommandInput(state: state, guardCondition: .valid)
                ),
                .reconciliationCommand(
                    AgentReconciliationCommandInput(state: state, guardCondition: .succeededProof)
                ),
                .trustedProgress(
                    AgentTrustedProgressInput(
                        state: state,
                        trigger: .beginPreparation,
                        callbackGuard: .valid
                    )
                ),
                .quiescence(
                    AgentQuiescenceInput(
                        state: state,
                        outcome: .userPause,
                        callbackGuard: .valid
                    )
                ),
                .terminalFailure(
                    AgentTerminalFailureInput(
                        state: state,
                        failureReason: .internalFailure,
                        callbackGuard: .valid
                    )
                ),
            ]
            for input in inputs {
                XCTAssertNotEqual(AgentRunStateMachine.decide(input).disposition, .accepted)
            }
        }
    }

    func testApplyingAcceptedTerminalTransitionPreservesReason() throws {
        let input = AgentRunDecisionInput.trustedProgress(
            AgentTrustedProgressInput(
                state: .validatingAction,
                trigger: .finalAnswerCommitted,
                callbackGuard: .valid
            )
        )
        let result = try AgentRunStateMachine.applying(
            input,
            to: try AgentRunStateSnapshot(state: .validatingAction, stateVersion: 10)
        )
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.stateVersion, 11)
        XCTAssertEqual(result.terminalReason, .completed)
    }

    func testApplyingFailsClosedForStatelessRejectedMismatchedAndOverflowInputs() throws {
        let admission = AgentRunDecisionInput.commandAdmission(
            AgentCommandAdmissionInput(
                wireValidity: .valid,
                runLookup: .found,
                deduplication: .unseen,
                terminality: .nonterminal,
                expectedVersion: .matching
            )
        )
        XCTAssertThrowsError(
            try AgentRunStateMachine.applying(
                admission,
                to: AgentRunStateSnapshot(state: .created, stateVersion: 1)
            )
        ) { XCTAssertEqual($0 as? AgentRunStateMachineError, .statelessDecisionCannotTransition) }

        let rejected = AgentRunDecisionInput.resume(
            AgentResumeInput(state: .created, guardCondition: .ready)
        )
        XCTAssertThrowsError(
            try AgentRunStateMachine.applying(
                rejected,
                to: AgentRunStateSnapshot(state: .created, stateVersion: 1)
            )
        )

        let accepted = AgentRunDecisionInput.resume(
            AgentResumeInput(state: .paused, guardCondition: .ready)
        )
        XCTAssertThrowsError(
            try AgentRunStateMachine.applying(
                accepted,
                to: AgentRunStateSnapshot(state: .waitingForForeground, stateVersion: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentRunStateMachineError,
                .sourceStateMismatch(expected: .paused, actual: .waitingForForeground)
            )
        }
        XCTAssertThrowsError(
            try AgentRunStateMachine.applying(
                accepted,
                to: AgentRunStateSnapshot(state: .paused, stateVersion: .max)
            )
        ) { XCTAssertEqual($0 as? AgentRunStateMachineError, .versionOverflow) }
    }

    func testSnapshotAndDecisionValuesRejectInvalidShapesIncludingDecode() throws {
        XCTAssertThrowsError(try AgentRunStateSnapshot(state: .created, stateVersion: 0))
        XCTAssertThrowsError(
            try AgentRunStateSnapshot(
                state: .completed,
                stateVersion: 1,
                terminalReason: .internalFailure
            )
        )
        XCTAssertThrowsError(
            try AgentRunStateSnapshot(
                state: .failed,
                stateVersion: 1,
                terminalReason: .completed
            )
        )
        XCTAssertThrowsError(
            try AgentRunStateSnapshot(
                state: .created,
                stateVersion: 1,
                terminalReason: .completed
            )
        )
        XCTAssertNoThrow(
            try AgentRunStateSnapshot(
                state: .cancelled,
                stateVersion: 1,
                terminalReason: .cancelledByUser
            )
        )

        XCTAssertThrowsError(
            try AgentRunDecision(disposition: .accepted, nextState: nil)
        )
        XCTAssertThrowsError(
            try AgentRunDecision(
                disposition: .rejected,
                nextState: .created,
                diagnostic: .invalidTrustedProgress
            )
        )
        XCTAssertThrowsError(
            try AgentRunDecision(disposition: .stale, diagnostic: .runNotFound)
        )
        XCTAssertThrowsError(
            try AgentRunDecision(disposition: .proceed, diagnostic: .runNotFound)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AgentRunStateSnapshot.self,
                from: Data(#"{"state":"completed","stateVersion":1,"terminalReason":null}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AgentRunDecision.self,
                from: Data(
                    #"{"disposition":"accepted","nextState":null,"terminalReason":null,"diagnostic":null}"#.utf8
                )
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AgentPauseCancelGuard.self,
                from: Data(#""futureGuard""#.utf8)
            )
        )
    }

    func testFailureReasonMappingIsExhaustive() {
        let expected: [AgentRunFailureReason: AgentTerminalReason] = [
            .budgetExceeded: .budgetExceeded,
            .noProgress: .noProgress,
            .permissionDenied: .permissionDenied,
            .toolUnavailable: .toolUnavailable,
            .modelUnavailable: .modelUnavailable,
            .contextUnsatisfiable: .contextUnsatisfiable,
            .internalFailure: .internalFailure,
        ]
        for reason in AgentRunFailureReason.allCases {
            XCTAssertEqual(reason.terminalReason, expected[reason])
        }
    }

    func testValidatedDecisionAndSnapshotRoundTrip() throws {
        let decision = AgentRunStateMachine.decide(
            .reconciliationCommand(
                AgentReconciliationCommandInput(
                    state: .waitingForReconciliation,
                    guardCondition: .abandonedConfirmed
                )
            )
        )
        let decodedDecision = try JSONDecoder().decode(
            AgentRunDecision.self,
            from: JSONEncoder().encode(decision)
        )
        XCTAssertEqual(decodedDecision, decision)

        let snapshot = try AgentRunStateSnapshot(
            state: .failed,
            stateVersion: 12,
            terminalReason: .externalResultUncertain
        )
        let decodedSnapshot = try JSONDecoder().decode(
            AgentRunStateSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(decodedSnapshot, snapshot)
    }
}
