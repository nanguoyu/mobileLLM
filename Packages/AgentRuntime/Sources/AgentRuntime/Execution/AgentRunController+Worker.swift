// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

private struct ContextualToolResultCandidate {
    let invocationID: ToolInvocationID
    let descriptorID: String
    let orderSequence: UInt64
    let revisionRecord: AgentEventRecord
    let content: Data
}

private enum DurableToolBatchRecoveryPhase {
    case executePending
    case synthesizeAfterFailure
    case reconcile(invocationID: ToolInvocationID, failure: AgentFailure)
    case continueWithModel
}

extension AgentRunController {
    func drive(runID: AgentRunID) async {
        var rootLease: RootExecutionLease?
        do {
            let (facts, history) = try await loadRun(runID)
            guard !facts.projection.isTerminal,
                  !Self.isDurableWait(history.status.state)
            else { return }
            guard let admissionSequence = facts.submission?.admissionSequence else {
                throw AgentExecutionError.invalidRecoveryBoundary
            }
            rootLease = try await arbiter.acquireRoot(
                runID: runID,
                admissionSequence: admissionSequence
            )
            if let rootLease { try await driveOwned(runID: runID, rootLease: rootLease) }
        } catch is CancellationError {
            await cancelActiveTool(runID: runID)
            try? await finishQuiescence(runID: runID)
        } catch {
            var metadata: [String: String] = [
                "run": runID.description,
                "type": String(reflecting: type(of: error)),
                "errorCode": Self.redactedWorkerErrorCode(error),
            ]
            for (key, value) in Self.redactedWorkerErrorDetails(error) where metadata[key] == nil {
                metadata[key] = value
            }
            await logger.record(
                code: "execution.worker-failed",
                metadata: metadata
            )
            try? await failRun(runID: runID, workerError: error)
        }
        if let rootLease { _ = await arbiter.releaseRoot(rootLease) }
    }

    private func driveOwned(
        runID: AgentRunID,
        rootLease: RootExecutionLease
    ) async throws {
        for _ in 0 ..< 64 {
            try Task.checkCancellation()
            let (facts, history) = try await loadRun(runID)
            switch facts.projection.state {
            case .created:
                try await transition(runID: runID, to: .preparing)
            case .preparing:
                if let toolPhase = try await durableToolBatchRecoveryPhase(history) {
                    switch toolPhase {
                    case .executePending:
                        _ = try await transition(runID: runID, to: .executingTools)
                    case .synthesizeAfterFailure:
                        _ = try await transition(runID: runID, to: .synthesizing)
                    case .reconcile(let invocationID, let failure):
                        _ = try await transition(
                            runID: runID,
                            to: .waitingForReconciliation,
                            failure: failure,
                            blocking: .reconciliation(invocationID: invocationID)
                        )
                    case .continueWithModel:
                        _ = try await compileContext(
                            facts: facts,
                            history: history,
                            toolFree: false,
                            transitionToWaiting: true
                        )
                    }
                } else if modelPurposeToResume(history) == .toolFreeSynthesis {
                    _ = try await transition(runID: runID, to: .synthesizing)
                } else {
                    _ = try await compileContext(
                        facts: facts,
                        history: history,
                        toolFree: false,
                        transitionToWaiting: true
                    )
                }
            case .waitingForModel:
                try await performModelAttempt(
                    facts: facts,
                    history: history,
                    rootLease: rootLease,
                    toolFree: false
                )
            case .synthesizing:
                try await performModelAttempt(
                    facts: facts,
                    history: history,
                    rootLease: rootLease,
                    toolFree: true
                )
            case .validatingAction:
                try await resolveValidatedAction(facts: facts, history: history)
            case .executingTools:
                try await executeNextTool(facts: facts, history: history)
            case .generating:
                // A scheduled worker can observe `generating` only after process recovery. An
                // incomplete decode is not a stable result and is never silently restarted.
                try await recoverInterruptedModel(facts: facts, history: history)
                return
            case .pausing:
                try await finishQuiescence(runID: runID)
                return
            case .waitingForApproval, .waitingForUser, .paused, .waitingForForeground,
                 .waitingForReconciliation, .completed, .failed, .cancelled:
                return
            }
        }
        try await failRun(
            runID: runID,
            reason: .noProgress,
            code: "execution.loop-limit",
            message: "The agent stopped after repeated actions made no progress."
        )
    }

    private static func isDurableWait(_ state: AgentRunState) -> Bool {
        switch state {
        case .waitingForApproval, .waitingForUser, .paused, .waitingForForeground,
             .waitingForReconciliation, .completed, .failed, .cancelled:
            true
        default:
            false
        }
    }

    private static func redactedWorkerErrorCode(_ error: Error) -> String {
        guard let error = error as? AgentExecutionError else { return "non-execution-error" }
        return switch error {
        case .requestRunAlreadyExists: "request-run-already-exists"
        case .submissionCommandConflict: "submission-command-conflict"
        case .executionNotFound: "execution-not-found"
        case .corruptExecutionBinding: "corrupt-execution-binding"
        case .cursorBelongsToAnotherExecution: "cursor-belongs-to-another-execution"
        case .cursorNotFound: "cursor-not-found"
        case .cursorIntegrityMismatch: "cursor-integrity-mismatch"
        case .commandTargetsAnotherRun: "command-targets-another-run"
        case .commandLeaseUnavailable: "command-lease-unavailable"
        case .dependencyUnavailable: "dependency-unavailable"
        case .malformedModelAction: "malformed-model-action"
        case .structuredRepairExhausted: "structured-repair-exhausted"
        case .toolBatchInvalid: "tool-batch-invalid"
        case .toolUnavailable: "tool-unavailable"
        case .approvalUnavailable: "approval-unavailable"
        case .interactionUnavailable: "interaction-unavailable"
        case .reconciliationUnavailable: "reconciliation-unavailable"
        case .budgetUnavailable: "budget-unavailable"
        case .invalidRecoveryBoundary: "invalid-recovery-boundary"
        case .ephemeralObserverLagged: "ephemeral-observer-lagged"
        case .internalInvariant: "internal-invariant"
        }
    }

    private static func redactedWorkerErrorDetails(_ error: Error) -> [String: String] {
        if let executionError = error as? AgentExecutionError,
           case .internalInvariant(let detail) = executionError
        {
            return ["detail": detail]
        }
        // Typed runtime errors carry only stable identities and safe messages — never prompts,
        // tool arguments, or external content — so their case text is redaction-safe diagnostics.
        if let resourceError = error as? ResourceArbiterError {
            return ["detail": String(describing: resourceError)]
        }
        if let modelError = error as? LocalModelAdapterError {
            return ["detail": String(describing: modelError)]
        }
        if let runtimeError = error as? AgentModelRuntimeError {
            return ["detail": String(describing: runtimeError)]
        }
        if error is AgentContractError {
            return ["detail": String(describing: error)]
        }
        return [:]
    }

