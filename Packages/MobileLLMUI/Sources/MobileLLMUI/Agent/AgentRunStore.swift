// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AgentContracts
import AgentRuntime
import AppRuntime

/// One recoverable run surfaced by the neutral launch inbox. The app never auto-resumes these:
/// resuming is an explicit user action in the thread.
public struct RecoverableAgentRun: Identifiable, Equatable, Sendable {
    public let conversationID: UUID
    public let runID: AgentRunID
    public let handleID: AgentExecutionHandleID
    public let state: AgentRunState
    public let updatedAt: Date

    public var id: AgentRunID { runID }

    public init(
        conversationID: UUID,
        runID: AgentRunID,
        handleID: AgentExecutionHandleID,
        state: AgentRunState,
        updatedAt: Date
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.handleID = handleID
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// The source of recoverable runs. App assembly implements this over the SQLite journal so a neutral
/// launch can list pending runs without loading a model or selecting a conversation.
public protocol AgentRunRecoveryListing: Sendable {
    func recoverableRuns() async throws -> [RecoverableAgentRun]
}

/// Main-actor UI projection and command surface for durable agent runs.
///
/// This store owns no model, tool, or persistence implementation. It submits immutable requests,
/// projects committed journal events, forwards explicit commands, and hands committed answers back
/// to the conversation store through `onAnswer`.
@MainActor
@Observable
public final class AgentRunStore {
    /// conversationID → live projection.
    public private(set) var runs: [UUID: AgentRunPresentation] = [:]
    /// conversationID → assistant placeholder message that owns the run's final answer.
    private var assistantMessageIDs: [UUID: UUID] = [:]
    /// Recoverable runs discovered at launch (or via refresh).
    public private(set) var recoverableRuns: [RecoverableAgentRun] = []
    public private(set) var isRefreshingRecovery = false
    public var recoveryError: String?

    /// Invoked on the main actor when a run commits its final answer.
    public var onAnswer: (@MainActor (UUID, UUID, String, String?, [AgentRunStep]) -> Void)?
    /// Invoked when a run fails terminally without an answer.
    public var onRunFailed: (@MainActor (UUID, UUID, String) -> Void)?
    /// Invoked when a run first becomes visible (submission accepted).
    public var onRunStarted: (@MainActor (UUID, UUID) -> Void)?

    private let executor: any AgentExecutor
    private let requestBuilder: any AgentRunRequestBuilding
    private let recovery: (any AgentRunRecoveryListing)?
    private var handles: [AgentRunID: any AgentExecutionHandle] = [:]
    private var eventTasks: [AgentRunID: Task<Void, Never>] = [:]
    private var ephemeralTasks: [AgentRunID: Task<Void, Never>] = [:]

    public init(
        executor: any AgentExecutor,
        requestBuilder: any AgentRunRequestBuilding,
        recovery: (any AgentRunRecoveryListing)? = nil
    ) {
        self.executor = executor
        self.requestBuilder = requestBuilder
        self.recovery = recovery
    }

    // MARK: - Submitting

    /// Starts one durable root run for a user turn. The caller (ChatStore) has already appended the
    /// user message and an empty assistant placeholder; `assistantMessageID` is where the committed
    /// answer is projected.
    @discardableResult
    public func start(
        conversationID: UUID,
        userMessageID: UUID,
        assistantMessageID: UUID,
        text: String,
        imageRefs: [ImageRef]
    ) async throws -> AgentRunID {
        let submission = try await requestBuilder.buildSubmission(
            conversationID: conversationID,
            userTurnID: userMessageID,
            text: text,
            imageRefs: imageRefs
        )
        let handleID = try await executor.submit(
            submission.request,
            commandID: AgentCommandID(rawValue: UUID())
        )
        let handle = try await executor.attach(to: handleID)
        handles[submission.request.runID] = handle
        assistantMessageIDs[conversationID] = assistantMessageID
        runs[conversationID] = AgentRunPresentation(
            conversationID: conversationID,
            runID: submission.request.runID,
            handleID: handleID,
            state: .created
        )
        onRunStarted?(conversationID, assistantMessageID)
        subscribe(runID: submission.request.runID, conversationID: conversationID, handle: handle)
        return submission.request.runID
    }

    /// Reattaches to a recoverable run and starts projecting it again. This does NOT resume it;
    /// the user must press Resume, exactly as the spec requires.
    public func reopen(recoverable: RecoverableAgentRun, assistantMessageID: UUID?) async throws {
        let handle = try await executor.attach(to: recoverable.handleID)
        handles[recoverable.runID] = handle
        if let assistantMessageID {
            assistantMessageIDs[recoverable.conversationID] = assistantMessageID
        }
        runs[recoverable.conversationID] = AgentRunPresentation(
            conversationID: recoverable.conversationID,
            runID: recoverable.runID,
            handleID: recoverable.handleID,
            state: recoverable.state,
            updatedAt: recoverable.updatedAt
        )
        recoverableRuns.removeAll { $0.runID == recoverable.runID }
        subscribe(runID: recoverable.runID, conversationID: recoverable.conversationID, handle: handle)
    }

    /// Refreshes the recoverable-run inbox (neutral launch / pull to refresh).
    public func refreshRecoverableRuns() async {
        guard let recovery else { return }
        isRefreshingRecovery = true
        recoveryError = nil
        defer { isRefreshingRecovery = false }
        do {
            let listed = try await recovery.recoverableRuns()
            let known = Set(runs.values.compactMap(\.handleID))
            recoverableRuns = listed.filter { !known.contains($0.handleID) }
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    // MARK: - Commands

    public func pause(conversationID: UUID) async {
        await send(conversationID: conversationID) { status, runID in
            try AgentCommand(
                commandID: AgentCommandID(rawValue: UUID()),
                runID: runID,
                expectedRunStateVersion: status.stateVersion,
                action: .pause(reason: .userRequested),
                issuedAt: try AgentTimestamp(Date())
            )
        }
    }

    public func resume(conversationID: UUID) async {
        await send(conversationID: conversationID) { status, runID in
            try AgentCommand(
                commandID: AgentCommandID(rawValue: UUID()),
                runID: runID,
                expectedRunStateVersion: status.stateVersion,
                action: .resume,
                issuedAt: try AgentTimestamp(Date())
            )
        }
    }

    public func cancel(conversationID: UUID) async {
        await send(conversationID: conversationID) { status, runID in
            try AgentCommand(
                commandID: AgentCommandID(rawValue: UUID()),
                runID: runID,
                expectedRunStateVersion: status.stateVersion,
                action: .cancel,
                issuedAt: try AgentTimestamp(Date())
            )
        }
    }

    public func decideApproval(conversationID: UUID, approvalID: ApprovalID, approved: Bool) async {
        await send(conversationID: conversationID) { status, runID in
            try AgentCommand(
                commandID: AgentCommandID(rawValue: UUID()),
                runID: runID,
                expectedRunStateVersion: status.stateVersion,
                action: .decideApproval(
                    approvalID: approvalID,
                    decision: approved ? .approved : .denied,
                    approvedScope: approved ? .exactInvocation : nil
                ),
                issuedAt: try AgentTimestamp(Date())
            )
        }
    }

    public func respond(conversationID: UUID, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let run = runs[conversationID],
              let request = run.pendingUserInput,
              let status = try? await status(of: run)
        else { return }
        do {
            let response = try UserInputResponse(
                requestID: request.id,
                expectedRunStateVersion: status.stateVersion,
                value: .string(trimmed)
            )
            let command = try AgentCommand(
                commandID: AgentCommandID(rawValue: UUID()),
                runID: run.runID,
                expectedRunStateVersion: status.stateVersion,
                action: .respond(response),
                issuedAt: try AgentTimestamp(Date())
            )
            try await sendCommand(command, conversationID: conversationID)
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    public func reconcile(conversationID: UUID, invocationID: ToolInvocationID, decision: AgentReconciliationDecision) async {
        await send(conversationID: conversationID) { status, runID in
            try AgentCommand(
                commandID: AgentCommandID(rawValue: UUID()),
                runID: runID,
                expectedRunStateVersion: status.stateVersion,
                action: .reconcile(invocationID: invocationID, decision: decision),
                issuedAt: try AgentTimestamp(Date())
            )
        }
    }

    // MARK: - Projection

    public func presentation(for conversationID: UUID) -> AgentRunPresentation? {
        runs[conversationID]
    }

    public func presentation(for runID: AgentRunID) -> AgentRunPresentation? {
        runs.values.first { $0.runID == runID }
    }

    /// Clears the projection for a deleted conversation.
    public func discard(conversationID: UUID) {
        guard let run = runs.removeValue(forKey: conversationID) else { return }
        assistantMessageIDs.removeValue(forKey: conversationID)
        eventTasks[run.runID]?.cancel()
        ephemeralTasks[run.runID]?.cancel()
        eventTasks.removeValue(forKey: run.runID)
        ephemeralTasks.removeValue(forKey: run.runID)
        handles.removeValue(forKey: run.runID)
    }

    // MARK: - Internals

    private func subscribe(
        runID: AgentRunID,
        conversationID: UUID,
        handle: any AgentExecutionHandle
    ) {
        eventTasks[runID]?.cancel()
        eventTasks[runID] = Task { @MainActor [weak self] in
            do {
                for try await envelope in handle.events(after: nil) {
                    self?.apply(envelope, conversationID: conversationID)
                }
            } catch is CancellationError {
                // Detached observer or discarded conversation; the run itself is unaffected.
            } catch {
                self?.markSubscriptionFailure(
                    runID: runID,
                    conversationID: conversationID,
                    message: error.localizedDescription
                )
            }
        }
        ephemeralTasks[runID]?.cancel()
        ephemeralTasks[runID] = Task { @MainActor [weak self] in
            let stream = await handle.ephemeralEvents()
            do {
                for try await envelope in stream {
                    self?.applyEphemeral(envelope, conversationID: conversationID)
                }
            } catch {
                // Live-only stream ended; durable projection remains authoritative.
            }
        }
    }

    private func apply(_ envelope: AgentEventEnvelope, conversationID: UUID) {
        guard var run = runs[conversationID] else { return }
        let record = envelope.payload
        var steps = run.steps
        switch record.event {
        case .statusChanged(let status):
            run = run.replacing(
                state: status.state,
                terminalReason: status.terminalReason,
                blockingReason: status.blockingReason,
                failureMessage: status.failure?.safeMessage
            )
            steps.append(step(
                kind: stateStepKind(status.state),
                title: stateTitle(status.state),
                detail: status.failure?.safeMessage ?? "",
                status: stateStepStatus(status.state),
                sequence: record.sequence
            ))
        case .approvalRequested(let request):
            let plan = request.prepared.plan
            run = run.replacing(
                blockingReason: .approval(approvalID: request.id),
                pendingApproval: AgentApprovalCard(
                    approvalID: request.id,
                    toolName: plan.descriptorID ?? plan.subjectID,
                    destination: plan.destination.map { "\($0.kind.rawValue) \($0.normalizedIdentity)" },
                    preview: plan.userPreview.isEmpty ? plan.subjectID : plan.userPreview,
                    dataCategories: plan.dataCategories.map(\.rawValue),
                    effects: plan.effects.map(\.rawValue),
                    isExternalWrite: plan.effects.contains(.externalWrite)
                )
            )
            steps.append(step(
                kind: .approval,
                title: "Approval needed: \(plan.descriptorID ?? plan.subjectID)",
                detail: plan.userPreview,
                status: .waiting,
                sequence: record.sequence
            ))
        case .approvalDecided(let receipt):
            run = run.replacing(pendingApproval: nil)
            steps.append(step(
                kind: .approval,
                title: receipt.decision == .approved ? "Approved" : "Denied",
                detail: receipt.decision == .approved ? "Operation authorized." : "Operation declined.",
                status: receipt.decision == .approved ? .succeeded : .failed,
                sequence: record.sequence
            ))
        case .userInputRequested(let request):
            run = run.replacing(
                blockingReason: .userInput(requestID: request.id),
                pendingUserInput: request
            )
            steps.append(step(
                kind: .userInput,
                title: "Question for you",
                detail: request.prompt,
                status: .waiting,
                sequence: record.sequence
            ))
        case .userInputResponseCommitted(let requestID, _):
            if run.pendingUserInput?.id == requestID {
                run = run.replacing(pendingUserInput: nil)
            }
            steps.append(step(
                kind: .userInput,
                title: "Answered",
                status: .succeeded,
                sequence: record.sequence
            ))
        case .toolIntentRecorded(let prepared):
            steps.append(step(
                kind: .toolCall,
                title: prepared.plan.subjectID,
                detail: prepared.plan.canonicalArguments?.string ?? "",
                status: .running,
                sequence: record.sequence
            ))
        case .toolOutcomeRecorded(let invocationID, let outcome):
            if let index = steps.lastIndex(where: {
                $0.kind == .toolCall && $0.status == .running && $0.sequence <= record.sequence
            }) {
                let status: AgentRunStep.Status
                let detail: String
                switch outcome {
                case .completed:
                    status = .succeeded
                    detail = "Completed"
                case .failed(let failure):
                    status = .failed
                    detail = failure.safeMessage
                case .uncertain(let failure):
                    status = .uncertain
                    detail = failure.safeMessage
                }
                steps[index] = AgentRunStep(
                    id: steps[index].id,
                    kind: .toolCall,
                    title: steps[index].title,
                    detail: detail,
                    status: status,
                    sequence: steps[index].sequence
                )
            }
        case .modelAttemptOutcome(let outcome):
            let status: AgentRunStep.Status
            switch outcome {
            case .completed: status = .succeeded
            case .failed: status = .failed
            case .interrupted: status = .failed
            }
            steps.append(step(
                kind: .modelAttempt,
                title: "Model pass",
                status: status,
                sequence: record.sequence
            ))
        case .terminal(let result):
            run = run.replacing(
                state: result.status.state,
                terminalReason: result.status.terminalReason,
                finalText: result.answer?.text,
                failureMessage: result.status.failure?.safeMessage
            )
            steps.append(step(
                kind: .finalization,
                title: result.status.state == .completed ? "Completed" : "Terminated",
                status: result.status.state == .completed ? .succeeded : .failed,
                sequence: record.sequence
            ))
            if let answer = result.answer?.text {
                finish(
                    conversationID: conversationID,
                    run: run,
                    text: answer,
                    reasoning: run.reasoningText,
                    steps: steps
                )
            }
        case .diagnostic(let failure):
            steps.append(step(
                kind: .diagnostic,
                title: failure.code,
                detail: failure.safeMessage,
                status: failure.classification == .potentiallySideEffecting ? .uncertain : .failed,
                sequence: record.sequence
            ))
        case .runInputSnapshotCommitted:
            steps.append(step(
                kind: .preparation,
                title: "Run inputs frozen",
                status: .succeeded,
                sequence: record.sequence
            ))
        case .compiledManifestCommitted:
            steps.append(step(
                kind: .preparation,
                title: "Context compiled",
                status: .succeeded,
                sequence: record.sequence
            ))
        case .validatedActionCommitted:
            steps.append(step(
                kind: .modelAttempt,
                title: "Action validated",
                status: .succeeded,
                sequence: record.sequence
            ))
        case .artifactCommitted:
            steps.append(step(
                kind: .finalization,
                title: "Artifact saved",
                status: .succeeded,
                sequence: record.sequence
            ))
        case .usageUpdated:
            break
        }
        runs[conversationID] = run.replacing(steps: deduplicated(steps))
    }

    private func applyEphemeral(_ envelope: AgentEphemeralEventEnvelope, conversationID: UUID) {
        guard var run = runs[conversationID] else { return }
        switch envelope.event {
        case .model(let event):
            switch event {
            case .visibleReasoningDelta(let delta):
                run = run.replacing(reasoningText: run.reasoningText + delta)
            case .provisionalAnswerDelta(let delta):
                run = run.replacing(provisionalText: run.provisionalText + delta)
            case .usage:
                break
            case .provisionalAnswerResolved:
                break
            }
        case .toolProgress:
            break
        }
        runs[conversationID] = run
    }

    private func finish(
        conversationID: UUID,
        run: AgentRunPresentation,
        text: String,
        reasoning: String,
        steps: [AgentRunStep]
    ) {
        runs[conversationID] = run.replacing(
            steps: deduplicated(steps),
            provisionalText: "",
            finalText: text
        )
        guard let assistantMessageID = assistantMessageIDs[conversationID] else { return }
        onAnswer?(conversationID, assistantMessageID, text, reasoning.isEmpty ? nil : reasoning, steps)
        if run.isTerminal {
            eventTasks[run.runID]?.cancel()
            ephemeralTasks[run.runID]?.cancel()
        }
    }

    private func markSubscriptionFailure(runID: AgentRunID, conversationID: UUID, message: String) {
        guard var run = runs[conversationID] else { return }
        run = run.replacing(
            state: .failed,
            terminalReason: .internalFailure,
            failureMessage: message
        )
        runs[conversationID] = run
        guard let assistantMessageID = assistantMessageIDs[conversationID] else { return }
        onRunFailed?(conversationID, assistantMessageID, message)
    }

    private func send(
        conversationID: UUID,
        makeCommand: @Sendable (AgentRunStatus, AgentRunID) throws -> AgentCommand
    ) async {
        guard let run = runs[conversationID] else { return }
        do {
            let status = try await status(of: run)
            let command = try makeCommand(status, run.runID)
            try await sendCommand(command, conversationID: conversationID)
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    private func status(of run: AgentRunPresentation) async throws -> AgentRunStatus {
        if let handle = handles[run.runID] {
            return try await handle.status()
        }
        throw AgentExecutionError.executionNotFound(AgentExecutionHandleID())
    }

    private func sendCommand(_ command: AgentCommand, conversationID: UUID) async throws {
        guard let run = runs[conversationID], let handle = handles[run.runID] else { return }
        let receipt = try await handle.send(try AgentCommandEnvelope(payload: command))
        if receipt.disposition == .accepted,
           let updated = try? await handle.status()
        {
            applyStatus(updated, conversationID: conversationID)
        }
    }

    private func applyStatus(_ status: AgentRunStatus, conversationID: UUID) {
        guard var run = runs[conversationID] else { return }
        run = run.replacing(
            state: status.state,
            terminalReason: status.terminalReason,
            blockingReason: status.blockingReason,
            failureMessage: status.failure?.safeMessage
        )
        runs[conversationID] = run
    }

    private func step(
        kind: AgentRunStep.Kind,
        title: String,
        detail: String = "",
        status: AgentRunStep.Status,
        sequence: UInt64
    ) -> AgentRunStep {
        AgentRunStep(kind: kind, title: title, detail: detail, status: status, sequence: sequence)
    }

    /// Durable events may arrive more than once across reattach; keep the latest state per sequence
    /// and preserve stable ordering.
    private func deduplicated(_ steps: [AgentRunStep]) -> [AgentRunStep] {
        var bySequence: [UInt64: AgentRunStep] = [:]
        for step in steps { bySequence[step.sequence] = step }
        return bySequence.values.sorted { $0.sequence < $1.sequence }
    }

    private func stateStepKind(_ state: AgentRunState) -> AgentRunStep.Kind {
        switch state {
        case .waitingForApproval: .approval
        case .waitingForUser: .userInput
        case .waitingForReconciliation: .reconciliation
        case .completed, .failed, .cancelled: .finalization
        case .generating, .synthesizing: .modelAttempt
        case .executingTools: .toolCall
        default: .preparation
        }
    }

    private func stateStepStatus(_ state: AgentRunState) -> AgentRunStep.Status {
        switch state {
        case .completed: .succeeded
        case .failed, .cancelled: .failed
        case .waitingForApproval, .waitingForUser, .paused, .waitingForForeground,
             .waitingForReconciliation: .waiting
        default: .running
        }
    }

    private func stateTitle(_ state: AgentRunState) -> String {
        switch state {
        case .created: "Run created"
        case .preparing: "Preparing"
        case .waitingForModel: "Waiting for model"
        case .generating: "Generating"
        case .validatingAction: "Validating action"
        case .waitingForApproval: "Waiting for approval"
        case .executingTools: "Running tools"
        case .waitingForUser: "Waiting for you"
        case .synthesizing: "Synthesizing"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .waitingForForeground: "Waiting for foreground"
        case .waitingForReconciliation: "Waiting to reconcile"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
