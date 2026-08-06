// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// One fully authorized tool invocation ready for execution (serial or parallel).
struct AuthorizedParallelTool {
    let tool: any ToolV2
    let authorized: AuthorizedToolInvocation
    let prepared: PreparedExternalOperationRequest
    let proposed: ProposedToolCall
    let stepID: AgentStepID
    let timestamp: AgentTimestamp
}

private actor ExecutionToolBoundaryUsageAccumulator: ToolBoundaryUsageObserving {
    private struct Charge: Sendable {
        let scope: ToolBoundaryUsageScope
        var closedResponseBytes: UInt64?
    }

    private let runID: AgentRunID
    private let invocationID: ToolInvocationID
    private let maximumRequestBytes: UInt64
    private let maximumResponseBytes: UInt64
    private let maximumResponseBytesPerOperation: UInt64
    private var charges: [StableDigest: Charge] = [:]

    init(
        runID: AgentRunID,
        invocationID: ToolInvocationID,
        maximumRequestBytes: UInt64,
        maximumResponseBytes: UInt64,
        maximumResponseBytesPerOperation: UInt64
    ) {
        self.runID = runID
        self.invocationID = invocationID
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumResponseBytesPerOperation = maximumResponseBytesPerOperation
    }

    func willExecute(_ scope: ToolBoundaryUsageScope) throws {
        guard scope.runID == runID,
              scope.invocationID == invocationID,
              charges[scope.hopFingerprint] == nil,
              scope.maximumResponseBytes <= maximumResponseBytesPerOperation
        else {
            throw AgentExecutionError.internalInvariant("invalid or duplicate tool boundary usage scope")
        }
        let current = try usageQuantities()
        let request = try Self.add(
            current.request,
            scope.requestBytes,
            dimension: .networkRequestBytes
        )
        let response = try Self.add(
            current.response,
            scope.maximumResponseBytes,
            dimension: .networkResponseBytesTotal
        )
        guard request <= maximumRequestBytes else {
            throw AgentContractError.budgetExceeded(
                dimension: .networkRequestBytes,
                limit: maximumRequestBytes,
                requested: request
            )
        }
        guard response <= maximumResponseBytes else {
            throw AgentContractError.budgetExceeded(
                dimension: .networkResponseBytesTotal,
                limit: maximumResponseBytes,
                requested: response
            )
        }
        // Register the conservative response limit before the external operation can begin.
        charges[scope.hopFingerprint] = Charge(scope: scope, closedResponseBytes: nil)
    }

    func didClose(_ scope: ToolBoundaryUsageScope, responseBytes: UInt64) throws {
        guard var charge = charges[scope.hopFingerprint],
              charge.scope == scope,
              responseBytes <= scope.maximumResponseBytes
        else { throw AgentExecutionError.internalInvariant("invalid closed tool boundary usage") }
        if let existing = charge.closedResponseBytes {
            guard existing == responseBytes else {
                throw AgentExecutionError.internalInvariant("conflicting closed tool boundary usage")
            }
            return
        }
        charge.closedResponseBytes = responseBytes
        charges[scope.hopFingerprint] = charge
    }

    func usage() throws -> AgentUsage {
        let value = try usageQuantities()
        return AgentUsage(quantities: BudgetQuantities([
            .networkRequestBytes: value.request,
            .networkResponseBytesPerOperation: value.maximumResponse,
            .networkResponseBytesTotal: value.response,
        ]))
    }

    func hasStartedBoundary() -> Bool { !charges.isEmpty }

    private func usageQuantities() throws -> (
        request: UInt64,
        response: UInt64,
        maximumResponse: UInt64
    ) {
        var request: UInt64 = 0
        var response: UInt64 = 0
        var maximumResponse: UInt64 = 0
        for charge in charges.values {
            request = try Self.add(
                request,
                charge.scope.requestBytes,
                dimension: .networkRequestBytes
            )
            let admitted = charge.closedResponseBytes ?? charge.scope.maximumResponseBytes
            response = try Self.add(
                response,
                admitted,
                dimension: .networkResponseBytesTotal
            )
            maximumResponse = max(maximumResponse, admitted)
        }
        return (request, response, maximumResponse)
    }

    private static func add(
        _ lhs: UInt64,
        _ rhs: UInt64,
        dimension: BudgetDimension
    ) throws -> UInt64 {
        let value = lhs.addingReportingOverflow(rhs)
        guard !value.overflow else { throw AgentContractError.arithmeticOverflow(dimension: dimension) }
        return value.partialValue
    }
}