    /// Derives recovery exclusively from the latest durable action and per-invocation facts.
    /// An intent is not required: a pause can win immediately after batch admission, and later
    /// calls in a serial batch deliberately have no intent until their turn begins.
    private func durableToolBatchRecoveryPhase(
        _ history: ExecutionHistory
    ) async throws -> DurableToolBatchRecoveryPhase? {
        guard let reference = history.actionEvents.last?.2 else { return nil }
        let action = try await loadPayload(AgentAction.self, reference: reference)
        guard case .callTools(let calls) = action else { return nil }

        var latestResolutionSequence: [ToolInvocationID: UInt64] = [:]
        for (record, failure) in history.diagnostics {
            let isSucceeded = failure.code == "execution.reconciled-succeeded"
            let isFailed = failure.code == "execution.reconciled-failed"
            guard isSucceeded || isFailed,
                  let rawInvocationID = failure.details["invocationID"],
                  let invocationID = ToolInvocationID(rawInvocationID)
            else { continue }
            if let existing = latestResolutionSequence[invocationID],
               existing >= record.sequence
            {
                continue
            }
            latestResolutionSequence[invocationID] = record.sequence
        }
        var deniedInvocations: Set<ToolInvocationID> = []
        for approval in history.approvals.values {
            guard let receipt = approval.receipt,
                  receipt.decision != .approved,
                  let invocationID = approval.request.prepared.invocationID
            else { continue }
            deniedInvocations.insert(invocationID)
        }

        var requiresSynthesis = false
        var hasPendingCall = false
        for call in calls {
            if let recordedOutcome = history.toolOutcomes[call.invocationID] {
                switch recordedOutcome.1 {
                case .uncertain(let failure):
                    let resolutionSequence = latestResolutionSequence[call.invocationID]
                    if let resolutionSequence,
                       resolutionSequence > recordedOutcome.0.sequence
                    {
                        requiresSynthesis = true
                    } else {
                        return .reconcile(invocationID: call.invocationID, failure: failure)
                    }
                case .failed:
                    requiresSynthesis = true
                case .completed:
                    break
                }
            } else if deniedInvocations.contains(call.invocationID)
                || latestResolutionSequence[call.invocationID] != nil
            {
                // A denial or explicit reconciliation is a terminal decision for this serial
                // batch even when an older journal contains no synthetic tool outcome.
                requiresSynthesis = true
            } else {
                hasPendingCall = true
            }
        }
        if requiresSynthesis { return .synthesizeAfterFailure }
        if hasPendingCall { return .executePending }
        return .continueWithModel
    }

    /// Recovers a model phase from durable context metadata. An outstanding manifest is the next
    /// attempt; an interrupted last attempt preserves its original purpose across foreground loss.
    private func modelPurposeToResume(
        _ history: ExecutionHistory
    ) -> ExecutionModelAttemptPurpose? {
        if history.manifestEvents.count > history.modelOutcomes.count {
            return history.manifestEvents.last?.3
        }
        guard let lastOutcome = history.modelOutcomes.last?.1,
              case .interrupted = lastOutcome,
              history.manifestEvents.count == history.modelOutcomes.count
        else { return nil }
        return history.manifestEvents.last?.3
    }

    @discardableResult
    func transition(
        runID: AgentRunID,
        to state: AgentRunState,
        failure: AgentFailure? = nil,
        blocking: AgentBlockingReason? = nil
    ) async throws -> CommittedEventBatch {
        let (facts, _) = try await loadRun(runID)
        let id = ExecutionStableID.event(
            runID: runID,
            key: "transition-\(state.rawValue)-\(facts.projection.eventCount + 1)"
        )
        return try await commitEvents(runID: runID, identity: .outcome(id)) { builder in
            let value = try self.status(
                after: builder,
                state: state,
                failure: failure,
                blockingReason: blocking
            )
            return [try builder.append(
                id: id,
                event: .statusChanged(value),
                transitionTo: state,
                redaction: Self.publicRedaction
            )]
        }
    }

    private func frozenInputs(_ facts: RuntimeRunFacts) async throws -> FrozenAgentRunInputs {
        guard let submission = facts.submission else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        return try await loadPayload(FrozenAgentRunInputs.self, reference: submission.inputSnapshot)
    }

