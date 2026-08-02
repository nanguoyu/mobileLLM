// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime

actor ScriptedModelResidencyDriver: ModelResidencyDriver {
    struct Call: Hashable, Sendable {
        let operation: ModelResidencyOperation
        let selection: AgentModelSelection
    }

    struct Snapshot: Hashable, Sendable {
        let calls: [Call]
        let residentSelection: AgentModelSelection?
        let maxOperationsInFlight: Int
        let maxResidentSelections: Int
        let lifecycleViolations: Int
    }

    enum DriverError: Error {
        case scriptedFailure
        case lifecycleViolation
    }

    private struct CallWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var calls: [Call] = []
    private var residentSelection: AgentModelSelection?
    private var operationsInFlight = 0
    private var maxOperationsInFlight = 0
    private var maxResidentSelections = 0
    private var lifecycleViolations = 0

    private var blocksRemaining: [Call: Int] = [:]
    private var blockedCalls: [Call: [CheckedContinuation<Void, Never>]] = [:]
    private var failuresRemaining: [Call: Int] = [:]
    private var callWaiters: [CallWaiter] = []

    func blockNext(_ operation: ModelResidencyOperation, selection: AgentModelSelection) {
        blocksRemaining[Call(operation: operation, selection: selection), default: 0] += 1
    }

    func failNext(_ operation: ModelResidencyOperation, selection: AgentModelSelection) {
        failuresRemaining[Call(operation: operation, selection: selection), default: 0] += 1
    }

    func waitForCallCount(_ expectedCount: Int) async {
        guard calls.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(
                CallWaiter(expectedCount: expectedCount, continuation: continuation)
            )
        }
    }

    @discardableResult
    func resumeNext(_ operation: ModelResidencyOperation, selection: AgentModelSelection) -> Bool {
        let call = Call(operation: operation, selection: selection)
        guard var continuations = blockedCalls[call], !continuations.isEmpty else { return false }
        let continuation = continuations.removeFirst()
        blockedCalls[call] = continuations.isEmpty ? nil : continuations
        continuation.resume()
        return true
    }

    func snapshot() -> Snapshot {
        Snapshot(
            calls: calls,
            residentSelection: residentSelection,
            maxOperationsInFlight: maxOperationsInFlight,
            maxResidentSelections: maxResidentSelections,
            lifecycleViolations: lifecycleViolations
        )
    }

    func load(selection: AgentModelSelection) async throws {
        try await perform(.load, selection: selection)
    }

    func cancelAndDrain(selection: AgentModelSelection) async throws {
        try await perform(.cancelAndDrain, selection: selection)
    }

    func unload(selection: AgentModelSelection) async throws {
        try await perform(.unload, selection: selection)
    }

    private func perform(
        _ operation: ModelResidencyOperation,
        selection: AgentModelSelection
    ) async throws {
        let call = Call(operation: operation, selection: selection)
        calls.append(call)
        operationsInFlight += 1
        maxOperationsInFlight = max(maxOperationsInFlight, operationsInFlight)
        resumeSatisfiedCallWaiters()
        defer { operationsInFlight -= 1 }

        if let remaining = blocksRemaining[call], remaining > 0 {
            blocksRemaining[call] = remaining == 1 ? nil : remaining - 1
            await withCheckedContinuation { continuation in
                blockedCalls[call, default: []].append(continuation)
            }
        }
        if let remaining = failuresRemaining[call], remaining > 0 {
            failuresRemaining[call] = remaining == 1 ? nil : remaining - 1
            throw DriverError.scriptedFailure
        }

        switch operation {
        case .load:
            if let residentSelection, residentSelection != selection {
                lifecycleViolations += 1
                throw DriverError.lifecycleViolation
            }
            residentSelection = selection
            maxResidentSelections = max(maxResidentSelections, 1)
        case .cancelAndDrain:
            break
        case .unload:
            if let residentSelection, residentSelection != selection {
                lifecycleViolations += 1
                throw DriverError.lifecycleViolation
            }
            if residentSelection == selection {
                residentSelection = nil
            }
        }
    }

    private func resumeSatisfiedCallWaiters() {
        var pending: [CallWaiter] = []
        for waiter in callWaiters {
            if calls.count >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        callWaiters = pending
    }
}
