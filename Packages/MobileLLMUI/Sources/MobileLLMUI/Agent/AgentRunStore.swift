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
    /// Invoked when a run terminates without a committed answer (cancelled or failed), so the chat
    /// surface can settle the streaming row instead of leaving it live forever.
    public var onRunTerminated: (@MainActor (UUID, UUID, AgentTerminalReason, String?) -> Void)?
    /// Invoked when a run first becomes visible (submission accepted).
    public var onRunStarted: (@MainActor (UUID, UUID) -> Void)?
    /// Live-only token activity (reasoning/answer deltas) so the composer's streaming surface can
    /// render the same thinking/answering phases the legacy loop produced.
    public var onEphemeral: (@MainActor (UUID, AgentEphemeralDeltaKind, String) -> Void)?

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

    /// iOS 17 background quiescence (spec §19.1): every actively progressing run receives one
    /// idempotent foreground-lost pause at its next safe boundary. Recovery never assumes the OS
    /// granted enough time; the run durably lands in a waiting state and resumes only through an
    /// explicit user Resume.
    public func quiesceForBackground() async {
        let activeConversations = runs.compactMap { conversationID, run -> UUID? in
            run.isActive ? conversationID : nil
        }
        for conversationID in activeConversations {
            await send(conversationID: conversationID) { status, runID in
                try AgentCommand(
                    commandID: AgentCommandID(rawValue: UUID()),
                    runID: runID,
                    expectedRunStateVersion: status.stateVersion,
                    action: .pause(reason: .foregroundLost),
                    issuedAt: try AgentTimestamp(Date())
                )
            }
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
                blockingReason: .some(status.blockingReason),
                failureMessage: Self.describe(status.failure)
            )
            // Steps are action lifecycles: every state advance settles previously in-flight or
            // waiting actions, then the current status contributes a step only when it describes a
            // user-meaningful action (tools, approvals, questions, waits, terminal outcomes).
            let settled = steps.map { entry -> AgentRunStep in
                guard entry.status == .running || entry.status == .waiting
                        || entry.status == .pending
                else { return entry }
                return AgentRunStep(
                    id: entry.id,
                    kind: entry.kind,
                    title: entry.title,
                    detail: entry.detail,
                    status: .succeeded,
                    sequence: entry.sequence
                )
            }
            if let semantic = Self.semanticStep(for: status, sequence: record.sequence) {
                steps = settled + [semantic]
            } else {
                steps = settled
            }
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
            run = run.replacing(
                blockingReason: .some(nil),
                pendingApproval: .some(nil)
            )
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
                run = run.replacing(
                    blockingReason: .some(nil),
                    pendingUserInput: .some(nil)
                )
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
                title: Self.toolDisplayName(prepared.plan.subjectID),
                detail: Self.toolArgumentSummary(prepared.plan.canonicalArguments?.string),
                status: .running,
                sequence: record.sequence
            ))
        case .toolOutcomeRecorded(_, let outcome):
            if let index = steps.lastIndex(where: {
                $0.kind == .toolCall && $0.status == .running && $0.sequence <= record.sequence
            }) {
                let status: AgentRunStep.Status
                let resultText: String?
                switch outcome {
                case .completed(let results):
                    status = .succeeded
                    resultText = Self.toolResultSummary(results)
                case .failed(let failure):
                    status = .failed
                    resultText = failure.safeMessage
                case .uncertain(let failure):
                    status = .uncertain
                    resultText = failure.safeMessage
                }
                steps[index] = AgentRunStep(
                    id: steps[index].id,
                    kind: .toolCall,
                    title: steps[index].title,
                    detail: steps[index].detail,
                    resultText: resultText,
                    status: status,
                    sequence: steps[index].sequence
                )
            }
        case .modelAttemptOutcome:
            // Token activity is rendered by the streaming row; a per-pass step is internal noise.
            break
        case .terminal(let result):
            run = run.replacing(
                state: result.status.state,
                terminalReason: result.status.terminalReason,
                blockingReason: .some(nil),
                finalText: result.answer?.text,
                failureMessage: Self.describe(result.status.failure),
                usage: result.usage
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
            } else if let assistantMessageID = assistantMessageIDs[conversationID] {
                let reason = result.status.terminalReason ?? .internalFailure
                let message = result.status.failure?.safeMessage
                    ?? "The run ended without a committed answer."
                onRunTerminated?(conversationID, assistantMessageID, reason, message)
            }
        case .diagnostic(let failure):
            // Runtime diagnostics are durable bookkeeping (tool-attempt markers, retries,
            // structured repairs). They are not failures and must not paint a ❌ beside a
            // completed run. Only an uncertain external outcome is user-meaningful here:
            // the run itself blocks for reconciliation and the step says so.
            guard failure.classification == .potentiallySideEffecting else { break }
            steps.append(step(
                kind: .diagnostic,
                title: failure.code,
                detail: failure.safeMessage,
                status: .uncertain,
                sequence: record.sequence
            ))
        case .runInputSnapshotCommitted, .compiledManifestCommitted,
             .validatedActionCommitted, .artifactCommitted:
            // Internal pipeline boundaries are not user actions; the UI stays focused on what the
            // agent is doing (tools, approvals, questions, waits), not how the runtime is plumbed.
            break
        case .usageUpdated:
            break
        }
        runs[conversationID] = run.replacing(steps: deduplicated(steps))
    }

    private func applyEphemeral(_ envelope: AgentEphemeralEventEnvelope, conversationID: UUID) {
        guard var run = runs[conversationID], !run.isTerminal else {
            // Live-only deltas that race in after the durable terminal event must never resurrect
            // "still working" text over a committed answer.
            return
        }
        switch envelope.event {
        case .model(let event):
            switch event {
            case .visibleReasoningDelta(let delta):
                run = run.replacing(reasoningText: run.reasoningText + delta)
                onEphemeral?(conversationID, .reasoning, delta)
            case .provisionalAnswerDelta(let delta):
                run = run.replacing(provisionalText: run.provisionalText + delta)
                onEphemeral?(conversationID, .answer, delta)
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
            blockingReason: .some(status.blockingReason),
            failureMessage: Self.describe(status.failure)
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

    /// One user-meaningful action step for a status that deserves one. Internal pipeline states
    /// (preparing, waiting for the model, generating, validating, synthesizing) deliberately produce
    /// no step: token activity is rendered by the streaming row, and plumbing stages are noise.
    private static func semanticStep(
        for status: AgentRunStatus,
        sequence: UInt64
    ) -> AgentRunStep? {
        let step: AgentRunStep
        switch status.state {
        case .waitingForApproval:
            step = AgentRunStep(
                kind: .approval,
                title: "Waiting for approval",
                status: .waiting,
                sequence: sequence
            )
        case .waitingForUser:
            step = AgentRunStep(
                kind: .userInput,
                title: "Waiting for your answer",
                status: .waiting,
                sequence: sequence
            )
        case .waitingForReconciliation:
            step = AgentRunStep(
                kind: .reconciliation,
                title: "External result uncertain",
                status: .waiting,
                sequence: sequence
            )
        case .paused:
            step = AgentRunStep(
                kind: .waiting,
                title: "Paused",
                status: .waiting,
                sequence: sequence
            )
        case .waitingForForeground:
            step = AgentRunStep(
                kind: .waiting,
                title: "Backgrounded — resume to continue",
                status: .waiting,
                sequence: sequence
            )
        case .completed:
            step = AgentRunStep(
                kind: .finalization,
                title: "Completed",
                status: .succeeded,
                sequence: sequence
            )
        case .failed:
            step = AgentRunStep(
                kind: .finalization,
                title: "Failed",
                detail: status.failure?.safeMessage ?? "",
                status: .failed,
                sequence: sequence
            )
        case .cancelled:
            step = AgentRunStep(
                kind: .finalization,
                title: "Stopped",
                status: .failed,
                sequence: sequence
            )
        case .created, .preparing, .waitingForModel, .generating, .validatingAction,
             .executingTools, .synthesizing, .pausing:
            return nil
        }
        return step
    }

    /// "builtin:current_datetime" / "7:builtin8:calculator" → "calculator": the visible action
    /// keeps the tool's real name (the message row and panel prettify it), not the internal subject id.
    private static func toolDisplayName(_ subjectID: String) -> String {
        subjectID.split(separator: ":").last.map(String.init) ?? subjectID
    }

    private static func toolArgumentSummary(_ json: String?) -> String {
        guard let json, !json.isEmpty else { return "" }
        let compact = json
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return compact.count <= 120 ? compact : String(compact.prefix(117)) + "…"
    }

    /// Bounded one-line summary of a successful tool result for the committed ToolRun row.
    private static func toolResultSummary(_ results: ToolResultCollection) -> String? {
        let parts = results.map { content -> String in
            switch content {
            case .text(let text):
                return text.value
            case .structured(let structured):
                return String(decoding: structured.value.data, as: UTF8.self)
            case .resourceLink(let link):
                return link.url
            case .image, .artifact:
                return "[artifact]"
            }
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " | ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return joined.count <= 240 ? joined : String(joined.prefix(237)) + "…"
    }

    /// Redacted failure text including the typed reason when present, so device diagnostics show why
    /// a run failed (e.g. "engine stream ended without usage statistics") rather than only the
    /// generic safe message.
    private static func describe(_ failure: AgentFailure?) -> String? {
        guard let failure else { return nil }
        if let reason = failure.details["reason"] {
            return "\(failure.safeMessage) (\(reason))"
        }
        return failure.safeMessage
    }

}

/// Discriminator for live-only token deltas forwarded to the chat streaming surface.
public enum AgentEphemeralDeltaKind: Sendable {
    case reasoning
    case answer
}
