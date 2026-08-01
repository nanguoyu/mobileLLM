// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import AgentContracts

final class ExecutionContractMatrixTests: XCTestCase {
    func testRunTransitionMatrixExhaustivelyCoversEveryStatePair() {
        let expected: [AgentRunState: Set<AgentRunState>] = [
            .created: [.created, .preparing, .failed, .cancelled],
            .preparing: [
                .preparing, .waitingForModel, .waitingForForeground, .waitingForReconciliation,
                .pausing, .failed,
            ],
            .waitingForModel: [
                .waitingForModel, .generating, .waitingForForeground, .waitingForReconciliation,
                .pausing, .failed,
            ],
            .generating: [
                .generating, .waitingForModel, .validatingAction, .waitingForForeground,
                .waitingForReconciliation, .pausing, .failed,
            ],
            .validatingAction: [
                .validatingAction, .waitingForModel, .waitingForApproval, .executingTools,
                .waitingForUser, .waitingForReconciliation, .pausing, .completed, .failed,
            ],
            .waitingForApproval: [
                .waitingForApproval, .executingTools, .synthesizing, .waitingForForeground,
                .cancelled, .failed,
            ],
            .executingTools: [
                .executingTools, .waitingForModel, .waitingForApproval,
                .waitingForReconciliation, .synthesizing, .pausing, .failed,
            ],
            .waitingForUser: [.waitingForUser, .waitingForModel, .cancelled, .failed],
            .synthesizing: [
                .synthesizing, .generating, .waitingForForeground, .waitingForReconciliation,
                .pausing, .failed,
            ],
            .pausing: [
                .pausing, .paused, .waitingForForeground, .waitingForReconciliation,
                .cancelled, .failed,
            ],
            .paused: [.paused, .preparing, .cancelled, .failed],
            .waitingForForeground: [.waitingForForeground, .preparing, .cancelled, .failed],
            .waitingForReconciliation: [.waitingForReconciliation, .synthesizing, .failed],
            .completed: [.completed],
            .failed: [.failed],
            .cancelled: [.cancelled],
        ]

        XCTAssertEqual(AgentRunState.allCases.count, 16)
        XCTAssertEqual(expected.count, AgentRunState.allCases.count)
        for source in AgentRunState.allCases {
            for destination in AgentRunState.allCases {
                XCTAssertEqual(
                    AgentRunTransitionMatrix.allows(from: source, to: destination),
                    expected[source, default: []].contains(destination),
                    "unexpected transition result for \(source.rawValue) -> \(destination.rawValue)"
                )
            }
        }
    }

    func testEveryDeclaredRegistryEdgeAgreesWithRuntimeMatrix() throws {
        let data = try Data(contentsOf: repositoryFile(
            "Verification/AgentHarness/Registries/run-transitions.v1.json"
        ))
        let registry = try JSONDecoder().decode(RunTransitionRegistry.self, from: data)

        XCTAssertEqual(registry.completeness, "complete")
        let registryEdges = try acceptedRegistryEdges(registry)
        XCTAssertFalse(registryEdges.isEmpty)

        let matrixEdges = Set(AgentRunState.allCases.flatMap { source in
            AgentRunState.allCases.compactMap { destination in
                source != destination
                    && AgentRunTransitionMatrix.allows(from: source, to: destination)
                    ? "\(source.rawValue)->\(destination.rawValue)"
                    : nil
            }
        })
        XCTAssertEqual(
            matrixEdges,
            registryEdges,
            "runtime matrix and complete registry must expose the same non-reflexive edge union"
        )

        for entry in registry.entries where entry.outcome.disposition == "rejected" {
            XCTAssertNil(
                entry.outcome.nextState,
                "rejected registry rows must not claim an edge: \(entry.id)"
            )
        }
    }