    private func compileContext(
        facts: RuntimeRunFacts,
        history: ExecutionHistory,
        toolFree: Bool,
        transitionToWaiting: Bool
    ) async throws -> CompiledContext {
        let frozen = try await frozenInputs(facts)
        let attempt = UInt64(history.modelOutcomes.count + 1)
        let stepID = ExecutionStableID.step(runID: facts.projection.runID, attempt: attempt)
        let selected = try frozen.selectedTools(
            latestUserRequest: frozen.currentUser.frozen.content
        )
        let descriptors = toolFree ? [] : selected.descriptors
        await logger.record(
            code: "execution.tool-selection",
            metadata: [
                "advertised": descriptors
                    .map { $0.id.logicalID.description }.sorted().joined(separator: ","),
                "catalog": frozen.toolCatalog.descriptors
                    .map { $0.id.logicalID.description }.sorted().joined(separator: ","),
                "policy.master": String(frozen.toolPolicy.masterEnabled),
                "policy.allowed": frozen.toolPolicy.allowedToolIDs
                    .map(\.description).sorted().joined(separator: ","),
                "policy.pinned": frozen.toolPolicy.pinnedToolIDs
                    .map(\.description).sorted().joined(separator: ","),
                "explicit": frozen.explicitlyRequestedToolIDs
                    .map(\.description).sorted().joined(separator: ","),
                "unavailable": selected.unavailable
                    .map { "\($0.logicalID.description):\($0.reason.rawValue)" }
                    .joined(separator: ","),
                "toolFree": String(toolFree),
            ]
        )
        var stateFields: [String: JSONValue] = [
            "state": .string(facts.projection.state.rawValue),
            "stateVersion": .unsignedInteger(facts.projection.stateVersion),
            "modelAttempt": .unsignedInteger(attempt),
            "structuredRepair": .bool(history.repairCount > 0),
            "toolFreeSynthesis": .bool(toolFree),
        ]
        if history.repairCount > 0 {
            let lastRepair = history.diagnostics.last { $0.1.code == "execution.structured-repair" }
                ?? history.diagnostics.last { $0.1.code == "execution.repeated-tool-call" }
            stateFields["repairInstruction"] = .string(
                lastRepair?.1.code == "execution.repeated-tool-call"
                    ? "Your last tool call already executed in this turn. Do NOT call any tool again — "
                        + "answer the user's request directly with text only."
                    : "Return exactly one valid action matching the advertised response contract. "
                        + "Do not include prose outside that action."
            )
        }
        let stateJSON = try CanonicalJSON(.object(stateFields))
        let runState = try RunStateContextSource(
            revision: "event-\(facts.projection.eventCount)",
            canonicalState: stateJSON
        )
        var conversation = frozen.conversation
        for (requestID, interaction) in history.interactions.sorted(by: {
            $0.key.description < $1.key.description
        }) {
            guard let reference = interaction.response else { continue }
            let value = try await loadPayload(JSONValue.self, reference: reference)
            let encoded = try ExecutionEncoding.encode(value)
            conversation.append(try ConversationTurnContextSource(
                messageID: ExecutionStableID.interactionMessage(
                    runID: facts.projection.runID,
                    requestID: requestID
                ),
                revision: reference.digest.rawValue,
                role: .user,
                content: String(decoding: encoded, as: UTF8.self)
            ))
        }
        var resolutionDiagnostics: [ToolInvocationID: (AgentEventRecord, AgentFailure)] = [:]
        for (record, failure) in history.diagnostics {
            guard failure.code == "execution.reconciled-succeeded"
                    || failure.code == "execution.reconciled-failed",
                  let rawInvocationID = failure.details["invocationID"],
                  let invocationID = ToolInvocationID(rawInvocationID)
            else { continue }
            if let existing = resolutionDiagnostics[invocationID],
               existing.0.sequence >= record.sequence
            {
                continue
            }
            resolutionDiagnostics[invocationID] = (record, failure)
        }
        var contextualResults = try history.toolOutcomes.map { invocationID, pair in
            guard let descriptorID = history.toolIntents[invocationID]?.1.plan.descriptorID else {
                throw AgentExecutionError.invalidRecoveryBoundary
            }
            if case .uncertain = pair.1, let resolution = resolutionDiagnostics[invocationID] {
                return ContextualToolResultCandidate(
                    invocationID: invocationID,
                    descriptorID: descriptorID,
                    orderSequence: pair.0.sequence,
                    revisionRecord: resolution.0,
                    content: try Self.safeToolFailureContext(
                        resolution.1,
                        status: resolution.1.code
                    )
                )
            }
            let content: Data = switch pair.1 {
            case .completed:
                try ExecutionEncoding.encode(pair.1)
            case .failed(let failure):
                try Self.safeToolFailureContext(failure, status: "failed")
            case .uncertain(let failure):
                try Self.safeToolFailureContext(failure, status: "uncertain")
            }
            return ContextualToolResultCandidate(
                invocationID: invocationID,
                descriptorID: descriptorID,
                orderSequence: pair.0.sequence,
                revisionRecord: pair.0,
                content: content
            )
        }
        for (invocationID, resolution) in resolutionDiagnostics
            where history.toolOutcomes[invocationID] == nil
        {
            guard let intent = history.toolIntents[invocationID],
                  let descriptorID = intent.1.plan.descriptorID,
                  let interruption = history.diagnostics.first(where: {
                      $0.1.code == "execution.tool-attempt-interrupted-uncertain"
                          && $0.1.details["invocationID"] == invocationID.description
                  })
            else { throw AgentExecutionError.invalidRecoveryBoundary }
            contextualResults.append(ContextualToolResultCandidate(
                invocationID: invocationID,
                descriptorID: descriptorID,
                orderSequence: interruption.0.sequence,
                revisionRecord: resolution.0,
                content: try Self.safeToolFailureContext(
                    resolution.1,
                    status: resolution.1.code
                )
            ))
        }
        for approval in history.approvals.values {
            guard let receipt = approval.receipt,
                  receipt.decision != .approved,
                  let invocationID = receipt.invocationID,
                  history.toolOutcomes[invocationID] == nil,
                  let receiptRecord = approval.receiptRecord,
                  let denial = history.diagnostics.first(where: {
                      $0.0.sequence > receiptRecord.sequence
                          && $0.1.details["invocationID"] == invocationID.description
                          && ($0.1.code == "execution.tool-approval-denied"
                              || $0.1.code == "execution.tool-approval-cancelled")
                  }),
                  let descriptorID = approval.request.prepared.plan.descriptorID
            else { continue }
            contextualResults.append(ContextualToolResultCandidate(
                invocationID: invocationID,
                descriptorID: descriptorID,
                orderSequence: approval.requestRecord.sequence,
                revisionRecord: denial.0,
                content: try Self.safeToolFailureContext(denial.1, status: "denied")
            ))
        }
        contextualResults.sort {
            if $0.orderSequence != $1.orderSequence { return $0.orderSequence < $1.orderSequence }
            return $0.invocationID.description < $1.invocationID.description
        }
        let toolResults = try contextualResults.map { entry in
            guard let descriptor = frozen.toolCatalog.descriptors.first(where: {
                $0.id.description == entry.descriptorID
            }) else { throw AgentExecutionError.invalidRecoveryBoundary }
            return try UntrustedToolResultContextSource(
                invocationID: entry.invocationID,
                descriptorID: descriptor.id,
                resultRevision: entry.revisionRecord.recordDigest.rawValue,
                resultContent: String(decoding: entry.content, as: UTF8.self),
                resultDigest: StableDigest.sha256(entry.content)
            )
        }
        let snapshot = try FrozenContextSnapshot(
            runID: facts.projection.runID,
            requestID: facts.projection.requestID,
            stepID: stepID,
            baseSystem: frozen.baseSystem,
            skills: frozen.skills,
            memories: frozen.memories,
            conversation: conversation,
            currentUser: frozen.currentUser,
            runState: runState,
            artifactExcerpts: frozen.artifactExcerpts,
            untrustedToolResults: toolResults,
            advertisedTools: descriptors,
            selectorID: selected.snapshot.selectorID,
            selectorPolicyVersion: selected.snapshot.policyVersion,
            contextPolicyVersion: frozen.contextPolicyVersion,
            approvalPolicyVersion: frozen.approvalPolicyVersion
        )
        let compiled = try ContextCompiler().compile(snapshot, budget: frozen.contextBudget)
        let data = try ExecutionEncoding.encode(compiled)
        let artifact = try await payloadStore.commit(
            data: data,
            mimeType: "application/json",
            semanticType: (toolFree
                ? ExecutionModelAttemptPurpose.toolFreeSynthesis
                : .standard).semanticType,
            runID: facts.projection.runID,
            stepID: stepID,
            invocationID: nil,
            owner: .run(facts.projection.runID),
            sensitivity: .sensitive
        )
        let reference = try stableReference(artifact, data: data)
        let eventID = ExecutionStableID.event(
            runID: facts.projection.runID,
            key: "compiled-context-\(stepID.description)"
        )
        _ = try await commitEvents(
            runID: facts.projection.runID,
            identity: .outcome(eventID)
        ) { builder in
            var events = [try builder.append(
                id: eventID,
                event: .artifactCommitted(artifact),
                redaction: Self.publicRedaction
            )]
            events.append(try builder.append(
                id: self.nextEventID(builder, key: "compiled-manifest"),
                event: .compiledManifestCommitted(stepID: stepID, reference: reference),
                redaction: Self.publicRedaction
            ))
            if transitionToWaiting {
                let waiting = try self.status(
                    after: builder,
                    state: .waitingForModel,
                    blockingReason: .modelResource
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "waiting-model"),
                    event: .statusChanged(waiting),
                    transitionTo: .waitingForModel,
                    redaction: Self.publicRedaction
                ))
            }
            return events
        }
        return compiled
    }

    private static func safeToolFailureContext(
        _ failure: AgentFailure,
        status: String
    ) throws -> Data {
        try CanonicalJSON(.object([
            "type": .string("tool-resolution"),
            "status": .string(status),
            "code": .string(failure.code),
            "classification": .string(failure.classification.rawValue),
            "externalEffect": .string(failure.externalEffect.rawValue),
            "safeMessage": .string(failure.safeMessage),
        ])).data
    }

    private func compiledContext(
        facts: RuntimeRunFacts,
        history: ExecutionHistory,
        toolFree: Bool
    ) async throws -> CompiledContext {
        if history.manifestEvents.count > history.modelOutcomes.count,
           let manifest = history.manifestEvents.last
        {
            let requested: ExecutionModelAttemptPurpose = toolFree ? .toolFreeSynthesis : .standard
            guard manifest.3 == requested else {
                throw AgentExecutionError.invalidRecoveryBoundary
            }
            return try await loadPayload(CompiledContext.self, reference: manifest.2)
        }
        return try await compileContext(
            facts: facts,
            history: history,
            toolFree: toolFree,
            transitionToWaiting: false
        )
    }

    private func performModelAttempt(
        facts: RuntimeRunFacts,
        history: ExecutionHistory,
        rootLease: RootExecutionLease,
        toolFree: Bool
    ) async throws {
        let frozen = try await frozenInputs(facts)
        let compiled = try await compiledContext(facts: facts, history: history, toolFree: toolFree)
        let selected = try frozen.selectedTools(
            latestUserRequest: frozen.currentUser.frozen.content
        )
        let includedIDs = Set(compiled.advertisedTools.map(\.id))
        let selectorSnapshot = try AgentToolSelectionSnapshot(
            selectorID: selected.snapshot.selectorID,
            policyVersion: selected.snapshot.policyVersion,
            inputDigest: selected.snapshot.inputDigest,
            decisions: selected.snapshot.decisions.filter { includedIDs.contains($0.descriptorID) }
        )
        let generation = try generationParameters(
            frozen.generationParameters,
            repair: history.repairCount > 0
        )
        let modelRequest = try AgentModelRequest(
            requestID: facts.projection.requestID,
            runID: facts.projection.runID,
            stepID: compiled.manifest.stepID,
            selection: frozen.modelSelection,
            compiledManifestDigest: compiled.manifest.manifestDigest,
            messages: compiled.messages,
            advertisedTools: compiled.advertisedTools,
            toolSelectionSnapshot: selectorSnapshot,
            generationParameters: generation,
            outputRequirement: facts.submission!.request.payload.outputRequirement
        )
        let grant = try StepCapabilityGrant(
            runCeiling: facts.submission!.request.payload.capabilityCeiling,
            authority: facts.submission!.request.payload.capabilityCeiling.authority
        )
        let authPayload = try sanitizer.sanitize(
            modelRequest.authorizationPayload(),
            referencedSecretIDs: [],
            redaction: try RedactionMetadata(classification: .sensitive, policyVersion: 1)
        )
        let prepContext = try ModelPreparationContext(
            conversationID: facts.submission!.request.payload.conversationID,
            modelPolicy: facts.submission!.request.payload.modelPolicy,
            capabilityGrant: grant,
            authorizationPayload: authPayload,
            maximumRequestBytes: UInt64(max(4, authPayload.data.count)),
            maximumResponseBytes: max(1, facts.submission!.request.payload.budget.limits[.persistedOutputBytes]),
            timeoutMilliseconds: max(1, min(
                60_000,
                facts.submission!.request.payload.budget.limits[.activeMilliseconds]
            ))
        )
        let provider = try modelProviders.provider(for: frozen.modelSelection)
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: modelRequest,
            context: prepContext
        )
        let now = try await clock.now()
        let authority = try TrustedRunAuthority(
            runID: facts.projection.runID,
            ceiling: facts.submission!.request.payload.capabilityCeiling,
            policyRevision: UInt64(policyEngine.policyVersion)
        )
        let approvalID = ApprovalID(rawValue: ExecutionStableID.event(
            runID: facts.projection.runID,
            key: "model-authorization-\(modelRequest.stepID.description)"
        ).rawValue)
        let generatingVersion = facts.projection.stateVersion.addingReportingOverflow(1)
        guard !generatingVersion.overflow else {
            throw AgentExecutionError.internalInvariant("state version overflow")
        }
        let attemptLedger = ScopedExternalOperationAttemptLedger(
            repository: repository,
            scope: try RuntimeBoundaryClaimScope(
                runID: facts.projection.runID,
                expectedState: .generating,
                expectedStateVersion: generatingVersion.partialValue
            )
        )
        let authorized = try await AgentModelAuthorizationBinder().authorizeLocal(
            prepared,
            approvalID: approvalID,
            trustedRunAuthority: authority,
            at: now,
            policyEngine: policyEngine,
            clock: clock,
            attemptLedger: attemptLedger
        )
        let reservation = try modelReservation(
            request: modelRequest,
            budget: facts.submission!.request.payload.budget,
            structuredRepair: history.repairCount > 0
        )
        guard let durableLedger = facts.budgetLedger else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        // Hard-budget admission precedes residency. This is a read-only exact preflight; the
        // reservation itself remains atomic with the durable `generating` boundary below, so a
        // residency failure cannot strand a reservation.
        _ = try durableLedger.reserving(reservation)
        let decodeLease = try await arbiter.acquireDecode(
            selection: frozen.modelSelection,
            rootLease: rootLease
        )
        let startID = ExecutionStableID.event(
            runID: facts.projection.runID,
            key: "model-start-\(modelRequest.stepID.description)"
        )
        do {
            _ = try await commitEvents(
                runID: facts.projection.runID,
                identity: .outcome(startID),
                budgetOperations: [.reserve(reservation)]
            ) { builder in
                let generating = try self.status(after: builder, state: .generating)
                return [try builder.append(
                    id: startID,
                    event: .statusChanged(generating),
                    transitionTo: .generating,
                    redaction: Self.publicRedaction
                )]
            }
        } catch {
            _ = await arbiter.releaseDecode(decodeLease)
            throw error
        }
        let execution: AgentModelExecutionResult
        do {
            execution = try await AgentModelExecutor().execute(
                provider: provider,
                authorized: authorized,
                // Every model pass owns a new step and a new prepared external operation. This is
                // therefore attempt one for that prepared request; the run-level pass ordinal is
                // already encoded by `stepID` and budget usage.
                attemptNumber: 1,
                eventSink: ControllerModelEventSink(
                    controller: self,
                    executionHandleID: facts.projection.executionHandleID,
                    runID: facts.projection.runID,
                    stepID: modelRequest.stepID
                )
            )
        } catch let error as AgentModelRuntimeError {
            _ = await arbiter.cancelDrainAndReleaseDecode(decodeLease)
            if case .providerContractViolation = error {
                try await commitMalformedModelAttempt(
                    runID: facts.projection.runID,
                    stepID: modelRequest.stepID,
                    reservation: reservation,
                    repairAlreadyAttempted: history.repairCount > 0
                )
                return
            }
            throw error
        } catch {
            _ = await arbiter.cancelDrainAndReleaseDecode(decodeLease)
            throw error
        }
        if Task.isCancelled || execution.interruption != nil {
            _ = await arbiter.cancelDrainAndReleaseDecode(decodeLease)
        } else {
            _ = await arbiter.releaseDecode(decodeLease)
        }
        if case .failed(let failure) = execution.outcome,
           Self.isRepairableStructuredModelFailure(failure)
        {
            try await commitMalformedModelAttempt(
                runID: facts.projection.runID,
                stepID: modelRequest.stepID,
                reservation: reservation,
                repairAlreadyAttempted: history.repairCount > 0
            )
            return
        }
        try await commitModelOutcome(
            runID: facts.projection.runID,
            stepID: modelRequest.stepID,
            reservation: reservation,
            execution: execution
        )
    }

    private static func isRepairableStructuredModelFailure(_ failure: AgentFailure) -> Bool {
        failure.externalEffect == .confirmedNone
            && failure.requiredUserAction == .none
            && failure.retryAdvice == .never
            && (failure.code == "model.local.malformed-action"
                || failure.code == "model.local.structured-output-invalid")
    }

    private func generationParameters(
        _ original: AgentModelGenerationParameters,
        repair: Bool
    ) throws -> AgentModelGenerationParameters {
        guard repair else { return original }
        return try AgentModelGenerationParameters(
            maximumOutputTokens: original.maximumOutputTokens,
            maximumContextTokens: original.maximumContextTokens,
            temperature: 0,
            topP: 1,
            topK: original.topK,
            repetitionPenalty: original.repetitionPenalty,
            thinkingMode: .disabled,
            seed: original.seed
        )
    }

    private func modelReservation(
        request: AgentModelRequest,
        budget: AgentBudget,
        structuredRepair: Bool
    ) throws -> BudgetReservation {
        try BudgetReservation(
            id: ExecutionStableID.reservation(
                runID: request.runID,
                kind: "model",
                stableID: request.stepID.description
            ),
            maximumUsage: AgentUsage(quantities: BudgetQuantities([
                .modelAttempts: 1,
                .structuredRepairs: structuredRepair ? 1 : 0,
                .inputTokens: request.generationParameters.maximumContextTokens,
                .outputTokens: request.generationParameters.maximumOutputTokens,
                .contextTokensPerAttempt: request.generationParameters.maximumContextTokens,
                .activeMilliseconds: min(60_000, budget.limits[.activeMilliseconds]),
                .peakMemoryBytes: budget.limits[.peakMemoryBytes],
            ])),
            reason: "model-attempt"
        )
    }

    private func usage(
        _ value: AgentModelUsage?,
        structuredRepair: Bool
    ) -> AgentUsage {
        guard let value else {
            return AgentUsage(quantities: BudgetQuantities([
                .modelAttempts: 1,
                .structuredRepairs: structuredRepair ? 1 : 0,
            ]))
        }
        return AgentUsage(quantities: BudgetQuantities([
            .modelAttempts: 1,
            .structuredRepairs: structuredRepair ? 1 : 0,
            .inputTokens: value.inputTokens,
            .outputTokens: value.outputTokens,
            .contextTokensPerAttempt: value.inputTokens,
            .activeMilliseconds: value.activeMilliseconds,
            .peakMemoryBytes: value.peakMemoryBytes,
        ]))
    }

    private func commitModelOutcome(
        runID: AgentRunID,
        stepID: AgentStepID,
        reservation: BudgetReservation,
        execution: AgentModelExecutionResult
    ) async throws {
        let (facts, history) = try await loadRun(runID)
        let reported: AgentModelUsage? = switch execution.outcome {
        case .completed(let completion): completion.usage
        case .interrupted(let value): value
        case .failed: nil
        }
        let actual = usage(
            reported,
            structuredRepair: reservation.maximumUsage.quantities[.structuredRepairs] > 0
        )
        let ledger: BudgetLedgerSnapshot
        do {
            ledger = try facts.budgetLedger!.settling(
                reservationID: reservation.id,
                actualUsage: actual
            )
        } catch {
            // The contract error identifies only the reservation; record which dimensions actually
            // exceeded their reserved ceilings so device diagnostics show the real budget story.
            let over = BudgetDimension.allCases.compactMap { dimension -> String? in
                guard actual.quantities[dimension] > reservation.maximumUsage.quantities[dimension]
                else { return nil }
                return "\(dimension.rawValue):\(reservation.maximumUsage.quantities[dimension])<\(actual.quantities[dimension])"
            }
            await logger.record(
                code: "execution.model-settle-failed",
                metadata: ["over": over.joined(separator: ",")]
            )
            throw error
        }
        let outcomeID = ExecutionStableID.event(
            runID: runID,
            key: "model-outcome-\(stepID.description)"
        )
        if facts.projection.state == .pausing {
            _ = try await commitEvents(
                runID: runID,
                identity: .outcome(outcomeID),
                budgetOperations: [.settle(reservationID: reservation.id, actualUsage: actual)]
            ) { builder in
                [try builder.append(
                    id: outcomeID,
                    event: .modelAttemptOutcome(execution.outcome),
                    cumulativeUsage: ledger.consumed,
                    redaction: Self.publicRedaction
                )]
            }
            try await finishQuiescence(runID: runID)
            return
        }
        switch execution.outcome {
        case .completed(let completion):
            let actionData = try ExecutionEncoding.encode(completion.action)
            let artifact = try await payloadStore.commit(
                data: actionData,
                mimeType: "application/json",
                semanticType: "agent-action.v1",
                runID: runID,
                stepID: stepID,
                invocationID: nil,
                owner: .run(runID),
                sensitivity: .sensitive
            )
            let reference = try stableReference(artifact, data: actionData)
            _ = try await commitEvents(
                runID: runID,
                identity: .outcome(outcomeID),
                budgetOperations: [.settle(reservationID: reservation.id, actualUsage: actual)]
            ) { builder in
                var events = [try builder.append(
                    id: outcomeID,
                    event: .modelAttemptOutcome(execution.outcome),
                    cumulativeUsage: ledger.consumed,
                    redaction: Self.publicRedaction
                )]
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "action-artifact"),
                    event: .artifactCommitted(artifact),
                    redaction: Self.publicRedaction
                ))
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "validated-action"),
                    event: .validatedActionCommitted(stepID: stepID, reference: reference),
                    redaction: Self.publicRedaction
                ))
                let validating = try self.status(after: builder, state: .validatingAction)
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "validating-action"),
                    event: .statusChanged(validating),
                    transitionTo: .validatingAction,
                    redaction: Self.publicRedaction
                ))
                return events
            }
        case .interrupted:
            _ = try await commitEvents(
                runID: runID,
                identity: .outcome(outcomeID),
                budgetOperations: [.settle(reservationID: reservation.id, actualUsage: actual)]
            ) { builder in
                var events = [try builder.append(
                    id: outcomeID,
                    event: .modelAttemptOutcome(execution.outcome),
                    cumulativeUsage: ledger.consumed,
                    redaction: Self.publicRedaction
                )]
                let waiting = try self.status(
                    after: builder,
                    state: .waitingForForeground,
                    blockingReason: .foreground
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "model-interrupted"),
                    event: .statusChanged(waiting),
                    transitionTo: .waitingForForeground,
                    redaction: Self.publicRedaction
                ))
                return events
            }
        case .failed(let failure):
            let lastResolvedActionSequence = history.actionEvents.last?.0.sequence ?? 0
            let retriesInCurrentChain = history.diagnostics.filter {
                $0.0.sequence > lastResolvedActionSequence
                    && $0.1.code == "execution.model-retry"
            }.count
            let mayRetry = failure.retryAdvice.automaticallyRetryable
                && retriesInCurrentChain
                    < Int(clamping: failure.retryAdvice.maximumAdditionalAttempts)
                && ledger.consumed.quantities[.modelAttempts]
                    < ledger.budget.limits[.modelAttempts]
            let retryDelay = mayRetry ? modelRetryDelay(
                base: failure.retryAdvice.delayMilliseconds,
                retryOrdinal: UInt16(clamping: retriesInCurrentChain + 1)
            ) : nil
            _ = try await commitEvents(
                runID: runID,
                identity: .outcome(outcomeID),
                budgetOperations: [.settle(reservationID: reservation.id, actualUsage: actual)]
            ) { builder in
                var events = [try builder.append(
                    id: outcomeID,
                    event: .modelAttemptOutcome(execution.outcome),
                    cumulativeUsage: ledger.consumed,
                    redaction: Self.publicRedaction
                )]
                if failure.classification == .cancelled {
                    let waiting = try self.status(
                        after: builder,
                        state: .waitingForForeground,
                        blockingReason: .foreground
                    )
                    events.append(try builder.append(
                        id: self.nextEventID(builder, key: "model-provider-cancelled"),
                        event: .statusChanged(waiting),
                        transitionTo: .waitingForForeground,
                        redaction: Self.publicRedaction
                    ))
                } else if mayRetry {
                    events.append(try builder.append(
                        id: self.nextEventID(builder, key: "model-retry-diagnostic"),
                        event: .diagnostic(try self.commandFailure(
                            code: "execution.model-retry",
                            message: "The local model attempt will be retried.",
                            classification: .transient
                        )),
                        redaction: Self.publicRedaction
                    ))
                    let waiting = try self.status(
                        after: builder,
                        state: .waitingForModel,
                        blockingReason: .modelResource
                    )
                    events.append(try builder.append(
                        id: self.nextEventID(builder, key: "model-retry"),
                        event: .statusChanged(waiting),
                        transitionTo: .waitingForModel,
                        redaction: Self.publicRedaction
                    ))
                } else {
                    let terminalReason = self.terminalReason(for: failure)
                    let terminalStatus = try self.status(
                        after: builder,
                        state: .failed,
                        terminalReason: terminalReason,
                        failure: failure
                    )
                    let result = try AgentResult(
                        requestID: builder.requestID,
                        executionHandleID: builder.handleID,
                        runID: runID,
                        status: terminalStatus,
                        answer: nil,
                        usage: ledger.consumed
                    )
                    events.append(try builder.append(
                        id: self.nextEventID(builder, key: "model-failed-terminal"),
                        event: .terminal(result),
                        transitionTo: .failed,
                        redaction: Self.publicRedaction
                    ))
                }
                return events
            }
            if let retryDelay, retryDelay > 0 {
                try await clock.sleep(milliseconds: retryDelay)
            }
        }
    }

    private func modelRetryDelay(base: UInt64, retryOrdinal: UInt16) -> UInt64 {
        guard base > 0 else { return 0 }
        var delay = min(base, 30_000)
        if retryOrdinal > 1 {
            for _ in 1 ..< retryOrdinal {
                // `delay` is clamped before every multiplication, so doubling cannot overflow.
                delay = min(delay * 2, 30_000)
                if delay == 30_000 { break }
            }
        }
        return delay
    }

    private func terminalReason(for failure: AgentFailure) -> AgentTerminalReason {
        switch failure.classification {
        case .budgetRelated: .budgetExceeded
        case .permissionRelated: .permissionDenied
        case .incompatible: .modelUnavailable
        case .potentiallySideEffecting: .externalResultUncertain
        case .cancelled, .permanent, .transient: .internalFailure
        }
    }

    private func commitMalformedModelAttempt(
        runID: AgentRunID,
        stepID: AgentStepID,
        reservation: BudgetReservation,
        repairAlreadyAttempted: Bool
    ) async throws {
        let facts = try await repository.loadRunFacts(for: runID)
        guard let facts, let currentLedger = facts.budgetLedger else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let actual = AgentUsage(quantities: BudgetQuantities([
            .modelAttempts: 1,
            .structuredRepairs: reservation.maximumUsage.quantities[.structuredRepairs] > 0 ? 1 : 0,
        ]))
        let settled = try currentLedger.settling(
            reservationID: reservation.id,
            actualUsage: actual
        )
        let malformed = try AgentFailure(
            code: "execution.malformed-model-action",
            classification: .permanent,
            safeMessage: "The model returned an invalid structured action.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: Self.publicRedaction
        )
        let outcomeID = ExecutionStableID.event(
            runID: runID,
            key: "malformed-model-outcome-\(stepID.description)"
        )
        _ = try await commitEvents(
            runID: runID,
            identity: .outcome(outcomeID),
            budgetOperations: [.settle(reservationID: reservation.id, actualUsage: actual)]
        ) { builder in
            var events = [try builder.append(
                id: outcomeID,
                event: .modelAttemptOutcome(.failed(malformed)),
                cumulativeUsage: settled.consumed,
                redaction: Self.publicRedaction
            )]
            if repairAlreadyAttempted {
                let exhausted = try ExecutionFailureFactory.make(
                    reason: .internalFailure,
                    code: "execution.structured-repair-exhausted",
                    message: "The model could not produce a valid structured action after one repair attempt."
                )
                let terminalStatus = try self.status(
                    after: builder,
                    state: .failed,
                    terminalReason: .internalFailure,
                    failure: exhausted
                )
                let result = try AgentResult(
                    requestID: builder.requestID,
                    executionHandleID: builder.handleID,
                    runID: runID,
                    status: terminalStatus,
                    answer: nil,
                    usage: settled.consumed
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "structured-repair-exhausted"),
                    event: .terminal(result),
                    transitionTo: .failed,
                    redaction: Self.publicRedaction
                ))
            } else {
                let repair = try AgentFailure(
                    code: "execution.structured-repair",
                    classification: .transient,
                    safeMessage: "Retrying once with constrained structured output.",
                    retryAdvice: .never,
                    externalEffect: .confirmedNone,
                    requiredUserAction: .none,
                    redaction: Self.publicRedaction
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "structured-repair-diagnostic"),
                    event: .diagnostic(repair),
                    redaction: Self.publicRedaction
                ))
                let waiting = try self.status(
                    after: builder,
                    state: .waitingForModel,
                    blockingReason: .modelResource
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "structured-repair-waiting"),
                    event: .statusChanged(waiting),
                    transitionTo: .waitingForModel,
                    redaction: Self.publicRedaction
                ))
            }
            return events
        }
    }

    private func resolveValidatedAction(
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws {
        guard let reference = history.actionEvents.last?.2 else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let action = try await loadPayload(AgentAction.self, reference: reference)
        switch action {
        case .finalAnswer(let answer):
            try await finalize(runID: facts.projection.runID, answer: answer)
        case .requestUserInput(let proposed):
            let request = try UserInputRequest(
                id: proposed.id,
                runID: facts.projection.runID,
                prompt: proposed.prompt,
                responseSchema: proposed.responseSchema,
                creationStateVersion: facts.projection.stateVersion + 1
            )
            let id = ExecutionStableID.event(
                runID: facts.projection.runID,
                key: "interaction-\(request.id.description)"
            )
            _ = try await commitEvents(runID: facts.projection.runID, identity: .outcome(id)) {
                builder in
                var events = [try builder.append(
                    id: id,
                    event: .userInputRequested(request),
                    redaction: Self.publicRedaction
                )]
                let waiting = try self.status(
                    after: builder,
                    state: .waitingForUser,
                    blockingReason: .userInput(requestID: request.id)
                )
                events.append(try builder.append(
                    id: self.nextEventID(builder, key: "waiting-user"),
                    event: .statusChanged(waiting),
                    transitionTo: .waitingForUser,
                    redaction: Self.publicRedaction
                ))
                return events
            }
        case .callTools(let calls):
            try await admitToolBatch(
                facts: facts,
                history: history,
                proposedCalls: calls
            )
        }
    }

    private func finalize(runID: AgentRunID, answer: AgentAnswer) async throws {
        let (facts, _) = try await loadRun(runID)
        let data = try ExecutionEncoding.encode(answer)
        let messageID = ExecutionStableID.message(runID: runID, role: .assistant)
        let artifact = try await payloadStore.commit(
            data: data,
            mimeType: "application/json",
            semanticType: "agent-final-answer.v1",
            runID: runID,
            stepID: nil,
            invocationID: nil,
            owner: .message(messageID),
            sensitivity: .personalData
        )
        let digest = StableDigest.sha256(data)
        guard artifact.contentDigest == digest,
              let conversationID = facts.conversationID
        else { throw AgentExecutionError.invalidRecoveryBoundary }
        var builder = ExecutionEventBuilder(projection: facts.projection)
        var events = [try builder.append(
            id: nextEventID(builder, key: "final-answer-artifact"),
            event: .artifactCommitted(artifact),
            redaction: Self.publicRedaction
        )]
        let terminalStatus = try status(
            after: builder,
            state: .completed,
            terminalReason: .completed
        )
        let result = try AgentResult(
            requestID: builder.requestID,
            executionHandleID: builder.handleID,
            runID: runID,
            status: terminalStatus,
            answer: answer,
            usage: builder.usage
        )
        let terminalID = nextEventID(builder, key: "completed")
        events.append(try builder.append(
            id: terminalID,
            event: .terminal(result),
            transitionTo: .completed,
            redaction: Self.publicRedaction
        ))
        let append = try RunJournalAppendRequest(
            mutationIdentity: .outcome(terminalID),
            runID: runID,
            expectedRunStateVersion: facts.projection.stateVersion,
            events: events
        )
        let message = JournalMessageReference(
            messageID: messageID,
            conversationID: conversationID,
            runID: runID,
            role: .assistant,
            bodyDigest: digest,
            bodyArtifactID: artifact.id,
            createdAt: builder.timestamp
        )
        let outbox = ProjectionOutboxItem(
            idempotencyKey: "final:\(messageID.description)",
            conversationID: conversationID,
            runID: runID,
            messageID: messageID,
            kind: .finalAnswer,
            payloadDigest: digest,
            payloadArtifactID: artifact.id
        )
        let receipt = try await repository.commitFinalization(
            RuntimeFinalizationCommit(
                message: message,
                outbox: outbox,
                mutation: RuntimeJournalMutation(append: append)
            )
        )
        let finalizationDisposition = receipt.appendReceipt.disposition
        let finalizationWasCommitted: Bool
        if finalizationDisposition == .appended {
            finalizationWasCommitted = true
        } else {
            finalizationWasCommitted = finalizationDisposition == .replayed
        }
        guard finalizationWasCommitted else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        broadcast(events, handleID: facts.projection.executionHandleID)
    }

    private func recoverInterruptedModel(
        facts: RuntimeRunFacts,
        history: ExecutionHistory
    ) async throws {
        guard let stepID = history.manifestEvents.last?.1 else {
            throw AgentExecutionError.invalidRecoveryBoundary
        }
        let expectedReservationID = ExecutionStableID.reservation(
            runID: facts.projection.runID,
            kind: "model",
            stableID: stepID.description
        )
        guard let reservation = facts.budgetLedger?.reservations.first(where: {
            $0.id == expectedReservationID
        }) else { throw AgentExecutionError.invalidRecoveryBoundary }
        let outcomeID = ExecutionStableID.event(
            runID: facts.projection.runID,
            key: "recovered-model-interruption-\(facts.projection.eventCount + 1)"
        )
        let conservativeUsage = reservation.maximumUsage
        let settled = try facts.budgetLedger!.settling(
            reservationID: reservation.id,
            actualUsage: conservativeUsage
        )
        let operations: [BudgetLedgerOperation] = [
            .settle(reservationID: reservation.id, actualUsage: conservativeUsage),
        ]
        _ = try await commitEvents(
            runID: facts.projection.runID,
            identity: .outcome(outcomeID),
            budgetOperations: operations
        ) { builder in
            var events = [try builder.append(
                id: outcomeID,
                event: .modelAttemptOutcome(.interrupted(nil)),
                cumulativeUsage: settled.consumed,
                redaction: Self.publicRedaction
            )]
            let waiting = try self.status(
                after: builder,
                state: .waitingForForeground,
                blockingReason: .foreground
            )
            events.append(try builder.append(
                id: self.nextEventID(builder, key: "recovery-waiting-foreground"),
                event: .statusChanged(waiting),
                transitionTo: .waitingForForeground,
                redaction: Self.publicRedaction
            ))
            return events
        }
        _ = history
    }

    private func finishQuiescence(runID: AgentRunID) async throws {
        await cancelActiveTool(runID: runID)
        let (facts, history) = try await loadRun(runID)
        guard facts.projection.state == .pausing else { return }
        let cancel = history.diagnostics.last(where: {
            $0.1.code == "execution.cancel-requested"
                || $0.1.code == "execution.pause-requested"
        })?.1.code == "execution.cancel-requested"
        let id = ExecutionStableID.event(
            runID: runID,
            key: "quiesced-\(facts.projection.eventCount + 1)"
        )
        let outstanding: [BudgetReservation]
        if let ledger = facts.budgetLedger {
            outstanding = ledger.reservations
        } else {
            outstanding = []
        }
        var operations: [BudgetLedgerOperation] = []
        operations.reserveCapacity(outstanding.count)
        for reservation in outstanding {
            operations.append(.release(reservationID: reservation.id))
        }
        var uncertainInterruption: AgentFailure?
        for marker in history.diagnostics.reversed() {
            guard marker.1.code == "execution.tool-attempt-interrupted-uncertain",
                  let invocationID = marker.1.details["invocationID"]
            else { continue }
            var isResolved = false
            for resolution in history.diagnostics where resolution.0.sequence > marker.0.sequence {
                guard resolution.1.details["invocationID"] == invocationID else { continue }
                let isSuccessResolution = resolution.1.code == "execution.reconciled-succeeded"
                let isFailureResolution = resolution.1.code == "execution.reconciled-failed"
                if isSuccessResolution {
                    isResolved = true
                    break
                }
                if isFailureResolution {
                    isResolved = true
                    break
                }
            }
            if !isResolved {
                uncertainInterruption = marker.1
                break
            }
        }
        _ = try await commitEvents(
            runID: runID,
            identity: .outcome(id),
            budgetOperations: operations
        ) { builder in
            if let uncertainInterruption,
               let rawInvocationID = uncertainInterruption.details["invocationID"],
               let invocationID = ToolInvocationID(rawInvocationID)
            {
                let waiting = try self.status(
                    after: builder,
                    state: .waitingForReconciliation,
                    failure: uncertainInterruption,
                    blockingReason: .reconciliation(invocationID: invocationID)
                )
                return [try builder.append(
                    id: id,
                    event: .statusChanged(waiting),
                    transitionTo: .waitingForReconciliation,
                    redaction: Self.publicRedaction
                )]
            }
            if cancel {
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
                    runID: runID,
                    status: terminal,
                    answer: nil,
                    usage: builder.usage
                )
                return [try builder.append(
                    id: id,
                    event: .terminal(result),
                    transitionTo: .cancelled,
                    redaction: Self.publicRedaction
                )]
            }
            let paused = try self.status(
                after: builder,
                state: .paused,
                blockingReason: .paused
            )
            return [try builder.append(
                id: id,
                event: .statusChanged(paused),
                transitionTo: .paused,
                redaction: Self.publicRedaction
            )]
        }
    }

    func failRun(
        runID: AgentRunID,
        reason: AgentTerminalReason,
        code: String,
        message: String
    ) async throws {
        let (facts, _) = try await loadRun(runID)
        guard !facts.projection.isTerminal,
              facts.projection.state != .waitingForReconciliation
        else { return }
        let failure = try ExecutionFailureFactory.make(reason: reason, code: code, message: message)
        let id = ExecutionStableID.event(
            runID: runID,
            key: "failed-\(reason.rawValue)-\(facts.projection.eventCount + 1)"
        )
        var operations: [BudgetLedgerOperation] = []
        if let ledger = facts.budgetLedger {
            operations.reserveCapacity(ledger.reservations.count)
            for reservation in ledger.reservations {
                operations.append(.release(reservationID: reservation.id))
            }
        }
        _ = try await commitEvents(
            runID: runID,
            identity: .outcome(id),
            budgetOperations: operations
        ) { builder in
            let terminal = try self.status(
                after: builder,
                state: .failed,
                terminalReason: reason,
                failure: failure
            )
            let result = try AgentResult(
                requestID: builder.requestID,
                executionHandleID: builder.handleID,
                runID: runID,
                status: terminal,
                answer: nil,
                usage: builder.usage
            )
            return [try builder.append(
                id: id,
                event: .terminal(result),
                transitionTo: .failed,
                redaction: Self.publicRedaction
            )]
        }
    }

    func failRun(runID: AgentRunID, workerError error: Error) async throws {
        let classification: (AgentTerminalReason, String, String)
        switch error {
        case AgentContractError.budgetExceeded,
             AgentContractError.arithmeticOverflow,
             AgentContractError.usageExceedsReservation:
            classification = (
                .budgetExceeded,
                "execution.budget-exceeded",
                "The run stopped because a fixed resource budget was exhausted."
            )
        case ContextCompilationError.contextUnsatisfiable:
            classification = (
                .contextUnsatisfiable,
                "execution.context-unsatisfiable",
                "The selected context cannot fit within this model's limits."
            )
        case AgentModelRuntimeError.providerNotFound,
             AgentModelRuntimeError.capabilityVersionMismatch,
             AgentModelRuntimeError.providerDescriptorChanged,
             AgentModelRuntimeError.modelTokenLimitExceeded,
             AgentModelRuntimeError.missingCapabilities,
             AgentModelRuntimeError.toolCallingUnavailable:
            classification = (
                .modelUnavailable,
                "execution.model-unavailable",
                "The exact model selected for this run is unavailable or incompatible."
            )
        case AgentModelRuntimeError.authorizationRejected,
             AgentContractError.authorizationDenied,
             AgentContractError.authorizationExpired:
            classification = (
                .permissionDenied,
                "execution.authorization-denied",
                "The operation no longer has valid authorization."
            )
        case AgentExecutionError.toolUnavailable:
            classification = (
                .toolUnavailable,
                "execution.tool-unavailable",
                "The exact tool selected for this run is unavailable."
            )
        case AgentExecutionError.dependencyUnavailable:
            classification = (
                .modelUnavailable,
                "execution.dependency-unavailable",
                "A dependency pinned by this run is unavailable."
            )
        default:
            classification = (
                .internalFailure,
                "execution.worker-failed",
                "The agent runtime could not continue this run."
            )
        }
        try await failRun(
            runID: runID,
            reason: classification.0,
            code: classification.1,
            message: classification.2
        )
    }
}
