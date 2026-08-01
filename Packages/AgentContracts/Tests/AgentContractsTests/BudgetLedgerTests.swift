// SPDX-License-Identifier: MIT

import XCTest
@testable import AgentContracts

final class BudgetLedgerTests: XCTestCase {
    private static let cumulativeDimensions: Set<BudgetDimension> = [
        .modelAttempts,
        .toolInvocations,
        .structuredRepairs,
        .activeMilliseconds,
        .inputTokens,
        .outputTokens,
        .networkRequestBytes,
        .networkResponseBytesTotal,
        .generatedArtifactBytes,
        .persistedOutputBytes,
    ]

    private static let maximumDimensions: Set<BudgetDimension> = [
        .repeatedCallsPerFingerprint,
        .consecutiveNoProgressActions,
        .contextTokensPerAttempt,
        .networkResponseBytesPerOperation,
        .peakMemoryBytes,
    ]

    func testEveryBudgetDimensionRejectsAboveAndAcceptsBelowOrEqual() throws {
        XCTAssertEqual(BudgetDimension.allCases.count, 15)
        XCTAssertEqual(Self.cumulativeDimensions.union(Self.maximumDimensions), Set(BudgetDimension.allCases))
        XCTAssertTrue(Self.cumulativeDimensions.isDisjoint(with: Self.maximumDimensions))

        let budget = try makeBudget(limit: 10)
        for dimension in BudgetDimension.allCases {
            for accepted in [UInt64(9), 10] {
                XCTAssertNoThrow(
                    try BudgetLedgerSnapshot(
                        budget: budget,
                        consumed: usage(dimension, accepted)
                    ),
                    "\(dimension.rawValue) should accept \(accepted) against limit 10"
                )

                let ledger = try BudgetLedgerSnapshot(budget: budget)
                let reservation = try makeReservation(id: UInt16(100 + accepted), dimension, accepted)
                XCTAssertNoThrow(
                    try ledger.reserving(reservation),
                    "\(dimension.rawValue) reservation should accept \(accepted) against limit 10"
                )
            }

            XCTAssertThrowsError(
                try BudgetLedgerSnapshot(
                    budget: budget,
                    consumed: usage(dimension, 11)
                )
            ) { error in
                guard case AgentContractError.budgetExceeded(let actual, 10, 11) = error else {
                    return XCTFail("Unexpected error for \(dimension.rawValue): \(error)")
                }
                XCTAssertEqual(actual, dimension)
            }

            let ledger = try BudgetLedgerSnapshot(budget: budget)
            let excessive = try makeReservation(id: 300, dimension, 11)
            XCTAssertThrowsError(try ledger.reserving(excessive)) { error in
                guard case AgentContractError.budgetExceeded(let actual, 10, 11) = error else {
                    return XCTFail("Unexpected reservation error for \(dimension.rawValue): \(error)")
                }
                XCTAssertEqual(actual, dimension)
            }
        }
    }

    func testReservationAccountingIsCumulativeOrMaximumForEveryDimension() throws {
        let budget = try makeBudget(limit: 10)

        for dimension in Self.cumulativeDimensions {
            var ledger = try BudgetLedgerSnapshot(budget: budget)
            ledger = try ledger.reserving(makeReservation(id: 1, dimension, 6))
            XCTAssertThrowsError(try ledger.reserving(makeReservation(id: 2, dimension, 6))) { error in
                guard case AgentContractError.budgetExceeded(let actual, 10, 12) = error else {
                    return XCTFail("Expected cumulative overflow for \(dimension.rawValue), got \(error)")
                }
                XCTAssertEqual(actual, dimension)
            }
        }

        for dimension in Self.maximumDimensions {
            var ledger = try BudgetLedgerSnapshot(budget: budget)
            ledger = try ledger.reserving(makeReservation(id: 1, dimension, 6))
            ledger = try ledger.reserving(makeReservation(id: 2, dimension, 6))
            XCTAssertEqual(ledger.reservations.count, 2, "\(dimension.rawValue) must use max accounting")
        }
    }