    func testTerminalStatusReasonAndFailureClassificationMatrixIsExhaustive() {
        let failures = AgentFailureClassification.allCases.map { classification in
            (classification, failure(for: classification))
        }
        XCTAssertEqual(failures.count, 7)

        for state in [AgentRunState.completed, .failed, .cancelled] {
            XCTAssertTrue(state.isTerminal)
            for reason in AgentTerminalReason.allCases {
                for candidate in [(nil as AgentFailure?)] + failures.map(\.1) {
                    let accepted = (try? AgentRunStatus(
                        state: state,
                        stateVersion: 1,
                        terminalReason: reason,
                        failure: candidate
                    )) != nil
                    XCTAssertEqual(
                        accepted,
                        expectedTerminalStatus(
                            state: state,
                            reason: reason,
                            classification: candidate?.classification
                        ),
                        "unexpected terminal status result for \(state.rawValue), "
                            + "\(reason.rawValue), \(candidate?.classification.rawValue ?? "nil")"
                    )
                }
            }
            XCTAssertThrowsError(try AgentRunStatus(state: state, stateVersion: 1))
        }

        let approvalID = TestValues.id(ApprovalIDDomain.self, 210)
        XCTAssertThrowsError(try AgentRunStatus(
            state: .completed,
            stateVersion: 1,
            terminalReason: .completed,
            blockingReason: .approval(approvalID: approvalID)
        ))
    }

    func testEveryNonterminalStatusRequiresItsExactBlockingAndFailureShape() throws {
        let approvalID = TestValues.id(ApprovalIDDomain.self, 211)
        let interactionID = TestValues.id(InteractionRequestIDDomain.self, 212)
        let invocationID = TestValues.id(ToolInvocationIDDomain.self, 213)
        let validBlocking: [AgentRunState: AgentBlockingReason] = [
            .waitingForModel: .modelResource,
            .waitingForApproval: .approval(approvalID: approvalID),
            .waitingForUser: .userInput(requestID: interactionID),
            .paused: .paused,
            .waitingForForeground: .foreground,
            .waitingForReconciliation: .reconciliation(invocationID: invocationID),
        ]

        for state in AgentRunState.allCases where !state.isTerminal {
            let failure: AgentFailure? = state == .waitingForReconciliation
                ? failure(for: .potentiallySideEffecting)
                : nil
            XCTAssertNoThrow(try AgentRunStatus(
                state: state,
                stateVersion: 1,
                failure: failure,
                blockingReason: validBlocking[state]
            ))
            XCTAssertThrowsError(try AgentRunStatus(
                state: state,
                stateVersion: 1,
                terminalReason: .internalFailure,
                failure: failure,
                blockingReason: validBlocking[state]
            ))
            if let expected = validBlocking[state] {
                let wrong: AgentBlockingReason = expected.kind == .paused ? .foreground : .paused
                XCTAssertThrowsError(try AgentRunStatus(
                    state: state,
                    stateVersion: 1,
                    failure: failure,
                    blockingReason: wrong
                ))
            } else {
                XCTAssertThrowsError(try AgentRunStatus(
                    state: state,
                    stateVersion: 1,
                    blockingReason: .paused
                ))
            }
        }

        for classification in AgentFailureClassification.allCases {
            let candidate = failure(for: classification)
            XCTAssertEqual(
                (try? AgentRunStatus(
                    state: .waitingForModel,
                    stateVersion: 1,
                    failure: candidate,
                    blockingReason: .modelResource
                )) != nil,
                classification == .transient || classification == .budgetRelated
            )
            XCTAssertEqual(
                (try? AgentRunStatus(
                    state: .waitingForForeground,
                    stateVersion: 1,
                    failure: candidate,
                    blockingReason: .foreground
                )) != nil,
                classification == .transient || classification == .permissionRelated
            )
        }
    }

