// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

extension AgentRunController {
    /// Bounded fan-out cap for one tool batch (spec §12 roadmap step 2).
    static let parallelToolBatchLimit = 4

    /// Executes a durable `.callTools` batch. A single pending call keeps the proven serial path;
    /// multiple pending calls fan out concurrently and then cross one deterministic barrier.
    func executeToolBatch(facts: RuntimeRunFacts, history: ExecutionHistory) async throws {
        guard let reference = history.actionEvents.last?.2 else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let action = try await loadPayload(AgentAction.self, reference: reference)
        guard case .callTools(let calls) = action else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let pending = calls.filter { history.toolOutcomes[$0.invocationID] == nil }
        if pending.isEmpty {
            // Every call already committed an outcome (parallel batch recovered after a crash);
            // apply the aggregate barrier transition exactly once.
            try await applyParallelToolBarrier(runID: facts.projection.runID)
            return
        }
        let limit = Int(facts.submission!.request.payload.parallelToolBatchLimit)
        if limit <= 1 || pending.count == 1 {
            try await executeNextTool(facts: facts, history: history)
            return
        }
        try await executeParallelToolBatch(
            facts: facts,
            history: history,
            calls: calls,
            maximumParallel: min(Self.parallelToolBatchLimit, limit)
        )
    }

