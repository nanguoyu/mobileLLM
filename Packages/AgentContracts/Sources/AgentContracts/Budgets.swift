// SPDX-License-Identifier: MIT

import Foundation

/// A hard resource dimension tracked by immutable budgets and usage ledgers.
public enum BudgetDimension: String, CaseIterable, Hashable, Codable, Sendable, Comparable {
    /// Total model attempts, including a structured-repair attempt when it invokes a model.
    case modelAttempts
    /// Completed or attempted tool invocations reserved before execution.
    case toolInvocations
    /// Structured-output repair passes.
    case structuredRepairs
    /// Executions allowed for one normalized call fingerprint.
    case repeatedCallsPerFingerprint
    /// Consecutive model actions that make no progress.
    case consecutiveNoProgressActions
    /// Active run time; durable wait states do not accrue this quantity.
    case activeMilliseconds
    /// Input tokens consumed by model attempts.
    case inputTokens
    /// Generated output tokens consumed by model attempts.
    case outputTokens
    /// Maximum compiled context tokens for one model attempt.
    case contextTokensPerAttempt
    /// Network bytes sent over the complete run.
    case networkRequestBytes
    /// Maximum network bytes received by one external operation.
    case networkResponseBytesPerOperation
    /// Network bytes received over the complete run.
    case networkResponseBytesTotal
    /// Newly generated artifact bytes over the complete run.
    case generatedArtifactBytes
    /// Persisted output bytes over the complete run.
    case persistedOutputBytes
    /// Peak resident bytes observed by the run.
    case peakMemoryBytes

    /// Orders dimensions by their stable wire identity.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    fileprivate var accounting: BudgetAccounting {
        switch self {
        case .repeatedCallsPerFingerprint,
             .consecutiveNoProgressActions,
             .contextTokensPerAttempt,
             .networkResponseBytesPerOperation,
             .peakMemoryBytes:
            .maximum
        default:
            .cumulative
        }
    }
}

private enum BudgetAccounting {
    case cumulative
    case maximum
}

/// Deterministically encoded quantities for budget limits, reservations, or usage.
public struct BudgetQuantities: Hashable, Codable, Sendable {
    /// One normalized dimension/value entry.
    public struct Entry: Hashable, Codable, Sendable, Comparable {
        /// Resource dimension.
        public let dimension: BudgetDimension
        /// Nonnegative integer quantity in the unit named by the dimension.
        public let value: UInt64

        /// Creates a dimension/value entry.
        public init(dimension: BudgetDimension, value: UInt64) {
            self.dimension = dimension
            self.value = value
        }

        /// Orders entries by their stable dimension identity.
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.dimension < rhs.dimension }
    }

    /// Entries in stable order with exactly one value per represented dimension.
    public let entries: [Entry]

    /// Creates normalized quantities; later duplicate values replace earlier values.
    public init(_ values: [BudgetDimension: UInt64] = [:]) {
        entries = values.map(Entry.init).sorted()
    }

    /// Creates normalized quantities from entries; later duplicate values replace earlier values.
    public init(entries: some Sequence<Entry>) {
        var values: [BudgetDimension: UInt64] = [:]
        for entry in entries { values[entry.dimension] = entry.value }
        self.init(values)
    }

    /// Returns a dimension's value, defaulting to zero for unrepresented usage.
    public subscript(_ dimension: BudgetDimension) -> UInt64 {
        entries.first(where: { $0.dimension == dimension })?.value ?? 0
    }

    /// Returns whether a dimension was explicitly represented.
    public func contains(_ dimension: BudgetDimension) -> Bool {
        entries.contains { $0.dimension == dimension }
    }

    /// Returns whether every quantity is at or below another quantity vector.
    public func isComponentwiseAtMost(_ other: Self) -> Bool {
        BudgetDimension.allCases.allSatisfy { self[$0] <= other[$0] }
    }

    /// Returns a vector formed by checked cumulative addition.
    public func adding(_ other: Self) throws -> Self {
        var values: [BudgetDimension: UInt64] = [:]
        for dimension in BudgetDimension.allCases {
            let (sum, overflow) = self[dimension].addingReportingOverflow(other[dimension])
            guard !overflow else { throw AgentContractError.arithmeticOverflow(dimension: dimension) }
            if sum > 0 || contains(dimension) || other.contains(dimension) { values[dimension] = sum }
        }
        return Self(values)
    }

    /// Returns a vector formed by taking each component's maximum.
    public func componentwiseMaximum(_ other: Self) -> Self {
        Self(Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
            ($0, max(self[$0], other[$0]))
        }))
    }

    /// Decodes and normalizes a stable entry array.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode([Entry].self)
        self.init(entries: encoded)
        guard entries == encoded else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Budget quantities must be unique and canonically ordered"
            )
        }
    }

    /// Encodes a stable entry array rather than an unordered dictionary.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

