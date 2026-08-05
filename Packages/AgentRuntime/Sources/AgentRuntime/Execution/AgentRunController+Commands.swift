// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

extension AgentRunController {
    public func send(
        _ envelope: AgentCommandEnvelope,
        through handleID: AgentExecutionHandleID
    ) async throws -> AgentCommandReceipt {
        guard let facts = try await repository.loadRunFacts(for: handleID) else {
            throw AgentExecutionError.executionNotFound(handleID)
        }
        let command = envelope.payload
        guard command.runID == facts.projection.runID else {
            throw AgentExecutionError.commandTargetsAnotherRun
        }
        let admission = try await repository.enqueueCommand(envelope)
        switch admission.disposition {
        case .conflict:
            throw AgentExecutionError.submissionCommandConflict(command.commandID)
        case .replayed where admission.command.state == .completed:
            guard let receipt = admission.command.receipt?.payload else {
                throw AgentExecutionError.corruptExecutionBinding
            }
            return receipt
        case .admitted, .replayed:
            break
        }

        try await pumpCommands(until: command.commandID)
        guard let completed = try await repository.loadCommand(command.commandID),
              completed.state == .completed,
              let receipt = completed.receipt?.payload
        else { throw AgentExecutionError.commandLeaseUnavailable }
        return receipt
    }

    private func pumpCommands(until target: AgentCommandID) async throws {
        for _ in 0 ..< 8 {
            if let current = try await repository.loadCommand(target), current.state == .completed {
                return
            }
            let now = try await clock.now()
            let (expiryRaw, overflow) = now.rawValue.addingReportingOverflow(30_000)
            guard !overflow else { throw AgentExecutionError.commandLeaseUnavailable }
            let claim = try await repository.claimCommands(
                owner: commandOwner,
                now: now,
                leaseUntil: AgentTimestamp(rawValue: expiryRaw),
                limit: 32
            )
            guard !claim.commands.isEmpty else { break }
            for durable in claim.commands {
                try await process(durable)
            }
        }
    }

    private func process(_ durable: DurableAgentCommand) async throws {
        guard let lease = durable.lease else { throw AgentExecutionError.commandLeaseUnavailable }
        let command = durable.envelope.payload
        let (facts, history) = try await loadRun(command.runID)
        let receipt: AgentCommandReceipt

        if let previouslyAccepted = acceptedCommandStatus(
            commandID: command.commandID,
            history: history
        ) {
            receipt = try AgentCommandReceipt(
                commandID: command.commandID,
                runID: command.runID,
                disposition: .accepted,
                currentStatus: previouslyAccepted
            )
        } else if command.expectedRunStateVersion != facts.projection.stateVersion {
            receipt = try AgentCommandReceipt(
                commandID: command.commandID,
                runID: command.runID,
                disposition: .stale,
                currentStatus: history.status,
                failure: commandFailure(
                    code: "execution.command-stale",
                    message: "The run changed before this command was applied."
                )
            )
        } else if facts.projection.isTerminal {
            receipt = try AgentCommandReceipt(
                commandID: command.commandID,
                runID: command.runID,
                disposition: .rejected,
                currentStatus: history.status,
                failure: commandFailure(
                    code: "execution.command-terminal",
                    message: "A completed run cannot be changed."
                )
            )
        } else {
            receipt = try await apply(command, facts: facts, history: history)
        }

        _ = try await repository.completeCommand(
            commandID: command.commandID,
            lease: lease,
            receipt: AgentCommandReceiptEnvelope(payload: receipt),
            completedAt: try await clock.now()
        )
    }

    private func acceptedCommandStatus(
        commandID: AgentCommandID,
        history: ExecutionHistory
    ) -> AgentRunStatus? {
        let candidateIDs = Set((0 ..< 8).map {
            ExecutionStableID.commandEvent(
                runID: history.events[0].payload.runID,
                commandID: commandID,
                ordinal: UInt16($0)
            )
        })
        let committed = history.events.filter { candidateIDs.contains($0.payload.eventID) }
        guard let lastSequence = committed.map(\.payload.sequence).max(),
              var status = try? AgentRunStatus(state: .created, stateVersion: 1)
        else { return nil }
        for envelope in history.events where envelope.payload.sequence <= lastSequence {
            switch envelope.payload.event {
            case .statusChanged(let value): status = value
            case .terminal(let result): status = result.status
            default: break
            }
        }
        return status
    }