extension AgentRunController {
    func admitToolBatch(
        facts: RuntimeRunFacts,
        history: ExecutionHistory,
        proposedCalls: [ProposedToolCall]
    ) async throws {
        let frozen = try await frozenInputsForTools(facts)
        let selected = try frozen.selectedTools(latestUserRequest: frozen.currentUser.frozen.content)
        let previous: Set<StableDigest> = Set(history.toolIntents.values.compactMap { intent in
            guard let descriptorText = intent.1.plan.descriptorID,
                  let arguments = intent.1.plan.canonicalArguments
            else { return nil }
            return StableDigest.fingerprint(
                domain: "tool-execution-fingerprint.v1",
                components: [
                    Data(descriptorText.utf8),
                    Data(arguments.fingerprint.rawValue.utf8),
                    Data(intent.1.plan.effects.map(\.rawValue).joined(separator: "\u{0}").utf8),
                ]
            )
        })
        let remaining = max(
            0,
            Int(facts.submission!.request.payload.budget.limits[.toolInvocations])
                - history.toolOutcomes.count
        )
        do {
            _ = try ToolBatchValidator().validate(
                proposedCalls: proposedCalls,
                advertisedDescriptors: selected.descriptors,
                maximumCalls: UInt16(clamping: remaining),
                previouslyExecutedFingerprints: previous
            )
        } catch ToolBatchValidationError.previouslyExecutedCall {
            // Small local models routinely repeat the tool call that just succeeded instead of
            // answering. Suppress the duplicate with one explicit repair instruction; only a second
            // repetition is a real no-progress failure.
            if history.duplicateRepairCount > 0 {
                try await failRun(
                    runID: facts.projection.runID,
                    reason: .noProgress,
                    code: "execution.repeated-tool-call",
                    message: "The model repeated an already executed tool call."
                )
                return
            }
            let repair = try AgentFailure(
                code: "execution.repeated-tool-call",
                classification: .transient,
                safeMessage: "Your last tool call already executed in this turn. Do not call any tool "
                    + "again — answer the user directly.",
                retryAdvice: .never,
                externalEffect: .confirmedNone,
                requiredUserAction: .none,
                redaction: Self.publicRedaction
            )
            let id = ExecutionStableID.event(
                runID: facts.projection.runID,
                key: "repeated-tool-repair-\(facts.projection.eventCount + 1)"
            )
            _ = try await commitEvents(runID: facts.projection.runID, identity: .outcome(id)) {
                builder in
                var events = [try builder.append(
                    id: id,
                    event: .diagnostic(repair),
                    redaction: Self.publicRedaction
                )]
                let waiting = try self.status(
                    after: builder,
                    state: .waitingForModel,
                    blockingReason: .modelResource
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "repeated-tool-repair-waiting"),
                    event: .statusChanged(waiting),
                    transitionTo: .waitingForModel,
                    redaction: Self.publicRedaction
                ))
                return events
            }
            return
        } catch {
            try await failRun(
                runID: facts.projection.runID,
                reason: .internalFailure,
                code: "execution.invalid-tool-batch",
                message: "The model proposed a tool action that could not be validated: "
                    + String(describing: error)
            )
            return
        }
        let id = ExecutionStableID.event(
            runID: facts.projection.runID,
            key: "tool-batch-admitted-\(facts.projection.eventCount + 1)"
        )
        _ = try await commitEvents(runID: facts.projection.runID, identity: .outcome(id)) {
            builder in
            let executing = try self.status(after: builder, state: .executingTools)
            return [try builder.append(
                id: id,
                event: .statusChanged(executing),
                transitionTo: .executingTools,
                redaction: Self.publicRedaction
            )]
        }
    }

    func executeNextTool(facts: RuntimeRunFacts, history: ExecutionHistory) async throws {
        // The durable batch has been admitted, but absence of a live exact descriptor must fail
        // closed rather than dropping the run or executing a mutable replacement.
        guard let reference = history.actionEvents.last?.2 else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let action = try await loadPayload(AgentAction.self, reference: reference)
        guard case .callTools(let calls) = action else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        guard let pending = calls.first(where: {
            history.toolOutcomes[$0.invocationID] == nil
        }) else {
            var needsSynthesis = false
            for call in calls {
                guard let outcome = history.toolOutcomes[call.invocationID]?.1 else { continue }
                if case .failed = outcome {
                    needsSynthesis = true
                    break
                }
            }
            _ = try await transition(
                runID: facts.projection.runID,
                to: needsSynthesis ? .synthesizing : .waitingForModel,
                blocking: needsSynthesis ? nil : .modelResource
            )
            return
        }
        let frozen = try await frozenInputsForTools(facts)
        guard let descriptor = frozen.toolCatalog.descriptor(for: pending.toolID),
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
        try await executeTool(
            live,
            descriptor: descriptor,
            proposed: pending,
            hasMore: calls.contains(where: {
                $0.invocationID != pending.invocationID
                    && history.toolOutcomes[$0.invocationID] == nil
            }),
            facts: facts,
            history: history
        )
    }

    func frozenInputsForTools(_ facts: RuntimeRunFacts) async throws -> FrozenAgentRunInputs {
        guard let submission = facts.submission else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        return try await loadPayload(FrozenAgentRunInputs.self, reference: submission.inputSnapshot)
    }

    private func executeTool(
        _ tool: any ToolV2,
        descriptor: AgentToolDescriptor,
        proposed: ProposedToolCall,
        hasMore: Bool,
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws {
        guard let authorizedTool = try await prepareAndAuthorizeTool(
            tool,
            descriptor: descriptor,
            proposed: proposed,
            facts: facts,
            history: history
        ) else { return }
        try await executeAuthorizedTool(
            authorizedTool.tool,
            authorized: authorizedTool.authorized,
            prepared: authorizedTool.prepared,
            proposed: authorizedTool.proposed,
            stepID: authorizedTool.stepID,
            initialTimestamp: authorizedTool.timestamp,
            hasMore: hasMore,
            budget: facts.submission!.request.payload.budget,
            history: history
        )
    }

    /// Prepares and authorizes one tool call, returning nil when the run stopped at an approval
    /// request or a policy denial (both already journaled). Shared by the serial and parallel batch
    /// paths so every invocation crosses the same prepare -> authorize boundary exactly once.
    func prepareAndAuthorizeTool(
        _ tool: any ToolV2,
        descriptor: AgentToolDescriptor,
        proposed: ProposedToolCall,
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws -> AuthorizedParallelTool? {
        guard let request = facts.submission?.request.payload else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let sanitized = try sanitizer.sanitize(
            proposed.arguments,
            referencedSecretIDs: [],
            redaction: try RedactionMetadata(classification: .sensitive, policyVersion: 1)
        )
        let executionRequest = try ToolExecutionRequest(
            proposedCall: proposed,
            descriptor: descriptor,
            sanitizedArguments: sanitized
        )
        let grant = try StepCapabilityGrant(
            runCeiling: request.capabilityCeiling,
            authority: request.capabilityCeiling.authority
        )
        let stepID = history.actionEvents.last!.1
        let preparationContext = ToolPreparationContext(
            requestID: request.id,
            runID: request.runID,
            conversationID: request.conversationID,
            stepID: stepID,
            capabilityGrant: grant
        )
        let prepared: PreparedToolInvocation
        let durablePreparation = history.toolIntents[proposed.invocationID]?.1
            ?? history.approvals.values.lazy
                .map(\.request.prepared)
                .first(where: { $0.invocationID == proposed.invocationID })
        if let durable = durablePreparation {
            // Preparation is deliberately not rerun after approval, pause, or process recovery.
            // Reconstruct the closure-free value from the exact durable plan and current frozen
            // request; the initializer revalidates every descriptor/schema/authority binding.
            prepared = try PreparedToolInvocation(
                request: executionRequest,
                context: preparationContext,
                plan: durable.plan
            )
            guard prepared.externalOperation == durable else {
                throw AgentExecutionError.invalidRecoveryBoundary
            }
        } else {
            prepared = try await tool.prepare(
                request: executionRequest,
                context: preparationContext
            )
        }
        guard prepared.request.descriptor == descriptor else {
            throw ToolV2ContractError.preparedPlanMismatch
        }
        let now = try await clock.now()
        let authority = try TrustedRunAuthority(
            runID: request.runID,
            ceiling: request.capabilityCeiling,
            policyRevision: UInt64(policyEngine.policyVersion)
        )
        let reusable = try await reusableApprovals.candidateReceipts(
            conversationID: request.conversationID,
            prepared: prepared.externalOperation
        )
        let evaluation = policyEngine.evaluate(
            prepared: prepared.externalOperation,
            trustedRunAuthority: authority,
            interaction: interactionContext,
            candidateReceipts: history.approvals.values.compactMap(\.receipt) + reusable,
            at: now,
            approvalMode: request.approvalMode
        )
        let approvalID = ExecutionStableID.approval(
            runID: request.runID,
            invocationID: proposed.invocationID
        )
        if let persistedApproval = history.approvals[approvalID]?.request,
           persistedApproval.prepared != prepared.externalOperation
        {
            try await failRun(
                runID: request.runID,
                reason: .toolUnavailable,
                code: "execution.approved-tool-plan-changed",
                message: "The tool plan changed after approval and cannot be executed."
            )
            return nil
        }
        let authorization: AuthorizedExternalOperationRequest
        switch evaluation.authorization.decision {
        case .authorizeLocalPolicy:
            authorization = try await policyEngine.bindApprovalMode(
                prepared: prepared.externalOperation,
                approvalID: approvalID,
                trustedRunAuthority: authority,
                at: now
            )
        case .authorizeMatchingReceipt:
            guard let receipt = evaluation.matchingReceipt else {
                throw AgentExecutionError.approvalUnavailable
            }
            authorization = try await policyEngine.bind(
                prepared: prepared.externalOperation,
                receipt: receipt,
                trustedRunAuthority: authority,
                at: now
            )
        case .requireApproval:
            try await requestApproval(
                approvalID: approvalID,
                prepared: prepared.externalOperation,
                createdAt: now
            )
            return nil
        case .deny:
            try await failRun(
                runID: request.runID,
                reason: .permissionDenied,
                code: "execution.tool-authorization-denied",
                message: "The tool operation was denied by local policy."
            )
            return nil
        }
        let authorized = try AuthorizedToolInvocation(
            prepared: prepared,
            authorization: authorization
        )
        return AuthorizedParallelTool(
            tool: tool,
            authorized: authorized,
            prepared: prepared.externalOperation,
            proposed: proposed,
            stepID: stepID,
            timestamp: now
        )
    }

    func executeAuthorizedTool(
        _ tool: any ToolV2,
        authorized: AuthorizedToolInvocation,
        prepared: PreparedExternalOperationRequest,
        proposed: ProposedToolCall,
        stepID: AgentStepID,
        initialTimestamp: AgentTimestamp,
        hasMore: Bool,
        deferTerminalDecisions: Bool = false,
        budget: AgentBudget,
        history: ExecutionHistory
    ) async throws {
        let invocationID = proposed.invocationID
        let isNewIntent = history.toolIntents[invocationID] == nil
        let previousAttemptCount = recordedToolAttemptCount(
            history: history,
            invocationID: invocationID
        )
        var attemptNumber = UInt16(clamping: max(1, previousAttemptCount))
        let externalBytes = requiresExternalByteAccounting(prepared.plan)
        var reservation = try toolReservation(
            runID: prepared.runID,
            invocationID: invocationID,
            prepared: prepared,
            attemptNumber: attemptNumber,
            externalBytes: externalBytes,
            budget: budget
        )
        guard let durableFacts = try await repository.loadRunFacts(for: prepared.runID),
              let durableLedger = durableFacts.budgetLedger
        else { throw AgentExecutionError.invalidRecoveryBoundary }
        let executionHandleID = durableFacts.projection.executionHandleID
        let durableReservations = durableLedger.reservations
        let expectedCurrentReservation = try toolReservation(
            runID: prepared.runID,
            invocationID: invocationID,
            prepared: prepared,
            attemptNumber: attemptNumber,
            externalBytes: externalBytes,
            budget: budget
        )
        let outstanding = durableReservations.first {
            $0.id == expectedCurrentReservation.id
        }
        let settledInterruptedAttempt = !isNewIntent && outstanding == nil
            && history.diagnostics.contains { _, failure in
                failure.code == "execution.tool-attempt-interrupted"
                    && failure.details["invocationID"] == invocationID.description
                    && failure.details["attemptNumber"] == String(attemptNumber)
            }
        if !isNewIntent, outstanding == nil, !settledInterruptedAttempt {
            throw AgentExecutionError.invalidRecoveryBoundary
        }

        if isNewIntent {
            attemptNumber = 1
            reservation = try toolReservation(
                runID: prepared.runID,
                invocationID: invocationID,
                prepared: prepared,
                attemptNumber: attemptNumber,
                externalBytes: externalBytes,
                budget: budget
            )
            try await commitToolAttemptStart(
                prepared: prepared,
                invocationID: invocationID,
                attemptNumber: attemptNumber,
                approvalID: authorized.authorization.authorization.id,
                reservation: reservation,
                intent: prepared,
                previous: nil
            )
        } else if let outstanding {
            let interruptedAttempt = try ExternalOperationAttempt(
                prepared: prepared,
                attemptNumber: attemptNumber
            )
            guard let durableApprovalID = recordedToolAttemptApprovalID(
                history: history,
                invocationID: invocationID,
                attemptNumber: attemptNumber
            ) else { throw AgentExecutionError.invalidRecoveryBoundary }
            let claimEvidence = try await repository.boundaryClaimEvidence(
                approvalID: durableApprovalID,
                prepared: prepared,
                attempt: interruptedAttempt
            )
            if claimEvidence == .legacyConservative {
                let legacy = try ExecutionFailureFactory.uncertain(
                    code: "execution.legacy-boundary-claim-uncertain",
                    message: "A legacy boundary claim lacks the exact authorization evidence required for automatic replay."
                )
                try await commitToolOutcome(
                    .uncertain(legacy),
                    prepared: prepared,
                    reservation: outstanding,
                    actualUsage: conservativeUsage(
                        for: outstanding,
                        completedInvocation: true
                    ),
                    invocationID: invocationID,
                    hasMore: hasMore,
                    deferTerminalDecisions: deferTerminalDecisions,
                    history: history
                )
                return
            }
            guard durableApprovalID == authorized.authorization.authorization.id else {
                throw AgentExecutionError.invalidRecoveryBoundary
            }
            if claimEvidence == .none {
                // A crash before the durable gate claim cannot have crossed the boundary. Resume
                // the exact attempt and reservation; incrementing the retry ordinal here would
                // make a `.never` plan invalid and double-charge the budget.
                reservation = outstanding
            } else if isSafelyReplayable(prepared.plan),
                      attemptNumber < prepared.plan.retryPolicy.maximumAttempts
            {
                let nextAttempt = attemptNumber + 1
                let nextReservation = try toolReservation(
                    runID: prepared.runID,
                    invocationID: invocationID,
                    prepared: prepared,
                    attemptNumber: nextAttempt,
                    externalBytes: externalBytes,
                    budget: budget
                )
                try await commitToolAttemptStart(
                    prepared: prepared,
                    invocationID: invocationID,
                    attemptNumber: nextAttempt,
                    approvalID: authorized.authorization.authorization.id,
                    reservation: nextReservation,
                    intent: nil,
                    previous: (
                        outstanding,
                        conservativeUsage(for: outstanding, completedInvocation: false)
                    )
                )
                attemptNumber = nextAttempt
                reservation = nextReservation
            } else if !hasRiskyExternalEffects(prepared.plan) {
                let exhausted = try typedToolFailure(
                    ToolV2ContractError.providerThrewBeforeTerminal,
                    plan: prepared.plan,
                    attemptNumber: attemptNumber,
                    boundaryStarted: false,
                    forcePermanent: true
                )
                try await commitToolOutcome(
                    .failed(exhausted),
                    prepared: prepared,
                    reservation: outstanding,
                    actualUsage: conservativeUsage(
                        for: outstanding,
                        completedInvocation: true
                    ),
                    invocationID: invocationID,
                    hasMore: hasMore,
                    deferTerminalDecisions: deferTerminalDecisions,
                    history: history
                )
                return
            } else {
                let uncertain = try ExecutionFailureFactory.uncertain(
                    code: "execution.tool-recovery-uncertain",
                    message: "The interrupted tool operation crossed its boundary without a durable outcome."
                )
                try await commitToolOutcome(
                    .uncertain(uncertain),
                    prepared: prepared,
                    reservation: outstanding,
                    actualUsage: conservativeUsage(
                        for: outstanding,
                        completedInvocation: true
                    ),
                    invocationID: invocationID,
                    hasMore: hasMore,
                    deferTerminalDecisions: deferTerminalDecisions,
                    history: history
                )
                return
            }
        } else {
            guard isSafelyReplayable(prepared.plan),
                  attemptNumber < prepared.plan.retryPolicy.maximumAttempts
            else {
                let stopped = try AgentFailure(
                    code: "execution.tool-interrupted-confirmed-none",
                    classification: .cancelled,
                    safeMessage: "The tool stopped before applying an external effect.",
                    retryAdvice: .never,
                    externalEffect: .confirmedNone,
                    requiredUserAction: .none,
                    redaction: Self.publicRedaction
                )
                try await commitToolOutcome(
                    .failed(stopped),
                    prepared: prepared,
                    reservation: nil,
                    actualUsage: .zero,
                    invocationID: invocationID,
                    hasMore: hasMore,
                    deferTerminalDecisions: deferTerminalDecisions,
                    history: history
                )
                return
            }
            let nextAttempt = attemptNumber + 1
            reservation = try toolReservation(
                runID: prepared.runID,
                invocationID: invocationID,
                prepared: prepared,
                attemptNumber: nextAttempt,
                externalBytes: externalBytes,
                budget: budget
            )
            try await commitToolAttemptStart(
                prepared: prepared,
                invocationID: invocationID,
                attemptNumber: nextAttempt,
                approvalID: authorized.authorization.authorization.id,
                reservation: reservation,
                intent: nil,
                previous: nil
            )
            attemptNumber = nextAttempt
        }

        let writer = try await payloadStore.toolArtifactWriter(
            runID: prepared.runID,
            stepID: stepID,
            invocationID: invocationID
        )
        var timestamp = initialTimestamp
        while true {
            try Task.checkCancellation()
            let usageObserver = try boundaryUsageAccumulator(
                prepared: prepared,
                invocationID: invocationID,
                externalBytes: externalBytes
            )
            let deadline = timestamp.rawValue.addingReportingOverflow(
                Int64(clamping: prepared.plan.timeoutMilliseconds)
            )
            guard !deadline.overflow else { throw ToolV2ContractError.invalidExecutionContext }
            let cancellation = ExecutionCancellationToken()
            let context = try ToolExecutionContext(
                authorized: authorized,
                deadline: AgentTimestamp(rawValue: deadline.partialValue),
                attemptNumber: attemptNumber,
                budgetReservationID: reservation.id,
                cancellation: cancellation,
                artifactWriter: writer,
                logger: logger,
                authorizationClock: clock,
                authorizationPolicyValidator: policyEngine,
                attemptLedger: ScopedExternalOperationAttemptLedger(
                    repository: repository,
                    scope: try RuntimeBoundaryClaimScope(
                        runID: prepared.runID,
                        expectedState: .executingTools,
                        expectedStateVersion: durableFacts.projection.stateVersion
                    )
                ),
                boundaryUsageObserver: usageObserver
            )
            try registerToolCancellation(
                cancellation,
                runID: prepared.runID,
                invocationID: invocationID
            )
            var outcome: AgentToolInvocationOutcome
            do {
                outcome = try await ToolExecutor().execute(
                    tool: tool,
                    authorized: authorized,
                    context: context,
                    eventSink: ControllerToolEventSink(
                        controller: self,
                        executionHandleID: executionHandleID,
                        runID: prepared.runID,
                        stepID: stepID,
                        invocationID: invocationID
                    )
                )
            } catch is CancellationError {
                clearToolCancellation(runID: prepared.runID, invocationID: invocationID)
                let runtimeCancellationRequested = await cancellation.isCancelled()
                if Task.isCancelled || runtimeCancellationRequested {
                    try await settleInterruptedToolAttempt(
                        prepared: prepared,
                        invocationID: invocationID,
                        attemptNumber: attemptNumber,
                        approvalID: authorized.authorization.authorization.id,
                        reservation: reservation,
                        usageObserver: usageObserver,
                        externalBytes: externalBytes,
                        startedAt: timestamp
                    )
                    throw CancellationError()
                }
                // A tool can throw `CancellationError` for its own timeout or internal work even
                // though the runtime never requested pause/cancel. Treat that as a provider
                // failure; otherwise the worker exits with the run permanently stranded in
                // `.executingTools` and an outstanding budget reservation.
                let failure = try typedToolFailure(
                    ToolV2ContractError.providerThrewBeforeTerminal,
                    plan: prepared.plan,
                    attemptNumber: attemptNumber,
                    boundaryStarted: await usageObserver.hasStartedBoundary()
                )
                outcome = failure.externalEffect == .uncertain
                    ? .uncertain(failure)
                    : .failed(failure)
            } catch {
                clearToolCancellation(runID: prepared.runID, invocationID: invocationID)
                if Task.isCancelled {
                    try await settleInterruptedToolAttempt(
                        prepared: prepared,
                        invocationID: invocationID,
                        attemptNumber: attemptNumber,
                        approvalID: authorized.authorization.authorization.id,
                        reservation: reservation,
                        usageObserver: usageObserver,
                        externalBytes: externalBytes,
                        startedAt: timestamp
                    )
                    throw CancellationError()
                }
                let failure = try typedToolFailure(
                    error,
                    plan: prepared.plan,
                    attemptNumber: attemptNumber,
                    boundaryStarted: await usageObserver.hasStartedBoundary()
                )
                outcome = failure.externalEffect == .uncertain
                    ? .uncertain(failure)
                    : .failed(failure)
            }
            let boundaryStarted = await usageObserver.hasStartedBoundary()
            if boundaryStarted,
               hasRiskyExternalEffects(prepared.plan),
               case .failed = outcome
            {
                outcome = .uncertain(try ExecutionFailureFactory.uncertain(
                    code: "execution.tool-returned-failure-uncertain",
                    message: "The tool reported failure after crossing a side-effect boundary, so its external result must be reconciled."
                ))
            }
            if case .completed = outcome {
                let boundaryRequired = requiresExecutionBoundary(prepared.plan)
                if boundaryRequired != boundaryStarted {
                    let violation: ToolV2ContractError = boundaryRequired
                        ? .boundaryRequired : .boundaryForbidden
                    outcome = .failed(try typedToolFailure(
                        violation,
                        plan: prepared.plan,
                        attemptNumber: attemptNumber,
                        boundaryStarted: boundaryStarted,
                        forcePermanent: true
                    ))
                }
            }
            clearToolCancellation(runID: prepared.runID, invocationID: invocationID)
            var attemptUsage = externalBytes ? try await usageObserver.usage() : .zero
            let completedAt = try await clock.now()
            let elapsedDelta = completedAt.rawValue.subtractingReportingOverflow(timestamp.rawValue)
            let elapsed = !elapsedDelta.overflow && elapsedDelta.partialValue >= 0
                ? UInt64(elapsedDelta.partialValue)
                : prepared.plan.timeoutMilliseconds
            let encodedOutcome = try ExecutionEncoding.encode(outcome)
            let persistedBytes = UInt64(encodedOutcome.count)
            attemptUsage = try attemptUsage.adding(AgentUsage(quantities: BudgetQuantities([
                .activeMilliseconds: min(elapsed, prepared.plan.timeoutMilliseconds),
                .persistedOutputBytes: persistedBytes,
                .repeatedCallsPerFingerprint: 1,
            ])))

            if case .failed(let failure) = outcome,
               shouldRetry(
                   failure: failure,
                   plan: prepared.plan,
                   attemptNumber: attemptNumber
               )
            {
                let nextAttempt = attemptNumber + 1
                let nextReservation = try toolReservation(
                    runID: prepared.runID,
                    invocationID: invocationID,
                prepared: prepared,
                attemptNumber: nextAttempt,
                externalBytes: externalBytes,
                budget: budget
                )
                try await commitToolAttemptStart(
                    prepared: prepared,
                    invocationID: invocationID,
                    attemptNumber: nextAttempt,
                    approvalID: authorized.authorization.authorization.id,
                    reservation: nextReservation,
                    intent: nil,
                    previous: (reservation, attemptUsage)
                )
                try await clock.sleep(milliseconds: retryDelay(
                    plan: prepared.plan,
                    invocationID: invocationID,
                    completedAttempt: attemptNumber
                ))
                attemptNumber = nextAttempt
                reservation = nextReservation
                timestamp = try await clock.now()
                continue
            }

            let finalHistory = try await loadRun(prepared.runID).1
            let precedingNoProgress = finalHistory.toolOutcomes.values
                .sorted { $0.0.sequence < $1.0.sequence }
                .reversed()
                .prefix { isSemanticNoProgress($0.1) }
                .count
            let consecutiveNoProgress = isSemanticNoProgress(outcome)
                ? UInt64(clamping: precedingNoProgress + 1) : 0
            var finalUsage = try attemptUsage.adding(AgentUsage(quantities: BudgetQuantities([
                .consecutiveNoProgressActions: consecutiveNoProgress,
            ])))
            finalUsage = try finalUsage.adding(AgentUsage(quantities: BudgetQuantities([
                .toolInvocations: 1,
            ])))
            try await commitToolOutcome(
                outcome,
                prepared: prepared,
                reservation: reservation,
                actualUsage: finalUsage,
                invocationID: invocationID,
                hasMore: hasMore,
                deferTerminalDecisions: deferTerminalDecisions,
                history: finalHistory
            )
            return
        }
    }

    private func settleInterruptedToolAttempt(
        prepared: PreparedExternalOperationRequest,
        invocationID: ToolInvocationID,
        attemptNumber: UInt16,
        approvalID: ApprovalID,
        reservation: BudgetReservation,
        usageObserver: ExecutionToolBoundaryUsageAccumulator,
        externalBytes: Bool,
        startedAt: AgentTimestamp
    ) async throws {
        var usage = externalBytes ? try await usageObserver.usage() : .zero
        let stoppedAt = try await clock.now()
        let elapsedDelta = stoppedAt.rawValue.subtractingReportingOverflow(startedAt.rawValue)
        let elapsed = !elapsedDelta.overflow && elapsedDelta.partialValue >= 0
            ? UInt64(elapsedDelta.partialValue)
            : prepared.plan.timeoutMilliseconds
        usage = try usage.adding(AgentUsage(quantities: BudgetQuantities([
            .activeMilliseconds: min(elapsed, prepared.plan.timeoutMilliseconds),
            .repeatedCallsPerFingerprint: 1,
        ])))
        let riskyEffects: Set<AgentEffect> = [
            .unknownExternal, .externalWrite, .externalCommunication,
            .destructive, .financial, .codeExecution,
        ]
        let attempt = try ExternalOperationAttempt(
            prepared: prepared,
            attemptNumber: attemptNumber
        )
        let claimEvidence = try await repository.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: prepared,
            attempt: attempt
        )
        let boundaryUsageStarted = await usageObserver.hasStartedBoundary()
        let boundaryWasClaimed = claimEvidence != .none || boundaryUsageStarted
        let isUncertain = boundaryWasClaimed
            && !Set(prepared.plan.effects).isDisjoint(with: riskyEffects)
        let diagnostic = isUncertain
            ? try AgentFailure(
                code: "execution.tool-attempt-interrupted-uncertain",
                classification: .potentiallySideEffecting,
                safeMessage: "The cancelled external operation has no stable outcome.",
                retryAdvice: .never,
                externalEffect: .uncertain,
                requiredUserAction: .reconcile,
                details: [
                    "invocationID": invocationID.description,
                    "attemptNumber": String(attemptNumber),
                ],
                redaction: Self.publicRedaction
            )
            : try AgentFailure(
                code: "execution.tool-attempt-interrupted",
                classification: .cancelled,
                safeMessage: "The tool attempt stopped at a cancellation boundary.",
                retryAdvice: .never,
                externalEffect: .confirmedNone,
                requiredUserAction: .none,
                details: [
                    "invocationID": invocationID.description,
                    "attemptNumber": String(attemptNumber),
                ],
                redaction: Self.publicRedaction
            )
        let finalOutcome: AgentToolInvocationOutcome? = if isUncertain {
            // Reconciliation must always have an invocation-specific durable fact. A diagnostic
            // alone is insufficient because synthesis after reconciliation consumes tool outcomes.
            .uncertain(diagnostic)
        } else if !isSafelyReplayable(prepared.plan)
            || attemptNumber >= prepared.plan.retryPolicy.maximumAttempts
        {
            .failed(diagnostic)
        } else {
            nil
        }
        if let finalOutcome {
            let persistedBytes = UInt64(try ExecutionEncoding.encode(finalOutcome).count)
            usage = try usage.adding(AgentUsage(quantities: BudgetQuantities([
                .toolInvocations: 1,
                .persistedOutputBytes: persistedBytes,
            ])))
        }
        let eventID = ExecutionStableID.event(
            runID: prepared.runID,
            key: "tool-attempt-interrupted-\(invocationID.description)-\(attemptNumber)"
        )
        _ = try await commitEventsSettling(
            runID: prepared.runID,
            identity: .outcome(eventID)
        ) { currentLedger in
            let settled = try currentLedger.settling(
                reservationID: reservation.id,
                actualUsage: usage
            )
            return (
                settled,
                [.settle(reservationID: reservation.id, actualUsage: usage)]
            )
        } build: { builder, settled in
            var events = [try builder.append(
                id: eventID,
                event: .diagnostic(diagnostic),
                cumulativeUsage: settled.consumed,
                redaction: Self.publicRedaction
            )]
            if let finalOutcome {
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "tool-interrupted-outcome"),
                    event: .toolOutcomeRecorded(
                        invocationID: invocationID,
                        outcome: finalOutcome
                    ),
                    redaction: Self.publicRedaction
                ))
            }
            return events
        }
    }

    func requestApproval(
        approvalID: ApprovalID,
        prepared: PreparedExternalOperationRequest,
        createdAt: AgentTimestamp
    ) async throws {
        let approval = try AgentApprovalRequest(
            id: approvalID,
            prepared: prepared,
            policyVersion: policyEngine.policyVersion,
            createdAt: createdAt
        )
        let id = ExecutionStableID.event(
            runID: prepared.runID,
            key: "approval-request-\(approvalID.description)"
        )
        _ = try await commitEvents(runID: prepared.runID, identity: .outcome(id)) { builder in
            var events = [try builder.append(
                id: id,
                event: .approvalRequested(approval),
                redaction: Self.publicRedaction
            )]
            let waiting = try self.status(
                after: builder,
                state: .waitingForApproval,
                blockingReason: .approval(approvalID: approvalID)
            )
            events.append(try builder.append(
                id: self.nextEventID(builder, key: "waiting-approval"),
                event: .statusChanged(waiting),
                transitionTo: .waitingForApproval,
                redaction: Self.publicRedaction
            ))
            return events
        }
    }

    func toolReservation(
        runID: AgentRunID,
        invocationID: ToolInvocationID,
        prepared: PreparedExternalOperationRequest,
        attemptNumber: UInt16,
        externalBytes: Bool,
        budget: AgentBudget
    ) throws -> BudgetReservation {
        let hopCount = UInt64(clamping: 1
            + prepared.plan.allowedRedirects.count
            + prepared.plan.allowedFallbacks.count)
        let requestBytes = externalBytes
            ? try checkedMultiply(
                prepared.plan.maximumRequestBytes,
                hopCount,
                dimension: .networkRequestBytes
            )
            : 0
        let responseBytes = externalBytes
            ? try checkedMultiply(
                prepared.plan.maximumResponseBytes,
                hopCount,
                dimension: .networkResponseBytesTotal
            )
            : 0
        return try BudgetReservation(
            id: ExecutionStableID.reservation(
                runID: runID,
                kind: "tool",
                stableID: "\(invocationID.description)-attempt-\(attemptNumber)"
            ),
            maximumUsage: AgentUsage(quantities: BudgetQuantities([
                .toolInvocations: 1,
                .repeatedCallsPerFingerprint: 1,
                .consecutiveNoProgressActions: budget.limits[.consecutiveNoProgressActions],
                .activeMilliseconds: prepared.plan.timeoutMilliseconds,
                .networkRequestBytes: requestBytes,
                .networkResponseBytesPerOperation: externalBytes
                    ? prepared.plan.maximumResponseBytes : 0,
                .networkResponseBytesTotal: responseBytes,
                .persistedOutputBytes: prepared.plan.maximumResponseBytes,
            ])),
            reason: "tool-invocation-attempt"
        )
    }

    private func commitToolAttemptStart(
        prepared: PreparedExternalOperationRequest,
        invocationID: ToolInvocationID,
        attemptNumber: UInt16,
        approvalID: ApprovalID,
        reservation: BudgetReservation,
        intent: PreparedExternalOperationRequest?,
        previous: (reservation: BudgetReservation, usage: AgentUsage)?
    ) async throws {
        let eventID = ExecutionStableID.event(
            runID: prepared.runID,
            key: "tool-attempt-start-\(invocationID.description)-\(attemptNumber)"
        )
        let diagnostic = try AgentFailure(
            code: "execution.tool-attempt-started",
            classification: .transient,
            safeMessage: "A bounded tool attempt started.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            details: [
                "invocationID": invocationID.description,
                "attemptNumber": String(attemptNumber),
                "approvalID": approvalID.description,
            ],
            redaction: Self.publicRedaction
        )
        _ = try await commitEventsSettling(
            runID: prepared.runID,
            identity: .outcome(eventID)
        ) { currentLedger in
            var ledger = currentLedger
            var operations: [BudgetLedgerOperation] = []
            if let previous {
                ledger = try ledger.settling(
                    reservationID: previous.reservation.id,
                    actualUsage: previous.usage
                )
                operations.append(.settle(
                    reservationID: previous.reservation.id,
                    actualUsage: previous.usage
                ))
            }
            ledger = try ledger.reserving(reservation)
            operations.append(.reserve(reservation))
            return (ledger, operations)
        } build: { builder, ledger in
            var events: [AgentEventEnvelope] = []
            if let intent {
                events.append(try builder.append(
                    id: ExecutionStableID.event(
                        runID: prepared.runID,
                        key: "tool-intent-\(invocationID.description)"
                    ),
                    event: .toolIntentRecorded(intent),
                    redaction: Self.publicRedaction
                ))
            }
            events.append(try builder.append(
                id: eventID,
                event: .diagnostic(diagnostic),
                cumulativeUsage: ledger.consumed,
                redaction: Self.publicRedaction
            ))
            return events
        }
    }

    func recordedToolAttemptCount(
        history: ExecutionHistory,
        invocationID: ToolInvocationID
    ) -> Int {
        history.diagnostics.reduce(into: 0) { highest, entry in
            guard entry.1.code == "execution.tool-attempt-started",
                  entry.1.details["invocationID"] == invocationID.description,
                  let rawAttempt = entry.1.details["attemptNumber"],
                  let attempt = Int(rawAttempt)
            else { return }
            highest = max(highest, attempt)
        }
    }

    func recordedToolAttemptApprovalID(
        history: ExecutionHistory,
        invocationID: ToolInvocationID,
        attemptNumber: UInt16
    ) -> ApprovalID? {
        guard let raw = history.diagnostics.reversed().first(where: { entry in
            entry.1.code == "execution.tool-attempt-started"
                && entry.1.details["invocationID"] == invocationID.description
                && entry.1.details["attemptNumber"] == String(attemptNumber)
        })?.1.details["approvalID"],
            let uuid = UUID(uuidString: raw)
        else { return nil }
        return ApprovalID(rawValue: uuid)
    }

    private func boundaryUsageAccumulator(
        prepared: PreparedExternalOperationRequest,
        invocationID: ToolInvocationID,
        externalBytes: Bool
    ) throws -> ExecutionToolBoundaryUsageAccumulator {
        guard externalBytes else {
            return ExecutionToolBoundaryUsageAccumulator(
                runID: prepared.runID,
                invocationID: invocationID,
                maximumRequestBytes: UInt64.max,
                maximumResponseBytes: UInt64.max,
                maximumResponseBytesPerOperation: UInt64.max
            )
        }
        let hops = UInt64(clamping: 1
            + prepared.plan.allowedRedirects.count
            + prepared.plan.allowedFallbacks.count)
        return ExecutionToolBoundaryUsageAccumulator(
            runID: prepared.runID,
            invocationID: invocationID,
            maximumRequestBytes: try checkedMultiply(
                prepared.plan.maximumRequestBytes,
                hops,
                dimension: .networkRequestBytes
            ),
            maximumResponseBytes: try checkedMultiply(
                prepared.plan.maximumResponseBytes,
                hops,
                dimension: .networkResponseBytesTotal
            ),
            maximumResponseBytesPerOperation: prepared.plan.maximumResponseBytes
        )
    }

    private func checkedMultiply(
        _ lhs: UInt64,
        _ rhs: UInt64,
        dimension: BudgetDimension
    ) throws -> UInt64 {
        let value = lhs.multipliedReportingOverflow(by: rhs)
        guard !value.overflow else { throw AgentContractError.arithmeticOverflow(dimension: dimension) }
        return value.partialValue
    }

    func requiresExternalByteAccounting(_ plan: ExternalOperationPlan) -> Bool {
        let networkDestinations: Set<ExternalDestination.Kind> = [
            .networkEndpoint, .mcpServer, .modelProvider,
        ]
        let destinations = [plan.destination].compactMap { $0 }
            + plan.allowedRedirects
            + plan.allowedFallbacks
        if destinations.contains(where: { networkDestinations.contains($0.kind) }) {
            return true
        }
        let externallyMetered: Set<AgentEffect> = [
            .networkRead, .unknownExternal, .externalWrite, .externalCommunication,
        ]
        return !Set(plan.effects).isDisjoint(with: externallyMetered)
    }

    private func requiresExecutionBoundary(_ plan: ExternalOperationPlan) -> Bool {
        plan.destination != nil || !plan.effects.allSatisfy { $0 == .localPure }
    }

    func hasRiskyExternalEffects(_ plan: ExternalOperationPlan) -> Bool {
        let risky: Set<AgentEffect> = [
            .unknownExternal, .externalWrite, .externalCommunication,
            .destructive, .financial, .codeExecution,
        ]
        return !Set(plan.effects).isDisjoint(with: risky)
    }

    func isSafelyReplayable(_ plan: ExternalOperationPlan) -> Bool {
        switch plan.idempotency {
        case .pureRead: true
        case .idempotencyKeyRequired: plan.idempotencyKey != nil
        case .reconciliationAvailable, .nonIdempotent: false
        }
    }

    private func shouldRetry(
        failure: AgentFailure,
        plan: ExternalOperationPlan,
        attemptNumber: UInt16
    ) -> Bool {
        plan.retryPolicy.kind == .boundedExponential
            && attemptNumber < plan.retryPolicy.maximumAttempts
            && isSafelyReplayable(plan)
            && failure.classification == .transient
            && failure.retryAdvice.automaticallyRetryable
            && failure.externalEffect != .uncertain
    }

    private func retryDelay(
        plan: ExternalOperationPlan,
        invocationID: ToolInvocationID,
        completedAttempt: UInt16
    ) -> UInt64 {
        var delay = plan.retryPolicy.baseDelayMilliseconds
        if completedAttempt > 1 {
            for _ in 1 ..< completedAttempt {
                if delay >= plan.retryPolicy.maximumDelayMilliseconds { break }
                let doubled = delay.multipliedReportingOverflow(by: 2)
                delay = doubled.overflow
                    ? plan.retryPolicy.maximumDelayMilliseconds
                    : min(doubled.partialValue, plan.retryPolicy.maximumDelayMilliseconds)
            }
        }
        guard plan.retryPolicy.allowsJitter, delay > 1 else { return delay }
        let digest = StableDigest.fingerprint(
            domain: "tool-retry-jitter.v1",
            components: [
                Data(invocationID.description.utf8),
                Data(String(completedAttempt).utf8),
            ]
        ).rawValue
        let parsedEntropy = UInt64(digest.prefix(16), radix: 16)
        let entropy: UInt64
        if let parsedEntropy {
            entropy = parsedEntropy
        } else {
            entropy = 0
        }
        let window = max(1, delay / 4)
        return delay - entropy % (window + 1)
    }

    func conservativeUsage(
        for reservation: BudgetReservation,
        completedInvocation: Bool
    ) -> AgentUsage {
        var values = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
            ($0, reservation.maximumUsage.quantities[$0])
        })
        values[.toolInvocations] = completedInvocation ? 1 : 0
        return AgentUsage(quantities: BudgetQuantities(values))
    }

    private func typedToolFailure(
        _ error: Error,
        plan: ExternalOperationPlan,
        attemptNumber: UInt16,
        boundaryStarted: Bool,
        forcePermanent: Bool = false
    ) throws -> AgentFailure {
        let riskyEffects: Set<AgentEffect> = [
            .unknownExternal, .externalWrite, .externalCommunication,
            .destructive, .financial, .codeExecution,
        ]
        if boundaryStarted, !Set(plan.effects).isDisjoint(with: riskyEffects) {
            return try ExecutionFailureFactory.uncertain(
                code: "execution.tool-outcome-uncertain",
                message: "The tool stopped after an external intent whose outcome is unknown."
            )
        }
        if let contract = error as? AgentContractError {
            switch contract {
            case .budgetExceeded, .arithmeticOverflow, .usageExceedsReservation:
                return try AgentFailure(
                    code: "execution.tool-budget-exceeded",
                    classification: .budgetRelated,
                    safeMessage: "The tool exceeded its fixed byte or resource budget.",
                    retryAdvice: .never,
                    externalEffect: .confirmedNone,
                    requiredUserAction: .none,
                    redaction: Self.publicRedaction
                )
            case .authorizationDenied, .authorizationExpired, .authorizationBindingMismatch:
                return try AgentFailure(
                    code: "execution.tool-authorization-failed",
                    classification: .permissionRelated,
                    safeMessage: "The tool authorization was denied, expired, or changed.",
                    retryAdvice: .never,
                    externalEffect: .confirmedNone,
                    requiredUserAction: .approve,
                    redaction: Self.publicRedaction
                )
            default: break
            }
        }
        let transient: Bool
        switch error {
        case ToolV2ContractError.deadlineExceeded,
             ToolV2ContractError.providerThrewBeforeTerminal,
             ToolV2ContractError.missingTerminal:
            transient = !forcePermanent
        default:
            transient = false
        }
        let additional = plan.retryPolicy.maximumAttempts > attemptNumber
            ? plan.retryPolicy.maximumAttempts - attemptNumber : 0
        let retry = transient && additional > 0 && isSafelyReplayable(plan)
            ? try AgentRetryAdvice(
                automaticallyRetryable: true,
                maximumAdditionalAttempts: additional,
                delayMilliseconds: plan.retryPolicy.baseDelayMilliseconds
            )
            : .never
        return try AgentFailure(
            code: transient ? "execution.tool-transient" : "execution.tool-contract-failed",
            classification: transient ? .transient : .permanent,
            safeMessage: transient
                ? "The tool stopped before producing a stable result."
                : "The tool violated its execution contract.",
            retryAdvice: retry,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: Self.publicRedaction
        )
    }

    private func commitToolOutcome(
        _ outcome: AgentToolInvocationOutcome,
        prepared: PreparedExternalOperationRequest,
        reservation: BudgetReservation?,
        actualUsage: AgentUsage,
        invocationID: ToolInvocationID,
        hasMore: Bool,
        deferTerminalDecisions: Bool = false,
        history: ExecutionHistory
    ) async throws {
        let id = ExecutionStableID.event(
            runID: prepared.runID,
            key: "tool-outcome-\(invocationID.description)"
        )
        _ = try await commitEventsSettling(
            runID: prepared.runID,
            identity: .outcome(id)
        ) { currentLedger in
            if let reservation {
                let settled = try currentLedger.settling(
                    reservationID: reservation.id,
                    actualUsage: actualUsage
                )
                return (
                    settled,
                    [.settle(reservationID: reservation.id, actualUsage: actualUsage)]
                )
            } else {
                guard actualUsage == .zero else {
                    throw AgentExecutionError.internalInvariant(
                        "settled tool outcome cannot add unreserved usage"
                    )
                }
                return (currentLedger, [])
            }
        } build: { builder, settled in
            var events = [try builder.append(
                id: id,
                event: .toolOutcomeRecorded(invocationID: invocationID, outcome: outcome),
                cumulativeUsage: settled.consumed,
                redaction: Self.publicRedaction
            )]
            // Parallel batches defer every terminal/no-progress/next-state decision to one
            // deterministic barrier after all fan-out invocations have committed their outcomes.
            if deferTerminalDecisions { return events }
            if builder.state == .pausing {
                if case .uncertain(let value) = outcome {
                    let waiting = try self.status(
                        after: builder,
                        state: .waitingForReconciliation,
                        failure: value,
                        blockingReason: .reconciliation(invocationID: invocationID)
                    )
                    events.append(try builder.append(
                        id: self.nextEventID(builder, key: "tool-pausing-uncertain"),
                        event: .statusChanged(waiting),
                        transitionTo: .waitingForReconciliation,
                        redaction: Self.publicRedaction
                    ))
                }
                return events
            }
            let noProgress = self.isSemanticNoProgress(outcome)
            let precedingNoProgress = history.toolOutcomes.values
                .sorted { $0.0.sequence < $1.0.sequence }
                .reversed()
                .prefix { self.isSemanticNoProgress($0.1) }
                .count
            if noProgress, precedingNoProgress >= 1,
               case .uncertain = outcome
            {
                // Uncertainty always takes precedence over no-progress termination.
            } else if noProgress, precedingNoProgress >= 1 {
                let terminalFailure = try ExecutionFailureFactory.make(
                    reason: .noProgress,
                    code: "execution.no-progress",
                    message: "The agent stopped after two consecutive actions produced no usable result."
                )
                let terminalStatus = try self.status(
                    after: builder,
                    state: .failed,
                    terminalReason: .noProgress,
                    failure: terminalFailure
                )
                let result = try AgentResult(
                    requestID: builder.requestID,
                    executionHandleID: builder.handleID,
                    runID: prepared.runID,
                    status: terminalStatus,
                    answer: nil,
                    usage: settled.consumed
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "tool-no-progress-terminal"),
                    event: .terminal(result),
                    transitionTo: .failed,
                    redaction: Self.publicRedaction
                ))
                return events
            }
            let next: AgentRunState
            let failure: AgentFailure?
            let blocking: AgentBlockingReason?
            switch outcome {
            case .completed:
                next = hasMore ? .executingTools : .waitingForModel
                failure = nil
                blocking = hasMore ? nil : .modelResource
            case .failed:
                next = .synthesizing
                failure = nil
                blocking = nil
            case .uncertain(let value):
                next = .waitingForReconciliation
                failure = value
                blocking = .reconciliation(invocationID: invocationID)
            }
            if next != .executingTools {
                let status = try self.status(
                    after: builder,
                    state: next,
                    failure: failure,
                    blockingReason: blocking
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "tool-next-state"),
                    event: .statusChanged(status),
                    transitionTo: next,
                    redaction: Self.publicRedaction
                ))
            }
            return events
        }
    }

    func isSemanticNoProgress(_ outcome: AgentToolInvocationOutcome) -> Bool {
        switch outcome {
        case .failed, .uncertain:
            return true
        case .completed(let results):
            return !results.contains { result in
                switch result {
                case .text(let text): !text.value.isEmpty
                case .structured, .image, .resourceLink, .artifact: true
                }
            }
        }
    }

}