/// Maximum thermal state at which new expensive work may be admitted.
public enum AgentThermalLimit: UInt8, CaseIterable, Hashable, Codable, Sendable, Comparable {
    /// Admit work only while the device is nominal.
    case nominal = 0
    /// Admit work through the fair thermal state.
    case fair = 1
    /// Admit work through the serious thermal state.
    case serious = 2
    /// The contract does not add a thermal-state admission restriction.
    case critical = 3

    /// Orders limits from most restrictive to least restrictive.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Required response when memory policy says the run may not continue normally.
public enum AgentMemoryPressureResponse: String, CaseIterable, Hashable, Codable, Sendable {
    /// Pause durably at the next stable boundary.
    case pause
    /// Cancel the current attempt and wait for foreground or explicit resume.
    case waitForForeground
    /// End the run with a typed resource failure.
    case failRun
}

/// Immutable hard limits selected by trusted policy and frozen for one run.
public struct AgentBudget: Hashable, Codable, Sendable {
    /// Hard numeric limits; every known dimension must be explicitly present.
    public let limits: BudgetQuantities
    /// Maximum thermal state at which new work may start.
    public let maximumThermalState: AgentThermalLimit
    /// Required behavior under disallowed memory pressure.
    public let memoryPressureResponse: AgentMemoryPressureResponse

    /// Creates a complete validated hard budget.
    public init(
        limits: BudgetQuantities,
        maximumThermalState: AgentThermalLimit,
        memoryPressureResponse: AgentMemoryPressureResponse
    ) throws {
        guard BudgetDimension.allCases.allSatisfy(limits.contains) else {
            throw AgentContractError.invalidName("budget omits a hard dimension")
        }
        self.limits = limits
        self.maximumThermalState = maximumThermalState
        self.memoryPressureResponse = memoryPressureResponse
    }

    /// First-release defaults with caller-supplied model context/output and device memory ceilings.
    public static func firstReleaseDefaults(
        contextTokensPerAttempt: UInt64,
        outputTokens: UInt64,
        peakMemoryBytes: UInt64
    ) throws -> Self {
        let (totalInputTokens, overflow) = contextTokensPerAttempt.multipliedReportingOverflow(by: 6)
        guard !overflow else { throw AgentContractError.arithmeticOverflow(dimension: .inputTokens) }
        let (totalOutputTokens, outputOverflow) = outputTokens.multipliedReportingOverflow(by: 6)
        guard !outputOverflow else { throw AgentContractError.arithmeticOverflow(dimension: .outputTokens) }
        let limits: [BudgetDimension: UInt64] = [
            .modelAttempts: 6,
            .toolInvocations: 3,
            .structuredRepairs: 1,
            .repeatedCallsPerFingerprint: 1,
            .consecutiveNoProgressActions: 2,
            .activeMilliseconds: 15 * 60 * 1_000,
            // Run totals sized for the maximum attempt count: a tool turn makes up to six model
            // passes, and EVERY pass reserves its full per-reply ceiling (see modelReservation).
            // A total equal to one pass would make the second pass fail preflight even after a
            // tiny first call.
            .inputTokens: totalInputTokens,
            .outputTokens: totalOutputTokens,
            .contextTokensPerAttempt: contextTokensPerAttempt,
            .networkRequestBytes: 8 * 1_024 * 1_024,
            .networkResponseBytesPerOperation: 2 * 1_024 * 1_024,
            .networkResponseBytesTotal: 8 * 1_024 * 1_024,
            .generatedArtifactBytes: 32 * 1_024 * 1_024,
            .persistedOutputBytes: 32 * 1_024 * 1_024,
            .peakMemoryBytes: peakMemoryBytes,
        ]
        return try Self(
            limits: BudgetQuantities(limits),
            maximumThermalState: .fair,
            memoryPressureResponse: .pause
        )
    }