    private func apply(
        _ command: AgentCommand,
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws -> AgentCommandReceipt {
        switch command.action {
        case .pause:
            return try await applyPauseOrCancel(
                command,
                cancel: false,
                facts: facts,
                history: history
            )
        case .cancel:
            return try await applyPauseOrCancel(
                command,
                cancel: true,
                facts: facts,
                history: history
            )
        case .resume:
            return try await applyResume(command, facts: facts, history: history)
        case .decideApproval(let approvalID, let decision, let approvedScope):
            return try await applyApproval(
                command,
                approvalID: approvalID,
                decision: decision,
                approvedScope: approvedScope,
                history: history
            )
        case .respond(let response):
            return try await applyResponse(command, response: response, history: history)
        case .reconcile(let invocationID, let decision):
            return try await applyReconciliation(
                command,
                invocationID: invocationID,
                decision: decision,
                history: history
            )
        }
    }

    private func applyResume(
        _ command: AgentCommand,
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws -> AgentCommandReceipt {
        let state = facts.projection.state
        let ordinarilyResumable = state == .paused || state == .waitingForForeground
        let volatileRecoveryStates: Set<AgentRunState> = [
            .created, .preparing, .waitingForModel, .generating, .validatingAction,
            .executingTools, .synthesizing, .pausing,
        ]
        guard ordinarilyResumable || volatileRecoveryStates.contains(state),
              workers[command.runID] == nil
        else {
            return try rejected(command, history: history, code: "execution.resume-invalid")
        }

        do {
            try await validateRecoveryDependencies(facts: facts, history: history)
        } catch {
            return try rejected(
                command,
                history: history,
                code: "execution.resume-dependency-unavailable"
            )
        }

        let batch: CommittedEventBatch
        var checkpointStatus: AgentRunStatus?
        switch state {
        case .created, .paused, .waitingForForeground:
            batch = try await commitCommandTransition(command, state: .preparing)
        case .preparing:
            batch = try await commitRecoveryCheckpoint(command)
            checkpointStatus = history.status
        case .waitingForModel:
            batch = try await commitRecoveryCheckpoint(command)
            checkpointStatus = history.status
        case .generating:
            batch = try await recoverGeneratingForExplicitResume(
                command,
                facts: facts,
                history: history
            )
        case .validatingAction:
            batch = try await commitRecoveryCheckpoint(command)
            checkpointStatus = history.status
        case .executingTools:
            if let reconciled = try await recoverClaimedToolForExplicitResume(
                command,
                facts: facts,
                history: history
            ) {
                let recoveredStatus = try statusFrom(reconciled)
                if !recoveredStatus.state.isTerminal,
                   recoveredStatus.state != .waitingForReconciliation
                {
                    schedule(runID: command.runID)
                }
                return try accepted(command, status: recoveredStatus)
            }
            batch = try await commitRecoveryCheckpoint(command)
            checkpointStatus = history.status
        case .synthesizing:
            batch = try await commitRecoveryCheckpoint(command)
            checkpointStatus = history.status
        case .pausing:
            batch = try await recoverPausingForExplicitResume(
                command,
                facts: facts,
                history: history
            )
        case .waitingForApproval, .waitingForUser, .waitingForReconciliation,
             .completed, .failed, .cancelled:
            return try rejected(command, history: history, code: "execution.resume-invalid")
        }
        let status = try checkpointStatus ?? statusFrom(batch)
        if !status.state.isTerminal,
           status.state != .waitingForReconciliation
        {
            schedule(runID: command.runID)
        }
        return try accepted(command, status: status)
    }

    private func commitRecoveryCheckpoint(
        _ command: AgentCommand
    ) async throws -> CommittedEventBatch {
        let marker = try AgentFailure(
            code: "execution.explicit-recovery-resumed",
            classification: .transient,
            safeMessage: "The user explicitly resumed this durable recovery checkpoint.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: Self.publicRedaction
        )
        return try await commitEvents(
            runID: command.runID,
            identity: .command(command.commandID)
        ) { builder in
            [try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: 0
                ),
                event: .diagnostic(marker),
                redaction: Self.publicRedaction
            )]
        }
    }

