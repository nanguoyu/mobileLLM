// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts

/// One normalized step the user can see inside a durable agent run. Steps are derived from durable
/// journal events, so they survive relaunch and never depend on disclosure visibility.
public struct AgentRunStep: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case preparation
        case modelAttempt
        case toolCall
        case approval
        case userInput
        case reconciliation
        case waiting
        case finalization
        case diagnostic
    }

    public enum Status: String, Equatable, Sendable {
        case pending
        case running
        case waiting
        case succeeded
        case failed
        case uncertain
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let detail: String
    /// Short user-visible outcome for a committed action (e.g. the text a tool returned). nil until
    /// the action settles, and for actions whose outcome carries no summary.
    public let resultText: String?
    public let status: Status
    public let sequence: UInt64

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String = "",
        resultText: String? = nil,
        status: Status,
        sequence: UInt64
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.resultText = resultText
        self.status = status
        self.sequence = sequence
    }
}

extension AgentRunStep {
    /// Short user-visible outcome text for a committed step.
    public var statusText: String? {
        switch status {
        case .succeeded: nil
        case .failed: "Failed"
        case .uncertain: "Uncertain"
        case .running, .waiting, .pending: "Running…"
        }
    }
}

/// The exact prepared operation shown for one approval decision. The model can never alter this
/// preview: it is copied from the durable approval request the runtime prepared.
public struct AgentApprovalCard: Equatable, Sendable {
    public let approvalID: ApprovalID
    public let toolName: String
    public let destination: String?
    public let preview: String
    public let dataCategories: [String]
    public let effects: [String]
    public let isExternalWrite: Bool

    public init(
        approvalID: ApprovalID,
        toolName: String,
        destination: String?,
        preview: String,
        dataCategories: [String],
        effects: [String],
        isExternalWrite: Bool
    ) {
        self.approvalID = approvalID
        self.toolName = toolName
        self.destination = destination
        self.preview = preview
        self.dataCategories = dataCategories
        self.effects = effects
        self.isExternalWrite = isExternalWrite
    }
}

/// The main-actor projection of one agent run, rebuilt from committed journal events plus the
/// live-only ephemeral stream. Ordinary answers look ordinary; complex work shows steps.
public struct AgentRunPresentation: Equatable, Sendable {
    public let conversationID: UUID
    public let runID: AgentRunID
    public let handleID: AgentExecutionHandleID?
    public let state: AgentRunState?
    public let terminalReason: AgentTerminalReason?
    public let blockingReason: AgentBlockingReason?
    public let steps: [AgentRunStep]
    public let pendingApproval: AgentApprovalCard?
    public let pendingUserInput: UserInputRequest?
    public let provisionalText: String
    public let reasoningText: String
    public let finalText: String?
    public let failureMessage: String?
    /// Final cumulative usage from the terminal result (used to render generation stats).
    public let usage: AgentUsage?
    public let updatedAt: Date

    public init(
        conversationID: UUID,
        runID: AgentRunID,
        handleID: AgentExecutionHandleID? = nil,
        state: AgentRunState? = nil,
        terminalReason: AgentTerminalReason? = nil,
        blockingReason: AgentBlockingReason? = nil,
        steps: [AgentRunStep] = [],
        pendingApproval: AgentApprovalCard? = nil,
        pendingUserInput: UserInputRequest? = nil,
        provisionalText: String = "",
        reasoningText: String = "",
        finalText: String? = nil,
        failureMessage: String? = nil,
        usage: AgentUsage? = nil,
        updatedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.handleID = handleID
        self.state = state
        self.terminalReason = terminalReason
        self.blockingReason = blockingReason
        self.steps = steps
        self.pendingApproval = pendingApproval
        self.pendingUserInput = pendingUserInput
        self.provisionalText = provisionalText
        self.reasoningText = reasoningText
        self.finalText = finalText
        self.failureMessage = failureMessage
        self.usage = usage
        self.updatedAt = updatedAt
    }

    /// Whether the run is doing work or durably waiting right now.
    public var isActive: Bool {
        guard let state else { return false }
        switch state {
        case .created, .preparing, .waitingForModel, .generating, .validatingAction,
             .executingTools, .synthesizing, .pausing:
            return true
        case .waitingForApproval, .waitingForUser, .paused, .waitingForForeground,
             .waitingForReconciliation, .completed, .failed, .cancelled:
            return false
        }
    }

    public var isTerminal: Bool { state?.isTerminal ?? false }

    public var isResumable: Bool {
        state == .paused || state == .waitingForForeground
    }

    public var isWaiting: Bool {
        switch state {
        case .waitingForApproval, .waitingForUser, .paused, .waitingForForeground,
             .waitingForReconciliation:
            return true
        default:
            return false
        }
    }

    /// Whether the run needs the agent activity panel at all. Pure chat stays visually identical to
    /// the ordinary message stream; the panel appears only when there is real agent work to expose
    /// (tools, approvals, waits, failures, paused/backgrounded runs).
    public var needsPanel: Bool {
        if pendingApproval != nil || pendingUserInput != nil { return true }
        if isWaiting { return true }
        if steps.contains(where: { $0.kind == .toolCall }) { return true }
        if state == .failed || state == .cancelled { return true }
        return false
    }

    public func replacing(
        state: AgentRunState? = nil,
        terminalReason: AgentTerminalReason? = nil,
        blockingReason: AgentBlockingReason?? = nil,
        steps: [AgentRunStep]? = nil,
        pendingApproval: AgentApprovalCard?? = nil,
        pendingUserInput: UserInputRequest?? = nil,
        provisionalText: String? = nil,
        reasoningText: String? = nil,
        finalText: String?? = nil,
        failureMessage: String?? = nil,
        usage: AgentUsage? = nil,
        handleID: AgentExecutionHandleID? = nil
    ) -> AgentRunPresentation {
        AgentRunPresentation(
            conversationID: conversationID,
            runID: runID,
            handleID: handleID ?? self.handleID,
            state: state ?? self.state,
            terminalReason: terminalReason ?? self.terminalReason,
            blockingReason: blockingReason ?? self.blockingReason,
            steps: steps ?? self.steps,
            pendingApproval: pendingApproval ?? self.pendingApproval,
            pendingUserInput: pendingUserInput ?? self.pendingUserInput,
            provisionalText: provisionalText ?? self.provisionalText,
            reasoningText: reasoningText ?? self.reasoningText,
            finalText: finalText ?? self.finalText,
            failureMessage: failureMessage ?? self.failureMessage,
            usage: usage ?? self.usage,
            updatedAt: Date()
        )
    }
}
