// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// The kind of total-workflow budget claim held by one child call.
enum WorkflowBudgetAdmission: Sendable {
    /// A new child owns an exact maximum-usage reservation.
    case reserved(BudgetReservationID)
    /// A child submitted before process loss is being reattached. New dispatch is fenced until all
    /// such children settle because their exact prior reservation is not reconstructed from script.
    case recovered
}

/// Serializes workflow-wide budget admission independently of JavaScript and scheduler concurrency.
/// Cumulative dimensions reserve by sum; maximum dimensions reserve by maximum through the shared
/// `BudgetLedgerSnapshot` accounting implementation.
actor WorkflowBudgetCoordinator {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
    }

    private var ledger: BudgetLedgerSnapshot
    private var recoveredUnsettled: Set<WorkflowAgentCallID>
    private var recoveryWaiters: [UUID: Waiter] = [:]

    init(projection: WorkflowRunProjectionV1) throws {
        ledger = try BudgetLedgerSnapshot(
            budget: projection.launch.budget,
            consumed: projection.usage
        )
        recoveredUnsettled = Set(projection.calls.compactMap { call in
            guard projection.outcomes[call.callID] == nil,
                  projection.submittedHandles[call.callID] != nil
            else { return nil }
            return call.callID
        })
    }

    /// Admits a call before submission. Recovered children bypass a new reservation but form a
    /// conservative dispatch fence: no new child starts until every already-running child is known.
    func admit(
        request: SubagentSpawnRequest?,
        call: WorkflowAgentCallV1,
        isRecoveredSubmission: Bool
    ) async throws -> WorkflowBudgetAdmission {
        if isRecoveredSubmission {
            guard recoveredUnsettled.contains(call.callID) else {
                throw WorkflowChildRequestValidationError.childIdentityMismatch
            }
            return .recovered
        }
        guard let request else {
            throw WorkflowChildRequestValidationError.childIdentityMismatch
        }
        try await waitForRecoveredChildren()
        let reservationID = BudgetReservationID(rawValue: call.callID.rawValue)
        let reservation = try BudgetReservation(
            id: reservationID,
            maximumUsage: AgentUsage(quantities: request.budget.limits),
            reason: "dynamic-workflow-child"
        )
        ledger = try ledger.reserving(reservation)
        return .reserved(reservationID)
    }

    /// Computing the remaining capacity, building the exact child request, and reserving it have
    /// no suspension point between them. Concurrent dispatch cannot spend the same remainder.
    func admitAvailable(
        call: WorkflowAgentCallV1,
        buildRequest: @Sendable (AgentBudget) throws -> SubagentSpawnRequest
    ) async throws -> (request: SubagentSpawnRequest, admission: WorkflowBudgetAdmission) {
        try await waitForRecoveredChildren()
        try Task.checkCancellation()
        let remaining = try AgentBudget(
            limits: ledger.availableCapacity,
            maximumThermalState: ledger.budget.maximumThermalState,
            memoryPressureResponse: ledger.budget.memoryPressureResponse
        )
        let request = try buildRequest(remaining)
        let reservationID = BudgetReservationID(rawValue: call.callID.rawValue)
        let reservation = try BudgetReservation(
            id: reservationID,
            maximumUsage: AgentUsage(quantities: request.budget.limits),
            reason: "dynamic-workflow-child"
        )
        ledger = try ledger.reserving(reservation)
        return (request, .reserved(reservationID))
    }

    /// Commits actual child usage and releases its admission claim. The returned usage is the
    /// accounting-correct workflow aggregate after this stable settlement.
    func settle(
        call: WorkflowAgentCallV1,
        admission: WorkflowBudgetAdmission,
        actualUsage: AgentUsage
    ) throws -> AgentUsage {
        switch admission {
        case .reserved(let reservationID):
            ledger = try ledger.settling(
                reservationID: reservationID,
                actualUsage: actualUsage
            )
        case .recovered:
            guard recoveredUnsettled.remove(call.callID) != nil else {
                throw WorkflowChildRequestValidationError.childIdentityMismatch
            }
            let aggregate = try ledger.consumed.aggregating(actualUsage)
            ledger = try BudgetLedgerSnapshot(
                budget: ledger.budget,
                consumed: aggregate,
                reservations: ledger.reservations
            )
            if recoveredUnsettled.isEmpty { releaseRecoveryFence() }
        }
        return ledger.consumed
    }

    /// Releases a claim only when submission never crossed the child executor boundary.
    func releaseUnsubmitted(_ admission: WorkflowBudgetAdmission) throws {
        guard case .reserved(let reservationID) = admission else { return }
        ledger = try ledger.releasing(reservationID: reservationID)
    }

    /// Releases the conservative recovery claim after the engine has durably abandoned and
    /// cancelled a mismatched replay-suffix child. No usage is invented; any known child usage must
    /// be committed by reconciliation before invoking this operation.
    func abandonRecovered(callID: WorkflowAgentCallID) throws -> AgentUsage {
        guard recoveredUnsettled.remove(callID) != nil else {
            throw WorkflowChildRequestValidationError.childIdentityMismatch
        }
        if recoveredUnsettled.isEmpty { releaseRecoveryFence() }
        return ledger.consumed
    }

    private func waitForRecoveredChildren() async throws {
        guard !recoveredUnsettled.isEmpty else { return }
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if recoveredUnsettled.isEmpty {
                    continuation.resume()
                } else {
                    recoveryWaiters[id] = Waiter(continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelRecoveryWaiter(id) }
        }
    }

    private func cancelRecoveryWaiter(_ id: UUID) {
        recoveryWaiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    private func releaseRecoveryFence() {
        let waiters = recoveryWaiters.values
        recoveryWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume() }
    }
}