    func testSettlementUsesCumulativeOrMaximumAccountingForEveryDimension() throws {
        let budget = try makeBudget(limit: 20)

        for dimension in Self.cumulativeDimensions {
            let reservation = try makeReservation(id: 10, dimension, 4)
            let ledger = try BudgetLedgerSnapshot(
                budget: budget,
                consumed: usage(dimension, 5),
                reservations: [reservation]
            )
            let settled = try ledger.settling(
                reservationID: reservation.id,
                actualUsage: usage(dimension, 4)
            )
            XCTAssertEqual(settled.consumed.quantities[dimension], 9)
            XCTAssertTrue(settled.reservations.isEmpty)
        }

        for dimension in Self.maximumDimensions {
            let reservation = try makeReservation(id: 10, dimension, 4)
            let ledger = try BudgetLedgerSnapshot(
                budget: budget,
                consumed: usage(dimension, 5),
                reservations: [reservation]
            )
            let settled = try ledger.settling(
                reservationID: reservation.id,
                actualUsage: usage(dimension, 4)
            )
            XCTAssertEqual(settled.consumed.quantities[dimension], 5)
            XCTAssertTrue(settled.reservations.isEmpty)
        }
    }

    func testReserveIsIdempotentAndConflictingReuseFailsClosed() throws {
        let ledger = try BudgetLedgerSnapshot(budget: makeBudget(limit: 20))
        let reservation = try makeReservation(id: 20, .toolInvocations, 3, reason: "tool.call")

        let reserved = try ledger.reserving(reservation)
        XCTAssertEqual(try reserved.reserving(reservation), reserved)

        let changedUsage = try makeReservation(id: 20, .toolInvocations, 4, reason: "tool.call")
        XCTAssertThrowsError(try reserved.reserving(changedUsage)) { error in
            XCTAssertEqual(error as? AgentContractError, .conflictingReservation(reservation.id))
        }
        let changedReason = try makeReservation(id: 20, .toolInvocations, 3, reason: "tool.other")
        XCTAssertThrowsError(try reserved.reserving(changedReason)) { error in
            XCTAssertEqual(error as? AgentContractError, .conflictingReservation(reservation.id))
        }
    }

    func testSettleAndReleaseEnforceReservationIdentityAndMaximumUsage() throws {
        let reservation = try BudgetReservation(
            id: TestValues.id(BudgetReservationIDDomain.self, 30),
            maximumUsage: AgentUsage(
                quantities: BudgetQuantities([
                    .modelAttempts: 2,
                    .outputTokens: 100,
                    .peakMemoryBytes: 500,
                ])
            ),
            reason: "model.attempt"
        )
        let ledger = try BudgetLedgerSnapshot(
            budget: makeBudget(limit: 1_000),
            reservations: [reservation]
        )
        let actual = AgentUsage(
            quantities: BudgetQuantities([
                .modelAttempts: 1,
                .outputTokens: 75,
                .peakMemoryBytes: 400,
            ])
        )
        let settled = try ledger.settling(reservationID: reservation.id, actualUsage: actual)
        XCTAssertEqual(settled.consumed.quantities[.modelAttempts], 1)
        XCTAssertEqual(settled.consumed.quantities[.outputTokens], 75)
        XCTAssertEqual(settled.consumed.quantities[.peakMemoryBytes], 400)
        for dimension in BudgetDimension.allCases
            where dimension != .modelAttempts && dimension != .outputTokens && dimension != .peakMemoryBytes
        {
            XCTAssertEqual(settled.consumed.quantities[dimension], 0)
        }
        XCTAssertTrue(settled.reservations.isEmpty)

        let released = try ledger.releasing(reservationID: reservation.id)
        XCTAssertEqual(released.consumed, .zero)
        XCTAssertTrue(released.reservations.isEmpty)

        let unknown = TestValues.id(BudgetReservationIDDomain.self, 31)
        XCTAssertThrowsError(try ledger.releasing(reservationID: unknown)) { error in
            XCTAssertEqual(error as? AgentContractError, .reservationNotFound(unknown))
        }
        XCTAssertThrowsError(try ledger.settling(reservationID: unknown, actualUsage: .zero)) { error in
            XCTAssertEqual(error as? AgentContractError, .reservationNotFound(unknown))
        }

        let excessive = AgentUsage(quantities: BudgetQuantities([.outputTokens: 101]))
        XCTAssertThrowsError(
            try ledger.settling(reservationID: reservation.id, actualUsage: excessive)
        ) { error in
            XCTAssertEqual(error as? AgentContractError, .usageExceedsReservation(reservation.id))
        }
    }