    /// Returns a child budget only when no numeric or thermal limit is widened.
    public func attenuating(to child: Self, requireStrict: Bool = false) throws -> Self {
        for dimension in BudgetDimension.allCases where child.limits[dimension] > limits[dimension] {
            throw AgentContractError.budgetExceeded(
                dimension: dimension,
                limit: limits[dimension],
                requested: child.limits[dimension]
            )
        }
        guard child.maximumThermalState <= maximumThermalState else {
            throw AgentContractError.invalidName("child thermal budget widened")
        }
        guard child.memoryPressureResponse == memoryPressureResponse else {
            throw AgentContractError.invalidName("child memory response changed")
        }
        if requireStrict,
           child.limits == limits,
           child.maximumThermalState == maximumThermalState
        {
            throw AgentContractError.invalidName("child budget was not strictly attenuated")
        }
        return child
    }

    /// Decodes and validates a complete budget.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                limits: container.decode(BudgetQuantities.self, forKey: .limits),
                maximumThermalState: container.decode(AgentThermalLimit.self, forKey: .maximumThermalState),
                memoryPressureResponse: container.decode(
                    AgentMemoryPressureResponse.self,
                    forKey: .memoryPressureResponse
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case limits
        case maximumThermalState
        case memoryPressureResponse
    }
}

/// Concrete resource consumption measured for a run or operation.
public struct AgentUsage: Hashable, Codable, Sendable {
    /// Numeric resource quantities consumed.
    public let quantities: BudgetQuantities

    /// Creates a usage value.
    public init(quantities: BudgetQuantities = .init()) {
        self.quantities = quantities
    }

    /// A zero-usage value.
    public static let zero = Self()
}

/// A maximum resource reservation recorded before work begins.
public struct BudgetReservation: Hashable, Codable, Sendable {
    /// Stable idempotency identity for the reservation.
    public let id: BudgetReservationID
    /// Maximum usage reserved before the operation starts.
    public let maximumUsage: AgentUsage
    /// Stable local reason code for diagnostics.
    public let reason: String

    /// Creates a budget reservation.
    public init(id: BudgetReservationID, maximumUsage: AgentUsage, reason: String) throws {
        guard AgentWireValidation.isNonblankControlFree(reason, maximumLength: 128) else {
            throw AgentContractError.invalidName("budget reservation reason")
        }
        self.id = id
        self.maximumUsage = maximumUsage
        self.reason = reason
    }

    /// Decodes and revalidates a reservation reason and quantity vector.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(BudgetReservationID.self, forKey: .id),
                maximumUsage: container.decode(AgentUsage.self, forKey: .maximumUsage),
                reason: container.decode(String.self, forKey: .reason)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, maximumUsage, reason
    }
}

/// An immutable, serializable usage ledger supporting reserve, settle, and release operations.
public struct BudgetLedgerSnapshot: Hashable, Codable, Sendable {
    /// Frozen hard budget.
    public let budget: AgentBudget
    /// Usage committed at stable outcomes.
    public let consumed: AgentUsage
    /// Outstanding maximum reservations in stable identifier order.
    public let reservations: [BudgetReservation]

