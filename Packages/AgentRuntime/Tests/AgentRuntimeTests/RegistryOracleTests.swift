// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class RegistryOracleTests: XCTestCase {
    func testCompiledReducerMatchesAllFiveThousandFourHundredEightyRegistryCells() throws {
        let registry: DecisionRegistry = try loadRegistry(named: "run-transitions.v1.json")
        XCTAssertEqual(registry.completeness, "complete")

        let expectedCellCounts = [
            "commandAdmission": 72,
            "pauseCancelRouting": 128,
            "resumeRouting": 48,
            "approvalCommandRouting": 176,
            "responseCommandRouting": 48,
            "reconciliationCommandRouting": 80,
            "trustedProgressRouting": 3_808,
            "quiescenceRouting": 560,
            "terminalFailureRouting": 560,
        ]
        let groupedDomains = Dictionary(grouping: registry.domains, by: \.table)
        let fixedSeed: UInt64 = 0xA6E1_7001_D15C_0FFE
        let rotatingSeed = ProcessInfo.processInfo.environment["AGENT_HARNESS_ROTATING_SEED"]
            .flatMap(UInt64.init) ?? 0x2026_0802_5EED_0001

        for seed in [fixedSeed, rotatingSeed] {
            var generator = SplitMix64(seed: seed)
            var tables = expectedCellCounts.keys.sorted()
            tables.shuffle(using: &generator)
            var totalCells = 0
            var allWinningRuleIDs: Set<String> = []
            var acceptedSelfTransitions = 0

            for table in tables {
                var domains = try XCTUnwrap(groupedDomains[table])
                domains.shuffle(using: &generator)
                var cells = cartesianCells(domains)
                cells.shuffle(using: &generator)
                XCTAssertEqual(cells.count, expectedCellCounts[table], table)
                totalCells += cells.count

                var rules = registry.entries.filter { $0.table == table }
                rules.shuffle(using: &generator)
                var winningRuleIDs: Set<String> = []
                for cell in cells {
                    let matches = rules.filter { rule in
                        rule.conditions.allSatisfy { cell[$0.key] == $0.value }
                    }
                    let highestPriority = try XCTUnwrap(matches.map(\.priority).max(), table)
                    let winners = matches.filter { $0.priority == highestPriority }
                    XCTAssertEqual(winners.count, 1, "ambiguous/no winner: \(table) \(cell)")
                    let winner = try XCTUnwrap(winners.first)
                    winningRuleIDs.insert(winner.id)
                    allWinningRuleIDs.insert(winner.id)

                    let actual = AgentRunReducer.reduce(try typedInput(table: table, cell: cell))
                    let expected = try decision(from: winner.outcome)
                    XCTAssertEqual(actual, expected, "\(winner.id) for \(cell), seed \(seed)")
                    let input = try typedInput(table: table, cell: cell)
                    if actual.disposition == .accepted,
                       let source = input.sourceState,
                       let destination = actual.nextState
                    {
                        XCTAssertTrue(
                            AgentRunStateMachine.allows(input, from: source, to: destination),
                            winner.id
                        )
                        XCTAssertTrue(
                            AgentRunTransitionMatrix.allows(from: source, to: destination),
                            winner.id
                        )
                        if source == destination { acceptedSelfTransitions += 1 }
                    }
                }
                XCTAssertEqual(winningRuleIDs, Set(rules.map(\.id)), "dead rule in \(table)")
            }

            XCTAssertEqual(totalCells, 5_480)
            XCTAssertEqual(allWinningRuleIDs, Set(registry.entries.map(\.id)))
            XCTAssertEqual(allWinningRuleIDs.count, 123)
            XCTAssertEqual(acceptedSelfTransitions, 4)
        }
    }

    func testCompiledFiniteDomainsExactlyMatchRegistryDomains() throws {
        let registry: DecisionRegistry = try loadRegistry(named: "run-transitions.v1.json")
        for domain in registry.domains {
            let actual: Set<String> = switch (domain.table, domain.name) {
            case ("commandAdmission", "wireValidity"):
                Set(AgentCommandWireValidity.allCases.map(\.rawValue))
            case ("commandAdmission", "runLookup"):
                Set(AgentRunLookupResult.allCases.map(\.rawValue))
            case ("commandAdmission", "deduplication"):
                Set(AgentCommandDeduplication.allCases.map(\.rawValue))
            case ("commandAdmission", "terminality"):
                Set(AgentRunTerminality.allCases.map(\.rawValue))
            case ("commandAdmission", "expectedVersion"):
                Set(AgentExpectedVersionMatch.allCases.map(\.rawValue))
            case ("pauseCancelRouting", "state"), ("resumeRouting", "state"),
                 ("approvalCommandRouting", "state"), ("responseCommandRouting", "state"),
                 ("reconciliationCommandRouting", "state"),
                 ("trustedProgressRouting", "state"), ("quiescenceRouting", "state"),
                 ("terminalFailureRouting", "state"):
                Set(AgentRunState.allCases.map(\.rawValue))
            case ("pauseCancelRouting", "command"):
                Set(AgentPauseCancelCommand.allCases.map(\.rawValue))
            case ("pauseCancelRouting", "guard"):
                Set(AgentPauseCancelGuard.allCases.map(\.rawValue))
            case ("resumeRouting", "guard"):
                Set(AgentResumeGuard.allCases.map(\.rawValue))
            case ("approvalCommandRouting", "guard"):
                Set(AgentApprovalCommandGuard.allCases.map(\.rawValue))
            case ("responseCommandRouting", "guard"):
                Set(AgentResponseCommandGuard.allCases.map(\.rawValue))
            case ("reconciliationCommandRouting", "guard"):
                Set(AgentReconciliationCommandGuard.allCases.map(\.rawValue))
            case ("trustedProgressRouting", "trigger"):
                Set(AgentTrustedProgressTrigger.allCases.map(\.rawValue))
            case ("trustedProgressRouting", "callbackGuard"):
                Set(AgentTrustedCallbackGuard.allCases.map(\.rawValue))
            case ("quiescenceRouting", "quiescenceOutcome"):
                Set(AgentQuiescenceOutcome.allCases.map(\.rawValue))
            case ("quiescenceRouting", "callbackGuard"):
                Set(AgentQuiescenceCallbackGuard.allCases.map(\.rawValue))
            case ("terminalFailureRouting", "failureReason"):
                Set(AgentRunFailureReason.allCases.map(\.rawValue))
            case ("terminalFailureRouting", "callbackGuard"):
                Set(AgentTerminalFailureCallbackGuard.allCases.map(\.rawValue))
            default:
                throw OracleError.unknownDomain("\(domain.table).\(domain.name)")
            }
            XCTAssertEqual(actual, Set(domain.values), "\(domain.table).\(domain.name)")
        }
    }

    func testCompiledStateTraitsMatchCompleteStateRegistry() throws {
        let registry: StateRegistry = try loadRegistry(named: "run-states.v1.json")
        XCTAssertEqual(registry.completeness, "complete")
        XCTAssertEqual(registry.entries.count, 16)
        XCTAssertEqual(Set(registry.entries.map(\.name)), Set(AgentRunState.allCases.map(\.rawValue)))

        for entry in registry.entries {
            let state = try XCTUnwrap(AgentRunState(rawValue: entry.name))
            let traits = try XCTUnwrap(AgentRunStateMachine.traits(for: state))
            XCTAssertEqual(traits.isTerminal, entry.terminal, entry.name)
            XCTAssertEqual(traits.isResumable, entry.resumable, entry.name)
            XCTAssertEqual(traits.ownsExecutionSlot, entry.ownsExecutionSlot, entry.name)
            XCTAssertEqual(
                traits.allowedUserCommands.map(\.rawValue),
                entry.allowedUserCommands,
                entry.name
            )
            XCTAssertEqual(traits.isTerminal, state.isTerminal, entry.name)
        }
    }

    func testUnknownFutureInputFailsClosed() {
        let decision = AgentRunReducer.reduce(
            .unknown(table: "futureRouting", field: "futureAxis", value: "futureValue")
        )
        XCTAssertEqual(decision.disposition, .rejected)
        XCTAssertEqual(decision.diagnostic, .unknownDomainValue)
        XCTAssertNil(decision.nextState)
        XCTAssertNil(decision.terminalReason)
    }

    private func typedInput(
        table: String,
        cell: [String: String]
    ) throws -> AgentRunDecisionInput {
        func value<E: RawRepresentable>(_ key: String, _: E.Type) throws -> E where E.RawValue == String {
            let raw = try XCTUnwrap(cell[key], "missing \(key)")
            return try XCTUnwrap(E(rawValue: raw), "unknown \(key)=\(raw)")
        }
        switch table {
        case "commandAdmission":
            return .commandAdmission(
                AgentCommandAdmissionInput(
                    wireValidity: try value("wireValidity", AgentCommandWireValidity.self),
                    runLookup: try value("runLookup", AgentRunLookupResult.self),
                    deduplication: try value("deduplication", AgentCommandDeduplication.self),
                    terminality: try value("terminality", AgentRunTerminality.self),
                    expectedVersion: try value("expectedVersion", AgentExpectedVersionMatch.self)
                )
            )
        case "pauseCancelRouting":
            return .pauseCancel(
                AgentPauseCancelInput(
                    state: try value("state", AgentRunState.self),
                    command: try value("command", AgentPauseCancelCommand.self),
                    guardCondition: try value("guard", AgentPauseCancelGuard.self)
                )
            )
        case "resumeRouting":
            return .resume(
                AgentResumeInput(
                    state: try value("state", AgentRunState.self),
                    guardCondition: try value("guard", AgentResumeGuard.self)
                )
            )
        case "approvalCommandRouting":
            return .approvalCommand(
                AgentApprovalCommandInput(
                    state: try value("state", AgentRunState.self),
                    guardCondition: try value("guard", AgentApprovalCommandGuard.self)
                )
            )
        case "responseCommandRouting":
            return .responseCommand(
                AgentResponseCommandInput(
                    state: try value("state", AgentRunState.self),
                    guardCondition: try value("guard", AgentResponseCommandGuard.self)
                )
            )
        case "reconciliationCommandRouting":
            return .reconciliationCommand(
                AgentReconciliationCommandInput(
                    state: try value("state", AgentRunState.self),
                    guardCondition: try value("guard", AgentReconciliationCommandGuard.self)
                )
            )
        case "trustedProgressRouting":
            return .trustedProgress(
                AgentTrustedProgressInput(
                    state: try value("state", AgentRunState.self),
                    trigger: try value("trigger", AgentTrustedProgressTrigger.self),
                    callbackGuard: try value("callbackGuard", AgentTrustedCallbackGuard.self)
                )
            )
        case "quiescenceRouting":
            return .quiescence(
                AgentQuiescenceInput(
                    state: try value("state", AgentRunState.self),
                    outcome: try value("quiescenceOutcome", AgentQuiescenceOutcome.self),
                    callbackGuard: try value(
                        "callbackGuard",
                        AgentQuiescenceCallbackGuard.self
                    )
                )
            )
        case "terminalFailureRouting":
            return .terminalFailure(
                AgentTerminalFailureInput(
                    state: try value("state", AgentRunState.self),
                    failureReason: try value("failureReason", AgentRunFailureReason.self),
                    callbackGuard: try value(
                        "callbackGuard",
                        AgentTerminalFailureCallbackGuard.self
                    )
                )
            )
        default:
            throw OracleError.unknownTable(table)
        }
    }

    private func decision(from outcome: RegistryOutcome) throws -> AgentRunDecision {
        try AgentRunDecision(
            disposition: try XCTUnwrap(AgentRunDecisionDisposition(rawValue: outcome.disposition)),
            nextState: outcome.nextState.flatMap(AgentRunState.init(rawValue:)),
            terminalReason: outcome.terminalReason.flatMap(AgentTerminalReason.init(rawValue:)),
            diagnostic: outcome.diagnostic.flatMap(AgentRunDecisionDiagnostic.init(rawValue:))
        )
    }

    private func cartesianCells(_ domains: [RegistryDomain]) -> [[String: String]] {
        domains.reduce([[:]]) { partial, domain in
            partial.flatMap { cell in
                domain.values.map { value in
                    var expanded = cell
                    expanded[domain.name] = value
                    return expanded
                }
            }
        }
    }

    private func loadRegistry<T: Decodable>(named name: String) throws -> T {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { root.deleteLastPathComponent() }
        let url = root
            .appendingPathComponent("Verification/AgentHarness/Registries")
            .appendingPathComponent(name)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private enum OracleError: Error {
    case unknownTable(String)
    case unknownDomain(String)
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct DecisionRegistry: Decodable {
    let completeness: String
    let domains: [RegistryDomain]
    let entries: [RegistryRule]
}

private struct RegistryDomain: Decodable {
    let table: String
    let name: String
    let values: [String]
}

private struct RegistryRule: Decodable {
    let id: String
    let table: String
    let priority: Int
    let conditions: [String: String]
    let outcome: RegistryOutcome
}

private struct RegistryOutcome: Decodable {
    let disposition: String
    let nextState: String?
    let terminalReason: String?
    let diagnostic: String?
}

private struct StateRegistry: Decodable {
    let completeness: String
    let entries: [StateRegistryEntry]
}

private struct StateRegistryEntry: Decodable {
    let name: String
    let terminal: Bool
    let resumable: Bool
    let ownsExecutionSlot: Bool
    let allowedUserCommands: [String]
}