    private func validateRecoveryDependencies(
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws {
        let frozen = try await frozenInputsForRecovery(facts)
        _ = try modelProviders.provider(for: frozen.modelSelection)
        guard let actionReference = history.actionEvents.last?.2 else { return }
        let action = try await loadPayload(AgentAction.self, reference: actionReference)
        guard case .callTools(let calls) = action else { return }
        for call in calls where history.toolOutcomes[call.invocationID] == nil {
            guard let descriptor = frozen.toolCatalog.descriptor(for: call.toolID),
                  let live = try await tools.tool(for: descriptor.id),
                  live.descriptor == descriptor
            else { throw AgentExecutionError.dependencyUnavailable("tool") }
        }
    }

    private func frozenInputsForRecovery(
        _ facts: RuntimeRunFacts
    ) async throws -> FrozenAgentRunInputs {
        guard let reference = facts.submission?.inputSnapshot else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        return try await loadPayload(FrozenAgentRunInputs.self, reference: reference)
    }

    private func recoverGeneratingForExplicitResume(
        _ command: AgentCommand,
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws -> CommittedEventBatch {
        guard let manifest = history.manifestEvents.last else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let reservationID = ExecutionStableID.reservation(
            runID: command.runID,
            kind: "model",
            stableID: manifest.1.description
        )
        guard let ledger = facts.budgetLedger,
              let reservation = ledger.reservations.first(where: { $0.id == reservationID })
        else { throw AgentExecutionError.invalidRecoveryBoundary }
        let conservative = reservation.maximumUsage
        let settled = try ledger.settling(
            reservationID: reservation.id,
            actualUsage: conservative
        )
        return try await commitEvents(
            runID: command.runID,
            identity: .command(command.commandID),
            budgetOperations: [
                .settle(reservationID: reservation.id, actualUsage: conservative),
            ]
        ) { builder in
            var events = [try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: 0
                ),
                event: .modelAttemptOutcome(.interrupted(nil)),
                cumulativeUsage: settled.consumed,
                redaction: Self.publicRedaction
            )]
            let foreground = try self.status(
                after: builder,
                state: .waitingForForeground,
                blockingReason: .foreground
            )
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: 1
                ),
                event: .statusChanged(foreground),
                transitionTo: .waitingForForeground,
                redaction: Self.publicRedaction
            ))
            let preparing = try self.status(after: builder, state: .preparing)
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: 2
                ),
                event: .statusChanged(preparing),
                transitionTo: .preparing,
                redaction: Self.publicRedaction
            ))
            return events
        }
    }

    private typealias InterruptedToolRecoveryFacts = (
        invocationID: ToolInvocationID,
        prepared: PreparedExternalOperationRequest,
        attemptNumber: UInt16,
        reservation: BudgetReservation,
        evidence: RuntimeBoundaryClaimEvidence
    )

    private func interruptedToolRecoveryFacts(
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws -> InterruptedToolRecoveryFacts? {
        guard let entry = history.toolIntents.first(where: {
            history.toolOutcomes[$0.key] == nil
        }) else { return nil }
        let invocationID = entry.key
        let prepared = entry.value.1
        let attemptNumber = UInt16(clamping: recordedToolAttemptCount(
            history: history,
            invocationID: invocationID
        ))
        guard attemptNumber > 0,
              let approvalID = recordedToolAttemptApprovalID(
                  history: history,
                  invocationID: invocationID,
                  attemptNumber: attemptNumber
              ),
              let budget = facts.submission?.request.payload.budget
        else { throw AgentExecutionError.invalidRecoveryBoundary }
        let expected = try toolReservation(
            runID: facts.projection.runID,
            invocationID: invocationID,
            prepared: prepared,
            attemptNumber: attemptNumber,
            externalBytes: requiresExternalByteAccounting(prepared.plan),
            budget: budget
        )
        guard let reservation = facts.budgetLedger?.reservations.first(where: {
            $0.id == expected.id
        }) else {
            // A live pause may already have settled this exact attempt and recorded its marker.
            return nil
        }
        let attempt = try ExternalOperationAttempt(
            prepared: prepared,
            attemptNumber: attemptNumber
        )
        let evidence = try await repository.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: prepared,
            attempt: attempt
        )
        return (invocationID, prepared, attemptNumber, reservation, evidence)
    }

    /// Commits an outcome only when a claimed crash cannot safely start another allowed attempt.
    /// Claim-free and replayable claimed attempts remain in `executingTools` for the worker.
    private func recoverClaimedToolForExplicitResume(
        _ command: AgentCommand,
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws -> CommittedEventBatch? {
        guard let recovery = try await interruptedToolRecoveryFacts(
            facts: facts,
            history: history
        ), recovery.evidence != .none else { return nil }
        if recovery.evidence == .exact,
           isSafelyReplayable(recovery.prepared.plan),
           recovery.attemptNumber < recovery.prepared.plan.retryPolicy.maximumAttempts
        {
            return nil
        }

        let requiresReconciliation = recovery.evidence == .legacyConservative
            || hasRiskyExternalEffects(recovery.prepared.plan)
        let failure = if requiresReconciliation {
            try ExecutionFailureFactory.uncertain(
                code: recovery.evidence == .legacyConservative
                    ? "execution.legacy-boundary-claim-uncertain"
                    : "execution.tool-recovery-uncertain",
                message: "The interrupted tool crossed its boundary without a durable outcome."
            )
        } else {
            try AgentFailure(
                code: "execution.tool-retry-exhausted",
                classification: .permanent,
                safeMessage: "The interrupted read cannot be retried within its frozen policy.",
                retryAdvice: .never,
                externalEffect: .confirmedNone,
                requiredUserAction: .none,
                redaction: Self.publicRedaction
            )
        }
        let outcome: AgentToolInvocationOutcome = requiresReconciliation
            ? .uncertain(failure) : .failed(failure)
        let actual = conservativeUsage(
            for: recovery.reservation,
            completedInvocation: true
        )
        guard let ledger = facts.budgetLedger else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let settled = try ledger.settling(
            reservationID: recovery.reservation.id,
            actualUsage: actual
        )
        return try await commitEvents(
            runID: command.runID,
            identity: .command(command.commandID),
            budgetOperations: [
                .settle(reservationID: recovery.reservation.id, actualUsage: actual),
            ]
        ) { builder in
            var events = [try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: 0
                ),
                event: .toolOutcomeRecorded(
                    invocationID: recovery.invocationID,
                    outcome: outcome
                ),
                cumulativeUsage: settled.consumed,
                redaction: Self.publicRedaction
            )]
            let next: AgentRunState = requiresReconciliation
                ? .waitingForReconciliation : .synthesizing
            let status = try self.status(
                after: builder,
                state: next,
                failure: requiresReconciliation ? failure : nil,
                blockingReason: requiresReconciliation
                    ? .reconciliation(invocationID: recovery.invocationID) : nil
            )
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: 1
                ),
                event: .statusChanged(status),
                transitionTo: next,
                redaction: Self.publicRedaction
            ))
            return events
        }
    }

    private func recoverPausingForExplicitResume(
        _ command: AgentCommand,
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws -> CommittedEventBatch {
        if let claimed = try await recoverClaimedToolForExplicitResume(
            command,
            facts: facts,
            history: history
        ) {
            return claimed
        }
        let cancellationRequested = history.diagnostics.last(where: {
            $0.1.code == "execution.cancel-requested"
                || $0.1.code == "execution.pause-requested"
        })?.1.code == "execution.cancel-requested"
        guard var ledger = facts.budgetLedger else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        var operations: [BudgetLedgerOperation] = []
        var interruptedModelUsage: AgentUsage?
        if history.manifestEvents.count > history.modelOutcomes.count {
            guard let stepID = history.manifestEvents.last?.1 else {
                throw AgentExecutionError.invalidRecoveryBoundary
            }
            let reservationID = ExecutionStableID.reservation(
                runID: command.runID,
                kind: "model",
                stableID: stepID.description
            )
            guard let reservation = ledger.reservations.first(where: {
                $0.id == reservationID
            }) else { throw AgentExecutionError.invalidRecoveryBoundary }
            let conservative = reservation.maximumUsage
            ledger = try ledger.settling(
                reservationID: reservation.id,
                actualUsage: conservative
            )
            operations.append(.settle(
                reservationID: reservation.id,
                actualUsage: conservative
            ))
            interruptedModelUsage = ledger.consumed
        }
        for reservation in ledger.reservations {
            operations.append(.release(reservationID: reservation.id))
        }
        return try await commitEvents(
            runID: command.runID,
            identity: .command(command.commandID),
            budgetOperations: operations
        ) { builder in
            var events: [AgentEventEnvelope] = []
            var ordinal: UInt16 = 0
            if let interruptedModelUsage {
                events.append(try builder.append(
                    id: ExecutionStableID.commandEvent(
                        runID: command.runID,
                        commandID: command.commandID,
                        ordinal: ordinal
                    ),
                    event: .modelAttemptOutcome(.interrupted(nil)),
                    cumulativeUsage: interruptedModelUsage,
                    redaction: Self.publicRedaction
                ))
                ordinal += 1
            }
            if cancellationRequested {
                let failure = try ExecutionFailureFactory.make(
                    reason: .cancelledByUser,
                    code: "execution.cancelled",
                    message: "The run was cancelled."
                )
                let terminal = try self.status(
                    after: builder,
                    state: .cancelled,
                    terminalReason: .cancelledByUser,
                    failure: failure
                )
                let result = try AgentResult(
                    requestID: builder.requestID,
                    executionHandleID: builder.handleID,
                    runID: command.runID,
                    status: terminal,
                    answer: nil,
                    usage: builder.usage
                )
                events.append(try builder.append(
                    id: ExecutionStableID.commandEvent(
                        runID: command.runID,
                        commandID: command.commandID,
                        ordinal: ordinal
                    ),
                    event: .terminal(result),
                    transitionTo: .cancelled,
                    redaction: Self.publicRedaction
                ))
                return events
            }
            let paused = try self.status(
                after: builder,
                state: .paused,
                blockingReason: .paused
            )
            events.append(try builder.append(
                    id: ExecutionStableID.commandEvent(
                        runID: command.runID,
                        commandID: command.commandID,
                        ordinal: ordinal
                    ),
                event: .statusChanged(paused),
                transitionTo: .paused,
                redaction: Self.publicRedaction
            ))
            ordinal += 1
            let preparing = try self.status(after: builder, state: .preparing)
            events.append(try builder.append(
                    id: ExecutionStableID.commandEvent(
                        runID: command.runID,
                        commandID: command.commandID,
                        ordinal: ordinal
                    ),
                event: .statusChanged(preparing),
                transitionTo: .preparing,
                redaction: Self.publicRedaction
            ))
            return events
        }
    }

    private func applyPauseOrCancel(
        _ command: AgentCommand,
        cancel: Bool,
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws -> AgentCommandReceipt {
        let unresolved = history.toolIntents.first { history.toolOutcomes[$0.key] == nil }
        let hasLiveCancellableAttempt = unresolved.map {
            activeToolCancellations[command.runID]?.invocationID == $0.key
        } ?? false
        if !hasLiveCancellableAttempt, unresolved != nil,
           let recovery = try await interruptedToolRecoveryFacts(
               facts: facts,
               history: history
           )
        {
            let marker = try commandFailure(
                code: cancel ? "execution.cancel-requested" : "execution.pause-requested",
                message: cancel
                    ? "Cancellation will complete at the next safe boundary."
                    : "Pause will complete at the next safe boundary."
            )
            let batch = try await commitInterruptedToolLifecycleCommand(
                command,
                requestMarker: marker,
                recovery: recovery
            )
            await cancelActiveTool(runID: command.runID)
            workers[command.runID]?.cancel()
            let status = try statusFrom(batch)
            if status.state == .pausing, workers[command.runID] == nil {
                schedule(runID: command.runID)
            }
            return try accepted(command, status: status)
        }

        let hasSafeInterruption: Bool
        if let unresolved {
            var foundSafeInterruption = false
            for (_, failure) in history.diagnostics {
                if failure.code == "execution.tool-attempt-interrupted",
                   failure.details["invocationID"] == unresolved.key.description
                {
                    foundSafeInterruption = true
                    break
                }
            }
            hasSafeInterruption = foundSafeInterruption
        } else {
            hasSafeInterruption = false
        }
        let hasRiskyOutstandingEffect: Bool
        if let unresolved {
            hasRiskyOutstandingEffect = hasRiskyExternalEffects(unresolved.value.1.plan)
        } else {
            hasRiskyOutstandingEffect = false
        }
        let hasUnsafeOutstandingEffect = !hasLiveCancellableAttempt
            && !hasSafeInterruption
            && hasRiskyOutstandingEffect
        let decision = AgentRunReducer.reduce(
            .pauseCancel(
                AgentPauseCancelInput(
                    state: history.status.state,
                    command: cancel ? .cancel : .pause,
                    guardCondition: hasUnsafeOutstandingEffect
                        ? .unresolvedExternalOutcome : .cancellableWork
                )
            )
        )
        guard decision.disposition == .accepted,
              let next = decision.nextState
        else {
            return try rejected(
                command,
                history: history,
                code: cancel ? "execution.cancel-invalid" : "execution.pause-invalid"
            )
        }
        if next == .cancelled, decision.terminalReason == .cancelledByUser {
            let batch = try await commitCancelled(command, history: history)
            await cancelActiveTool(runID: command.runID)
            workers[command.runID]?.cancel()
            return try accepted(command, status: try statusFrom(batch))
        }
        if next == .waitingForReconciliation,
           let invocationID = unresolved?.key
        {
            let failure = try ExecutionFailureFactory.uncertain(
                code: "execution.external-outcome-unknown",
                message: "The external operation outcome must be reconciled before this run can stop."
            )
            let batch = try await commitCommandTransition(
                command,
                state: .waitingForReconciliation,
                failure: failure,
                blockingReason: .reconciliation(invocationID: invocationID)
            )
            await cancelActiveTool(runID: command.runID)
            workers[command.runID]?.cancel()
            return try accepted(command, status: try statusFrom(batch))
        }
        let marker = try commandFailure(
            code: cancel ? "execution.cancel-requested" : "execution.pause-requested",
            message: cancel
                ? "Cancellation will complete at the next safe boundary."
                : "Pause will complete at the next safe boundary."
        )
        let batch = try await commitCommandTransition(
            command,
            state: .pausing,
            diagnostic: marker
        )
        await cancelActiveTool(runID: command.runID)
        workers[command.runID]?.cancel()
        if workers[command.runID] == nil { schedule(runID: command.runID) }
        return try accepted(command, status: try statusFrom(batch))
    }

    private func commitInterruptedToolLifecycleCommand(
        _ command: AgentCommand,
        requestMarker: AgentFailure,
        recovery: InterruptedToolRecoveryFacts
    ) async throws -> CommittedEventBatch {
        let boundaryIsUncertain = recovery.evidence == .legacyConservative
            || (recovery.evidence == .exact && hasRiskyExternalEffects(recovery.prepared.plan))
        let interruption = if boundaryIsUncertain {
            try AgentFailure(
                code: recovery.evidence == .legacyConservative
                    ? "execution.legacy-boundary-claim-uncertain"
                    : "execution.tool-attempt-interrupted-uncertain",
                classification: .potentiallySideEffecting,
                safeMessage: "The interrupted external operation has no stable outcome.",
                retryAdvice: .never,
                externalEffect: .uncertain,
                requiredUserAction: .reconcile,
                details: [
                    "invocationID": recovery.invocationID.description,
                    "attemptNumber": String(recovery.attemptNumber),
                ],
                redaction: Self.publicRedaction
            )
        } else {
            try AgentFailure(
                code: "execution.tool-attempt-interrupted",
                classification: .cancelled,
                safeMessage: "The tool attempt stopped at a confirmed safe boundary.",
                retryAdvice: .never,
                externalEffect: .confirmedNone,
                requiredUserAction: .none,
                details: [
                    "invocationID": recovery.invocationID.description,
                    "attemptNumber": String(recovery.attemptNumber),
                ],
                redaction: Self.publicRedaction
            )
        }
        let retryIsExhausted = recovery.attemptNumber
            >= recovery.prepared.plan.retryPolicy.maximumAttempts
        let isNotSafelyReplayable = !isSafelyReplayable(recovery.prepared.plan)
        let outcome: AgentToolInvocationOutcome? = if boundaryIsUncertain {
            .uncertain(interruption)
        } else if isNotSafelyReplayable {
            .failed(interruption)
        } else if retryIsExhausted {
            .failed(interruption)
        } else {
            nil
        }
        let usage = conservativeUsage(
            for: recovery.reservation,
            completedInvocation: outcome != nil
        )
        guard let ledger = try await repository.loadRunFacts(for: command.runID)?.budgetLedger else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let settled = try ledger.settling(
            reservationID: recovery.reservation.id,
            actualUsage: usage
        )
        return try await commitEvents(
            runID: command.runID,
            identity: .command(command.commandID),
            budgetOperations: [
                .settle(reservationID: recovery.reservation.id, actualUsage: usage),
            ]
        ) { builder in
            var ordinal: UInt16 = 0
            var events = [try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: ordinal
                ),
                event: .diagnostic(requestMarker),
                redaction: Self.publicRedaction
            )]
            ordinal += 1
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: ordinal
                ),
                event: .diagnostic(interruption),
                cumulativeUsage: settled.consumed,
                redaction: Self.publicRedaction
            ))
            ordinal += 1
            if let outcome {
                events.append(try builder.append(
                    id: ExecutionStableID.commandEvent(
                        runID: command.runID,
                        commandID: command.commandID,
                        ordinal: ordinal
                    ),
                    event: .toolOutcomeRecorded(
                        invocationID: recovery.invocationID,
                        outcome: outcome
                    ),
                    redaction: Self.publicRedaction
                ))
                ordinal += 1
            }
            let next: AgentRunState = boundaryIsUncertain
                ? .waitingForReconciliation : .pausing
            let status = try self.status(
                after: builder,
                state: next,
                failure: boundaryIsUncertain ? interruption : nil,
                blockingReason: boundaryIsUncertain
                    ? .reconciliation(invocationID: recovery.invocationID) : nil
            )
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: ordinal
                ),
                event: .statusChanged(status),
                transitionTo: next,
                redaction: Self.publicRedaction
            ))
            return events
        }
    }

    private func applyApproval(
        _ command: AgentCommand,
        approvalID: ApprovalID,
        decision: ApprovalDecision,
        approvedScope: ApprovalScope?,
        history: ExecutionHistory
    ) async throws -> AgentCommandReceipt {
        guard let approval = history.approvals[approvalID], approval.receipt == nil else {
            return try rejected(command, history: history, code: "execution.approval-missing")
        }
        let now = try await clock.now()
        guard approval.request.acceptsDecision(at: now),
              approval.request.policyVersion == policyEngine.policyVersion
        else { return try rejected(command, history: history, code: "execution.approval-expired") }
        let prepared = approval.request.prepared
        let isModelApproval = prepared.plan.kind == .modelProvider
        // Spec §15.2: approving the online model consents to THIS conversation using THIS service, so
        // the receipt is conversation-scoped and reusable across subsequent messages; denials remain
        // exact and terminal.
        let scope: ApprovalScope = isModelApproval
            ? (decision == .approved ? .conversation : .exactInvocation)
            : (approvedScope ?? .exactInvocation)
        let receipt: ApprovalReceipt
        do {
            receipt = try ApprovalReceipt(
                request: approval.request,
                decision: decision,
                scope: scope,
                decidedAt: now
            )
        } catch {
            return try rejected(command, history: history, code: "execution.approval-scope")
        }
        // An approved MODEL request resumes the model path (the worker re-runs the exact prepared
        // attempt, now bound to the receipt); a tool approval resumes tool execution.
        let approvedNext: AgentRunState
        if isModelApproval {
            let purpose = history.manifestEvents.count > history.modelOutcomes.count
                ? history.manifestEvents.last?.3
                : nil
            approvedNext = purpose == .toolFreeSynthesis ? .synthesizing : .waitingForModel
        } else {
            approvedNext = .executingTools
        }
        // Models are not optional tools: denying an online-model request ends the run instead of
        // synthesizing without it.
        if isModelApproval, decision != .approved {
            let failure = try AgentFailure(
                code: decision == .denied
                    ? "execution.model-approval-denied"
                    : "execution.model-approval-cancelled",
                classification: .permissionRelated,
                safeMessage: decision == .denied
                    ? "The online model request was denied."
                    : "The online model request was cancelled.",
                retryAdvice: .never,
                externalEffect: .confirmedNone,
                requiredUserAction: .none,
                details: ["model": prepared.plan.subjectID],
                redaction: Self.publicRedaction
            )
            let batch = try await commitEvents(
                runID: command.runID,
                identity: .command(command.commandID)
            ) { builder in
                var events: [AgentEventEnvelope] = [
                    try builder.append(
                        id: ExecutionStableID.commandEvent(
                            runID: command.runID, commandID: command.commandID, ordinal: 0
                        ),
                        event: .approvalDecided(receipt),
                        redaction: Self.publicRedaction
                    ),
                    try builder.append(
                        id: ExecutionStableID.commandEvent(
                            runID: command.runID, commandID: command.commandID, ordinal: 1
                        ),
                        event: .diagnostic(failure),
                        redaction: Self.publicRedaction
                    ),
                ]
                let terminal = try self.status(
                    after: builder,
                    state: .failed,
                    terminalReason: .permissionDenied,
                    failure: failure
                )
                let result = try AgentResult(
                    requestID: builder.requestID,
                    executionHandleID: builder.handleID,
                    runID: command.runID,
                    status: terminal,
                    answer: nil,
                    usage: builder.usage
                )
                events.append(try builder.append(
                    id: ExecutionStableID.commandEvent(
                        runID: command.runID, commandID: command.commandID, ordinal: 2
                    ),
                    event: .terminal(result),
                    transitionTo: .failed,
                    redaction: Self.publicRedaction
                ))
                return events
            }
            return try accepted(command, status: try statusFrom(batch))
        }
        let next: AgentRunState = decision == .approved ? approvedNext : .synthesizing
        let invocationDescription: String
        if let invocationID = prepared.invocationID {
            invocationDescription = invocationID.description
        } else {
            invocationDescription = "none"
        }
        let descriptorDescription: String
        if let descriptorID = prepared.plan.descriptorID {
            descriptorDescription = descriptorID
        } else {
            descriptorDescription = "none"
        }
        let denial = if decision == .approved {
            Optional<AgentFailure>.none
        } else {
            try AgentFailure(
                code: decision == .denied
                    ? "execution.tool-approval-denied"
                    : "execution.tool-approval-cancelled",
                classification: .permissionRelated,
                safeMessage: decision == .denied
                    ? "The user denied the requested tool operation."
                    : "The user cancelled the requested tool operation.",
                retryAdvice: .never,
                externalEffect: .confirmedNone,
                requiredUserAction: .none,
                details: [
                    "invocationID": invocationDescription,
                    "descriptorID": descriptorDescription,
                ],
                redaction: Self.publicRedaction
            )
        }
        let batch = try await commitEvents(runID: command.runID, identity: .command(command.commandID)) {
            builder in
            var events: [AgentEventEnvelope] = []
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID, commandID: command.commandID, ordinal: 0
                ),
                event: .approvalDecided(receipt),
                redaction: Self.publicRedaction
            ))
            if let denial {
                events.append(try builder.append(
                    id: ExecutionStableID.commandEvent(
                        runID: command.runID, commandID: command.commandID, ordinal: 1
                    ),
                    event: .diagnostic(denial),
                    redaction: Self.publicRedaction
                ))
            }
            let blocking: AgentBlockingReason? = next == .waitingForModel ? .modelResource : nil
            let status = try self.status(after: builder, state: next, blockingReason: blocking)
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID,
                    commandID: command.commandID,
                    ordinal: denial == nil ? 1 : 2
                ),
                event: .statusChanged(status),
                transitionTo: next,
                redaction: Self.publicRedaction
            ))
            return events
        }
        schedule(runID: command.runID)
        return try accepted(command, status: try statusFrom(batch))
    }

    private func applyResponse(
        _ command: AgentCommand,
        response: UserInputResponse,
        history: ExecutionHistory
    ) async throws -> AgentCommandReceipt {
        let responseMatchesSchema: Bool
        if let interaction = history.interactions[response.requestID],
           let schema = interaction.request.responseSchema
        {
            responseMatchesSchema = (try? schema.validates(instance: response.value)) == true
        } else {
            responseMatchesSchema = true
        }
        guard let interaction = history.interactions[response.requestID],
              interaction.response == nil,
              interaction.request.creationStateVersion == command.expectedRunStateVersion,
              responseMatchesSchema
        else { return try rejected(command, history: history, code: "execution.response-invalid") }
        let data = try ExecutionEncoding.encode(response.value)
        let artifact = try await payloadStore.commit(
            data: data,
            mimeType: "application/json",
            semanticType: "agent-user-response.v1",
            runID: command.runID,
            stepID: nil,
            invocationID: nil,
            owner: .run(command.runID),
            sensitivity: .personalData
        )
        let reference = try stableReference(artifact, data: data)
        let batch = try await commitEvents(runID: command.runID, identity: .command(command.commandID)) {
            builder in
            var events: [AgentEventEnvelope] = []
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID, commandID: command.commandID, ordinal: 0
                ),
                event: .artifactCommitted(artifact),
                redaction: Self.publicRedaction
            ))
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID, commandID: command.commandID, ordinal: 1
                ),
                event: .userInputResponseCommitted(
                    requestID: response.requestID,
                    reference: reference
                ),
                redaction: Self.publicRedaction
            ))
            let next = try self.status(
                after: builder,
                state: .waitingForModel,
                blockingReason: .modelResource
            )
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID, commandID: command.commandID, ordinal: 2
                ),
                event: .statusChanged(next),
                transitionTo: .waitingForModel,
                redaction: Self.publicRedaction
            ))
            return events
        }
        schedule(runID: command.runID)
        return try accepted(command, status: try statusFrom(batch))
    }

    private func applyReconciliation(
        _ command: AgentCommand,
        invocationID: ToolInvocationID,
        decision: AgentReconciliationDecision,
        history: ExecutionHistory
    ) async throws -> AgentCommandReceipt {
        guard history.status.state == .waitingForReconciliation,
              history.toolIntents[invocationID] != nil,
              history.toolOutcomes[invocationID] == nil
                || history.toolOutcomes[invocationID].map({
                    if case .uncertain = $0.1 { return true }
                    return false
                }) == true
        else { return try rejected(command, history: history, code: "execution.reconcile-invalid") }
        if decision == .abandoned {
            let failure = try ExecutionFailureFactory.make(
                reason: .externalResultUncertain,
                code: "execution.reconciliation-abandoned",
                message: "The unresolved external operation was abandoned."
            )
            let batch = try await commitTerminal(
                command: command,
                history: history,
                state: .failed,
                reason: .externalResultUncertain,
                failure: failure
            )
            return try accepted(command, status: try statusFrom(batch))
        }
        let diagnostic = try AgentFailure(
            code: decision == .succeeded
                ? "execution.reconciled-succeeded"
                : "execution.reconciled-failed",
            classification: .permanent,
            safeMessage: decision == .succeeded
                ? "The external operation was confirmed successful."
                : "The external operation was confirmed not to have succeeded.",
            retryAdvice: .never,
            externalEffect: decision == .succeeded ? .confirmedApplied : .confirmedNone,
            requiredUserAction: .none,
            details: ["invocationID": invocationID.description],
            redaction: Self.publicRedaction
        )
        let batch = try await commitCommandTransition(
            command,
            state: .synthesizing,
            diagnostic: diagnostic
        )
        schedule(runID: command.runID)
        return try accepted(command, status: try statusFrom(batch))
    }

    private func commitCommandTransition(
        _ command: AgentCommand,
        state: AgentRunState,
        failure: AgentFailure? = nil,
        blockingReason: AgentBlockingReason? = nil,
        diagnostic: AgentFailure? = nil
    ) async throws -> CommittedEventBatch {
        try await commitEvents(runID: command.runID, identity: .command(command.commandID)) {
            builder in
            var events: [AgentEventEnvelope] = []
            var ordinal: UInt16 = 0
            if let diagnostic {
                events.append(try builder.append(
                    id: ExecutionStableID.commandEvent(
                        runID: command.runID, commandID: command.commandID, ordinal: ordinal
                    ),
                    event: .diagnostic(diagnostic),
                    redaction: Self.publicRedaction
                ))
                ordinal += 1
            }
            let next = try self.status(
                after: builder,
                state: state,
                failure: failure,
                blockingReason: blockingReason
            )
            events.append(try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID, commandID: command.commandID, ordinal: ordinal
                ),
                event: .statusChanged(next),
                transitionTo: state,
                redaction: Self.publicRedaction
            ))
            return events
        }
    }

    private func commitCancelled(
        _ command: AgentCommand,
        history: ExecutionHistory
    ) async throws -> CommittedEventBatch {
        let failure = try ExecutionFailureFactory.make(
            reason: .cancelledByUser,
            code: "execution.cancelled",
            message: "The run was cancelled."
        )
        return try await commitTerminal(
            command: command,
            history: history,
            state: .cancelled,
            reason: .cancelledByUser,
            failure: failure
        )
    }

    private func commitTerminal(
        command: AgentCommand,
        history: ExecutionHistory,
        state: AgentRunState,
        reason: AgentTerminalReason,
        failure: AgentFailure?
    ) async throws -> CommittedEventBatch {
        try await commitEvents(runID: command.runID, identity: .command(command.commandID)) {
            builder in
            let terminalStatus = try self.status(
                after: builder,
                state: state,
                terminalReason: reason,
                failure: failure
            )
            let result = try AgentResult(
                requestID: builder.requestID,
                executionHandleID: builder.handleID,
                runID: command.runID,
                status: terminalStatus,
                answer: nil,
                usage: builder.usage
            )
            return [try builder.append(
                id: ExecutionStableID.commandEvent(
                    runID: command.runID, commandID: command.commandID, ordinal: 0
                ),
                event: .terminal(result),
                transitionTo: state,
                redaction: Self.publicRedaction
            )]
        }
    }

    private func accepted(
        _ command: AgentCommand,
        status: AgentRunStatus
    ) throws -> AgentCommandReceipt {
        try AgentCommandReceipt(
            commandID: command.commandID,
            runID: command.runID,
            disposition: .accepted,
            currentStatus: status
        )
    }

    private func rejected(
        _ command: AgentCommand,
        history: ExecutionHistory,
        code: String
    ) throws -> AgentCommandReceipt {
        try AgentCommandReceipt(
            commandID: command.commandID,
            runID: command.runID,
            disposition: .rejected,
            currentStatus: history.status,
            failure: commandFailure(code: code, message: "The command is not valid in the current run state.")
        )
    }

    private func statusFrom(_ batch: CommittedEventBatch) throws -> AgentRunStatus {
        for event in batch.events.reversed() {
            switch event.payload.event {
            case .statusChanged(let status): return status
            case .terminal(let result): return result.status
            default: continue
            }
        }
        throw AgentExecutionError.internalInvariant("command mutation has no status")
    }
}