    func testArithmeticAndFirstReleaseDefaultOverflowFailClosed() throws {
        let unlimited = try makeBudget(limit: UInt64.max)
        let reservation = try makeReservation(id: 40, .inputTokens, 1)
        XCTAssertThrowsError(
            try BudgetLedgerSnapshot(
                budget: unlimited,
                consumed: usage(.inputTokens, UInt64.max),
                reservations: [reservation]
            )
        ) { error in
            XCTAssertEqual(error as? AgentContractError, .arithmeticOverflow(dimension: .inputTokens))
        }

        let overflowingContext = UInt64.max / 6 + 1
        XCTAssertThrowsError(
            try AgentBudget.firstReleaseDefaults(
                contextTokensPerAttempt: overflowingContext,
                outputTokens: 1,
                peakMemoryBytes: 1
            )
        ) { error in
            XCTAssertEqual(error as? AgentContractError, .arithmeticOverflow(dimension: .inputTokens))
        }
    }

    func testBudgetCodableRejectsMissingDuplicateNoncanonicalAndOverBudgetForgeries() throws {
        let canonicalEntries = BudgetDimension.allCases.sorted().map {
            BudgetQuantities.Entry(dimension: $0, value: 10)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BudgetQuantities.self,
                from: encodedJSON(Array(canonicalEntries.reversed()))
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BudgetQuantities.self,
                from: encodedJSON(canonicalEntries + [canonicalEntries[0]])
            )
        )

        let incomplete = BudgetQuantities(entries: canonicalEntries.dropLast())
        let forgedBudget = ForgedBudget(
            limits: incomplete,
            maximumThermalState: .fair,
            memoryPressureResponse: .pause
        )
        XCTAssertThrowsError(try JSONDecoder().decode(AgentBudget.self, from: encodedJSON(forgedBudget)))

        let budget = try makeBudget(limit: 10)
        let overBudget = ForgedLedger(
            budget: budget,
            consumed: usage(.outputTokens, 11),
            reservations: []
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(BudgetLedgerSnapshot.self, from: encodedJSON(overBudget))
        )

        let first = try makeReservation(id: 50, .modelAttempts, 1)
        let second = try makeReservation(id: 51, .modelAttempts, 1)
        let noncanonical = ForgedLedger(
            budget: budget,
            consumed: .zero,
            reservations: [second, first]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(BudgetLedgerSnapshot.self, from: encodedJSON(noncanonical)),
            "Persisted reservations must not silently normalize forged ordering"
        )

        let duplicate = ForgedLedger(
            budget: budget,
            consumed: .zero,
            reservations: [first, first]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(BudgetLedgerSnapshot.self, from: encodedJSON(duplicate))
        )
    }

    private func makeBudget(limit: UInt64) throws -> AgentBudget {
        try AgentBudget(
            limits: BudgetQuantities(
                Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map { ($0, limit) })
            ),
            maximumThermalState: .fair,
            memoryPressureResponse: .pause
        )
    }

    private func usage(_ dimension: BudgetDimension, _ value: UInt64) -> AgentUsage {
        AgentUsage(quantities: BudgetQuantities([dimension: value]))
    }

    private func makeReservation(
        id: UInt16,
        _ dimension: BudgetDimension,
        _ value: UInt64,
        reason: String = "test.reservation"
    ) throws -> BudgetReservation {
        try BudgetReservation(
            id: TestValues.id(BudgetReservationIDDomain.self, id),
            maximumUsage: usage(dimension, value),
            reason: reason
        )
    }
}

private struct ForgedBudget: Encodable {
    let limits: BudgetQuantities
    let maximumThermalState: AgentThermalLimit
    let memoryPressureResponse: AgentMemoryPressureResponse
}

private struct ForgedLedger: Encodable {
    let budget: AgentBudget
    let consumed: AgentUsage
    let reservations: [BudgetReservation]
}