    private func executeParallelToolBatch(
        facts: RuntimeRunFacts,
        history: ExecutionHistory,
        calls: [ProposedToolCall],
        maximumParallel: Int
    ) async throws {
        let frozen = try await frozenInputsForTools(facts)
        var authorized: [AuthorizedParallelTool] = []
        authorized.reserveCapacity(calls.count)
        // Prepare + authorize sequentially (approval semantics stay one-at-a-time and durable);
        // only the execution bodies fan out.
        for call in calls where history.toolOutcomes[call.invocationID] == nil {
            guard let descriptor = frozen.toolCatalog.descriptor(for: call.toolID),
                  let live = try await tools.tool(for: descriptor.id),
                  live.descriptor == descriptor
            else {
                try await failRun(
                    runID: facts.projection.runID,
                    reason: .toolUnavailable,
                    code: "execution.tool-unavailable",
                    message: "The exact tool revision selected for this run is unavailable."
                )
                return
            }
            guard let prepared = try await prepareAndAuthorizeTool(
                live,
                descriptor: descriptor,
                proposed: call,
                facts: facts,
                history: history
            ) else { return }
            authorized.append(prepared)
        }

        let budget = facts.submission!.request.payload.budget
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = authorized.makeIterator()
            var active = 0
            while active < maximumParallel, let next = iterator.next() {
                group.addTask { [self] in
                    try await self.executeAuthorizedTool(
                        next.tool,
                        authorized: next.authorized,
                        prepared: next.prepared,
                        proposed: next.proposed,
                        stepID: next.stepID,
                        initialTimestamp: next.timestamp,
                        // Every fan-out invocation defers its terminal decision to the barrier.
                        hasMore: true,
                        deferTerminalDecisions: true,
                        budget: budget,
                        history: history
                    )
                }
                active += 1
            }
            while let next = iterator.next() {
                try await group.next()
                group.addTask { [self] in
                    try await self.executeAuthorizedTool(
                        next.tool,
                        authorized: next.authorized,
                        prepared: next.prepared,
                        proposed: next.proposed,
                        stepID: next.stepID,
                        initialTimestamp: next.timestamp,
                        hasMore: true,
                        deferTerminalDecisions: true,
                        budget: budget,
                        history: history
                    )
                }
            }
            try await group.waitForAll()
        }
        try await applyParallelToolBarrier(runID: facts.projection.runID)
    }

    /// The deterministic barrier: commits ONE aggregate next-state transition after every fan-out
    /// outcome has landed. Uncertainty wins over no-progress termination, matching the serial path.
    private func applyParallelToolBarrier(runID: AgentRunID) async throws {
        let (facts, history) = try await loadRun(runID)
        guard let reference = history.actionEvents.last?.2 else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let action = try await loadPayload(AgentAction.self, reference: reference)
        guard case .callTools(let calls) = action else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        var missing = false
        for call in calls where history.toolOutcomes[call.invocationID] == nil {
            missing = true
        }
        guard !missing else { return }

        // Latest reconciliation resolution per invocation (durable recovery semantics).
        var resolutionSequence: [ToolInvocationID: UInt64] = [:]
        for (record, failure) in history.diagnostics {
            let isSucceeded = failure.code == "execution.reconciled-succeeded"
            let isFailed = failure.code == "execution.reconciled-failed"
            guard isSucceeded || isFailed,
                  let rawInvocationID = failure.details["invocationID"],
                  let invocationID = ToolInvocationID(rawInvocationID)
            else { continue }
            if let existing = resolutionSequence[invocationID], existing >= record.sequence {
                continue
            }
            resolutionSequence[invocationID] = record.sequence
        }

        var firstUncertain: (invocationID: ToolInvocationID, failure: AgentFailure)?
        var anyFailed = false
        for call in calls {
            guard let outcome = history.toolOutcomes[call.invocationID]?.1 else { continue }
            switch outcome {
            case .completed:
                continue
            case .failed:
                anyFailed = true
            case .uncertain(let failure):
                if let resolution = resolutionSequence[call.invocationID],
                   resolution > (history.toolOutcomes[call.invocationID]?.0.sequence ?? 0)
                {
                    // Resolved after this batch; not a live reconciliation target.
                    anyFailed = true
                } else if firstUncertain == nil {
                    firstUncertain = (call.invocationID, failure)
                }
            }
        }

        if facts.projection.state == .pausing, firstUncertain == nil {
            // No terminal decision needed; the worker's `.pausing` branch finishes quiescence.
            return
        }

        let id = ExecutionStableID.event(
            runID: runID,
            key: "tool-batch-barrier-\(facts.projection.eventCount + 1)"
        )
        _ = try await commitEvents(runID: runID, identity: .outcome(id)) { builder in
            var events: [AgentEventEnvelope] = []
            if let uncertain = firstUncertain {
                let waiting = try self.status(
                    after: builder,
                    state: .waitingForReconciliation,
                    failure: uncertain.failure,
                    blockingReason: .reconciliation(invocationID: uncertain.invocationID)
                )
                events.append(try builder.append(
                    id: id,
                    event: .statusChanged(waiting),
                    transitionTo: .waitingForReconciliation,
                    redaction: Self.publicRedaction
                ))
                return events
            }
            let consecutiveNoProgress = history.toolOutcomes.values
                .sorted { $0.0.sequence < $1.0.sequence }
                .reversed()
                .prefix { self.isSemanticNoProgress($0.1) }
                .count
            if consecutiveNoProgress >= 2 {
                let failure = try ExecutionFailureFactory.make(
                    reason: .noProgress,
                    code: "execution.no-progress",
                    message: "The agent stopped after two consecutive actions produced no usable result."
                )
                let status = try self.status(
                    after: builder,
                    state: .failed,
                    terminalReason: .noProgress,
                    failure: failure
                )
                let result = try AgentResult(
                    requestID: builder.requestID,
                    executionHandleID: builder.handleID,
                    runID: runID,
                    status: status,
                    answer: nil,
                    usage: builder.usage
                )
                events.append(try builder.append(
                    id: id,
                    event: .terminal(result),
                    transitionTo: .failed,
                    redaction: Self.publicRedaction
                ))
                return events
            }
            let next: AgentRunState = anyFailed ? .synthesizing : .waitingForModel
            let blocking: AgentBlockingReason? = anyFailed ? nil : .modelResource
            let status = try self.status(
                after: builder,
                state: next,
                blockingReason: blocking
            )
            events.append(try builder.append(
                id: id,
                event: .statusChanged(status),
                transitionTo: next,
                redaction: Self.publicRedaction
            ))
            return events
        }
    }
}