    /// Creates and fully validates a ledger snapshot.
    public init(
        budget: AgentBudget,
        consumed: AgentUsage = .zero,
        reservations: [BudgetReservation] = []
    ) throws {
        let sorted = reservations.sorted { $0.id.description < $1.id.description }
        guard Set(sorted.map(\.id)).count == sorted.count else {
            throw AgentContractError.invalidName("duplicate budget reservation")
        }
        self.budget = budget
        self.consumed = consumed
        self.reservations = sorted
        try validateBounds()
    }

    /// Returns a new snapshot with a reservation, idempotently accepting an identical duplicate.
    public func reserving(_ reservation: BudgetReservation) throws -> Self {
        if let existing = reservations.first(where: { $0.id == reservation.id }) {
            guard existing == reservation else {
                throw AgentContractError.conflictingReservation(reservation.id)
            }
            return self
        }
        return try Self(
            budget: budget,
            consumed: consumed,
            reservations: reservations + [reservation]
        )
    }

    /// Returns a new snapshot committing actual usage and releasing unused reservation quantities.
    public func settling(
        reservationID: BudgetReservationID,
        actualUsage: AgentUsage
    ) throws -> Self {
        guard let reservation = reservations.first(where: { $0.id == reservationID }) else {
            throw AgentContractError.reservationNotFound(reservationID)
        }
        guard actualUsage.quantities.isComponentwiseAtMost(reservation.maximumUsage.quantities) else {
            throw AgentContractError.usageExceedsReservation(reservationID)
        }
        var committed: [BudgetDimension: UInt64] = [:]
        for dimension in BudgetDimension.allCases {
            switch dimension.accounting {
            case .cumulative:
                let (sum, overflow) = consumed.quantities[dimension].addingReportingOverflow(
                    actualUsage.quantities[dimension]
                )
                guard !overflow else { throw AgentContractError.arithmeticOverflow(dimension: dimension) }
                committed[dimension] = sum
            case .maximum:
                committed[dimension] = max(
                    consumed.quantities[dimension],
                    actualUsage.quantities[dimension]
                )
            }
        }
        return try Self(
            budget: budget,
            consumed: AgentUsage(
                quantities: BudgetQuantities(committed)
            ),
            reservations: reservations.filter { $0.id != reservationID }
        )
    }

    /// Returns a new snapshot releasing a reservation without committing usage.
    public func releasing(reservationID: BudgetReservationID) throws -> Self {
        guard reservations.contains(where: { $0.id == reservationID }) else {
            throw AgentContractError.reservationNotFound(reservationID)
        }
        return try Self(
            budget: budget,
            consumed: consumed,
            reservations: reservations.filter { $0.id != reservationID }
        )
    }

    /// Decodes and revalidates all budget invariants.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedReservations = try container.decode(
            [BudgetReservation].self,
            forKey: .reservations
        )
        do {
            try self.init(
                budget: container.decode(AgentBudget.self, forKey: .budget),
                consumed: container.decode(AgentUsage.self, forKey: .consumed),
                reservations: decodedReservations
            )
            guard reservations == decodedReservations else {
                throw AgentContractError.invalidName("noncanonical budget reservations")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case budget
        case consumed
        case reservations
    }

    private func validateBounds() throws {
        for dimension in BudgetDimension.allCases {
            var effective = consumed.quantities[dimension]
            for reservation in reservations {
                let requested = reservation.maximumUsage.quantities[dimension]
                switch dimension.accounting {
                case .cumulative:
                    let (sum, overflow) = effective.addingReportingOverflow(requested)
                    guard !overflow else { throw AgentContractError.arithmeticOverflow(dimension: dimension) }
                    effective = sum
                case .maximum:
                    effective = max(effective, requested)
                }
            }
            let limit = budget.limits[dimension]
            guard effective <= limit else {
                throw AgentContractError.budgetExceeded(
                    dimension: dimension,
                    limit: limit,
                    requested: effective
                )
            }
        }
    }

}