    func testUserInputResponsesEnforceInMemoryAndDecodedJSONBounds() throws {
        let requestID = TestValues.id(InteractionRequestIDDomain.self, 214)
        let accepted = try UserInputResponse(
            requestID: requestID,
            expectedRunStateVersion: 1,
            value: .object(["answer": .array([.string("yes"), .integer(1)])])
        )
        try assertContractRoundTrip(accepted)

        XCTAssertThrowsError(try UserInputResponse(
            requestID: requestID,
            expectedRunStateVersion: 1,
            value: .string(String(repeating: "x", count: CanonicalJSON.maximumBytes + 1))
        ))

        var tooDeep: JSONValue = .null
        for _ in 0 ..< 65 { tooDeep = .array([tooDeep]) }
        XCTAssertThrowsError(try UserInputResponse(
            requestID: requestID,
            expectedRunStateVersion: 1,
            value: tooDeep
        ))
        XCTAssertThrowsError(try AgentAnswer(structuredOutput: tooDeep))

        let tooMany = JSONValue.array(Array(
            repeating: .null,
            count: AgentWireDecodingLimits.inlineValue.maximumCollectionItems + 1
        ))
        XCTAssertThrowsError(try UserInputResponse(
            requestID: requestID,
            expectedRunStateVersion: 1,
            value: tooMany
        ))
        XCTAssertThrowsError(try AgentAnswer(structuredOutput: tooMany))

        let forged = try replacingJSONField(
            in: encodedJSON(accepted),
            path: ["value"],
            with: String(repeating: "x", count: CanonicalJSON.maximumBytes + 1)
        )
        XCTAssertThrowsError(try JSONDecoder().decode(UserInputResponse.self, from: forged))
    }
}

private extension ExecutionContractMatrixTests {
    struct RunTransitionRegistry: Decodable {
        let completeness: String
        let domains: [Domain]
        let entries: [Entry]

        struct Domain: Decodable {
            let table: String
            let name: String
            let values: [String]
        }

        struct Entry: Decodable {
            let id: String
            let table: String
            let priority: Int
            let conditions: [String: String]
            let outcome: Outcome

            struct Outcome: Decodable {
                let disposition: String
                let nextState: String?
            }
        }
    }

    func acceptedRegistryEdges(_ registry: RunTransitionRegistry) throws -> Set<String> {
        let stateTables = Set(registry.domains.filter { $0.name == "state" }.map(\.table))
        var result: Set<String> = []

        for table in stateTables {
            let domains = registry.domains.filter { $0.table == table }
            var cells: [[String: String]] = [[:]]
            for domain in domains {
                cells = cells.flatMap { partial in
                    domain.values.map { value in
                        var cell = partial
                        cell[domain.name] = value
                        return cell
                    }
                }
            }

            let rules = registry.entries.filter { $0.table == table }
            for cell in cells {
                let matches = rules.filter { rule in
                    rule.conditions.allSatisfy { cell[$0.key] == $0.value }
                }
                let highestPriority = try XCTUnwrap(matches.map(\.priority).max(), table)
                let winners = matches.filter { $0.priority == highestPriority }
                XCTAssertEqual(
                    winners.count,
                    1,
                    "complete registry cell must resolve to one winner: \(table) \(cell)"
                )
                guard let winner = winners.first,
                      winner.outcome.disposition == "accepted",
                      let source = cell["state"],
                      let destination = winner.outcome.nextState,
                      source != destination
                else { continue }
                result.insert("\(source)->\(destination)")
            }
        }
        return result
    }

    func repositoryFile(_ relativePath: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ExecutionContractMatrixTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "repository file not found: \(relativePath)"]
        )
    }

    func failure(for classification: AgentFailureClassification) -> AgentFailure {
        let externalEffect: ExternalEffectDisposition = classification == .potentiallySideEffecting
            ? .uncertain
            : .confirmedNone
        let action: AgentRequiredUserAction = switch classification {
        case .permissionRelated: .updateSystemPermission
        case .incompatible: .restoreDependency
        case .potentiallySideEffecting: .reconcile
        default: .none
        }
        return TestValues.failure(
            classification: classification,
            externalEffect: externalEffect,
            action: action
        )
    }

    func expectedTerminalStatus(
        state: AgentRunState,
        reason: AgentTerminalReason,
        classification: AgentFailureClassification?
    ) -> Bool {
        switch state {
        case .completed:
            reason == .completed && classification == nil
        case .cancelled:
            reason == .cancelledByUser && (classification == nil || classification == .cancelled)
        case .failed:
            switch reason {
            case .budgetExceeded: classification == .budgetRelated
            case .noProgress: classification == .permanent
            case .permissionDenied: classification == .permissionRelated
            case .toolUnavailable, .modelUnavailable, .contextUnsatisfiable:
                classification == .incompatible
            case .externalResultUncertain: classification == .potentiallySideEffecting
            case .internalFailure: classification == .transient || classification == .permanent
            case .completed, .cancelledByUser: false
            }
        default:
            false
        }
    }
}
