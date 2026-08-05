// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-AUTH-002
final class ApprovalDecisionTableTests: XCTestCase {
    func testAuthorizationTableEnumeratesEveryCellAndEveryRegisteredWinner() {
        var cells = 0
        var winners: Set<String> = []
        for authority in ApprovalAuthorityValidity.allCases {
            for receipt in ApprovalReceiptValidity.allCases {
                for effect in ApprovalEffectClass.allCases {
                    for feature in ApprovalFeatureState.allCases {
                        for interaction in ApprovalInteractionContext.allCases {
                            cells += 1
                            let output = ApprovalDecisionTables.authorize(
                                ApprovalAuthorizationInput(
                                    authority: authority,
                                    receipt: receipt,
                                    effectClass: effect,
                                    feature: feature,
                                    interaction: interaction
                                )
                            )
                            winners.insert(output.matchedRuleID)
                            if authority != .valid || feature == .disabled {
                                XCTAssertEqual(output.decision, .deny)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cells, ApprovalDecisionTables.authorizationCellCount)
        XCTAssertEqual(winners.count, 22)
        XCTAssertEqual(
            winners,
            Set((1 ... 22).map { String(format: "AH-APPROVAL-AUTHORITY-%03d", $0) })
        )
    }

    func testAuthorizationSecurityPrecedenceAndEffectDefaults() {
        for effect in ApprovalEffectClass.allCases {
            let denied = ApprovalDecisionTables.authorize(
                input(authority: .outsideRunCeiling, receipt: .usableExact, effect: effect)
            )
            XCTAssertEqual(denied.decision, .deny)
            XCTAssertEqual(denied.diagnostic, .outsideRunCeiling)

            let featureDenied = ApprovalDecisionTables.authorize(
                input(receipt: .usableExact, effect: effect, feature: .disabled)
            )
            XCTAssertEqual(featureDenied.decision, .deny)
        }
        for local in [
            ApprovalEffectClass.localPure, .appLocalRead, .appLocalWrite,
        ] {
            let output = ApprovalDecisionTables.authorize(input(effect: local))
            XCTAssertEqual(output.decision, .authorizeLocalPolicy)
            XCTAssertEqual(output.grantScope, .none)
            XCTAssertFalse(output.uncertainOnTransportLoss)
        }
        XCTAssertEqual(
            ApprovalDecisionTables.authorize(input(receipt: .usableConversationRead, effect: .externalWrite)).decision,
            .requireApproval
        )
        XCTAssertEqual(
            ApprovalDecisionTables.authorize(input(receipt: .usableExact, effect: .unknownExternal)).grantScope,
            .exactInvocation
        )
        XCTAssertTrue(
            ApprovalDecisionTables.authorize(input(effect: .strongExact)).uncertainOnTransportLoss
        )
    }

    func testHighestRiskRanksLocalEffectClassesWithoutUnknownFallback() {
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [AgentEffect.localPure]),
            .localPure
        )
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [AgentEffect.localRead]),
            .appLocalRead
        )
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [AgentEffect.localWrite]),
            .appLocalWrite
        )
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [AgentEffect.localPure, .localRead]),
            .appLocalRead
        )
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [AgentEffect.localRead, .localWrite]),
            .appLocalWrite
        )
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [AgentEffect.localPure, .localWrite, .localRead]),
            .appLocalWrite
        )
        XCTAssertNil(ApprovalEffectClass.highestRisk(in: []))
    }

    func testApprovalPresentationEnumeratesSixCellsAndFourRules() {
        var cells = 0
        var winners: Set<String> = []
        for decision in ApprovalPresentationAuthorization.allCases {
            for interaction in ApprovalInteractionContext.allCases {
                cells += 1
                let result = ApprovalDecisionTables.presentation(
                    for: decision,
                    interaction: interaction
                )
                winners.insert(result.matchedRuleID)
                if decision == .approvalRequired {
                    XCTAssertEqual(result.runState, .waitingForApproval)
                    XCTAssertEqual(
                        result.decision,
                        interaction == .foregroundInteractive ? .presentApproval : .deferApproval
                    )
                } else {
                    XCTAssertEqual(result.decision, .noPresentation)
                    XCTAssertNil(result.runState)
                }
            }
        }
        XCTAssertEqual(cells, ApprovalDecisionTables.approvalPresentationCellCount)
        XCTAssertEqual(winners.count, 4)
    }

    func testSystemAccessEnumeratesTenCellsAndNeverPromptsInBackground() {
        var cells = 0
        var winners: Set<String> = []
        for state in SystemAccessState.allCases {
            for interaction in ApprovalInteractionContext.allCases {
                cells += 1
                let result = ApprovalDecisionTables.systemAccess(state, interaction: interaction)
                winners.insert(result.matchedRuleID)
                if interaction == .background {
                    XCTAssertNotEqual(result.decision, .requestSystemPrompt)
                }
                if state == .denied { XCTAssertEqual(result.decision, .deny) }
                if state == .promptRequired, interaction == .background {
                    XCTAssertEqual(result.runState, .waitingForForeground)
                }
            }
        }
        XCTAssertEqual(cells, ApprovalDecisionTables.systemAccessCellCount)
        XCTAssertEqual(winners.count, 6)
    }

    func testRetryTableEnumeratesEveryCellAndEveryRegisteredWinner() {
        var cells = 0
        var winners: Set<String> = []
        for effect in ApprovalEffectClass.allCases {
            for idempotency in ExternalIdempotency.allCases {
                for retry in [ExternalRetryPolicy.Kind.never, .boundedExponential] {
                    for transport in ExternalTransportOutcome.allCases {
                        cells += 1
                        let output = ApprovalDecisionTables.retry(
                            ExternalRetryInput(
                                effectClass: effect,
                                idempotency: idempotency,
                                retry: retry,
                                transportOutcome: transport
                            )
                        )
                        winners.insert(output.matchedRuleID)
                        if transport == .confirmedSuccess {
                            XCTAssertEqual(output.decision, .complete)
                        }
                        if transport == .transportLost,
                           [.unknownExternal, .strongExact, .codeExecution].contains(effect)
                        {
                            XCTAssertEqual(output.decision, .waitForReconciliation)
                            XCTAssertTrue(output.uncertainOnTransportLoss)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cells, ApprovalDecisionTables.retryAndTransportLossCellCount)
        XCTAssertEqual(winners.count, 13)
        XCTAssertEqual(
            winners,
            Set((1 ... 13).map { String(format: "AH-APPROVAL-RETRY-%03d", $0) })
        )
    }

    func testRetryOnlyUsesFrozenSafeSemantics() {
        let keyedWrite = ApprovalDecisionTables.retry(
            ExternalRetryInput(
                effectClass: .externalWrite,
                idempotency: .idempotencyKeyRequired,
                retry: .boundedExponential,
                transportOutcome: .transportLost
            )
        )
        XCTAssertEqual(keyedWrite.decision, .retrySameOperation)
        XCTAssertEqual(keyedWrite.retryDirective, .boundedExponential)

        for idempotency in [
            ExternalIdempotency.pureRead, .reconciliationAvailable, .nonIdempotent,
        ] {
            let output = ApprovalDecisionTables.retry(
                ExternalRetryInput(
                    effectClass: .externalWrite,
                    idempotency: idempotency,
                    retry: .boundedExponential,
                    transportOutcome: .transportLost
                )
            )
            XCTAssertEqual(output.decision, .waitForReconciliation)
        }
        let readWithoutRetry = ApprovalDecisionTables.retry(
            ExternalRetryInput(
                effectClass: .externalRead,
                idempotency: .pureRead,
                retry: .never,
                transportOutcome: .transportLost
            )
        )
        XCTAssertEqual(readWithoutRetry.decision, .failKnownNoEffect)
        XCTAssertFalse(readWithoutRetry.uncertainOnTransportLoss)
    }

    func testEffectNormalizationUsesHighestTrustedRisk() {
        XCTAssertNil(ApprovalEffectClass.highestRisk(in: [] as [AgentEffect]))
        XCTAssertEqual(ApprovalEffectClass.highestRisk(in: [.localPure]), .localPure)
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [.externalWrite, .networkRead]),
            .externalWrite
        )
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [.unknownExternal, .destructive, .codeExecution]),
            .unknownExternal
        )
        XCTAssertEqual(
            ApprovalEffectClass.highestRisk(in: [.externalCommunication, .financial]),
            .strongExact
        )
    }

    private func input(
        authority: ApprovalAuthorityValidity = .valid,
        receipt: ApprovalReceiptValidity = .none,
        effect: ApprovalEffectClass,
        feature: ApprovalFeatureState = .notApplicable,
        interaction: ApprovalInteractionContext = .foregroundInteractive
    ) -> ApprovalAuthorizationInput {
        ApprovalAuthorizationInput(
            authority: authority,
            receipt: receipt,
            effectClass: effect,
            feature: feature,
            interaction: interaction
        )
    }
}
