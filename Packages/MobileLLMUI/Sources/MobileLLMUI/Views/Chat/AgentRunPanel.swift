// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

/// A compact badge for the conversation list: dot + short label for a run that is active, waiting,
/// or failed. A neutral launch never navigates to the run — it is only marked here.
struct AgentRunBadge: View {
    let run: AgentRunPresentation

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Run status: \(label)")
    }

    private var color: Color {
        guard let state = run.state else { return Theme.fitGray }
        return switch state {
        case .completed: Theme.fitGreen
        case .failed, .cancelled: Theme.danger
        case .waitingForApproval, .waitingForUser, .waitingForReconciliation: Theme.accent
        case .paused, .waitingForForeground: Theme.fitAmber
        default: Theme.accent
        }
    }

    private var label: String {
        guard let state = run.state else { return "run" }
        return switch state {
        case .completed: "done"
        case .failed: "failed"
        case .cancelled: "stopped"
        case .waitingForApproval: "approval"
        case .waitingForUser: "asks you"
        case .paused: "paused"
        case .waitingForForeground: "backgrounded"
        case .waitingForReconciliation: "needs review"
        default: "working"
        }
    }
}

/// The top-level agent interaction surface inside one chat thread: a compact activity row that
/// expands into steps, approval and reconciliation cards, user-input prompts, and Pause/Resume/Stop.
struct AgentRunPanel: View {
    let store: AgentRunStore
    let conversationID: UUID
    @State private var expanded = false
    @State private var userResponse = ""

    private var run: AgentRunPresentation? { store.presentation(for: conversationID) }

    var body: some View {
        if let run {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                activityRow(run)
                if expanded {
                    stepsList(run)
                }
                if let approval = run.pendingApproval {
                    approvalCard(approval, run: run)
                }
                if let request = run.pendingUserInput {
                    userInputCard(request, run: run)
                }
                if run.state == .waitingForReconciliation, let invocation = run.blockingReason {
                    reconciliationCard(invocation, run: run)
                }
                if !run.provisionalText.isEmpty || run.state == .generating || run.state == .synthesizing {
                    provisionalOutput(run)
                }
                controls(run)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            }
        }
    }

    // MARK: Activity row

    private func activityRow(_ run: AgentRunPresentation) -> some View {
        Button {
            withAnimation(Motion.spring) { expanded.toggle() }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                statusIcon(run)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activityTitle(run))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(activitySubtitle(run))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activityTitle(run))
        .accessibilityHint("Show or hide run steps")
    }

    private func statusIcon(_ run: AgentRunPresentation) -> some View {
        Group {
            switch run.state {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.fitGreen)
            case .failed, .cancelled:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
            case .waitingForApproval, .waitingForUser, .waitingForReconciliation:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
            case .paused, .waitingForForeground:
                Image(systemName: "pause.circle.fill").foregroundStyle(Theme.fitAmber)
            default:
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
        }
        .frame(width: 20, height: 20)
    }

    private func activityTitle(_ run: AgentRunPresentation) -> String {
        if let failure = run.failureMessage, run.state == .failed { return failure }
        switch run.state {
        case .waitingForApproval: return "Approval needed"
        case .waitingForUser: return "Waiting for your answer"
        case .waitingForReconciliation: return "External result uncertain"
        case .paused: return "Run paused"
        case .waitingForForeground: return "Run backgrounded"
        case .generating, .synthesizing: return "Generating…"
        case .executingTools: return "Running tools…"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        default: return "Agent run in progress"
        }
    }

    private func activitySubtitle(_ run: AgentRunPresentation) -> String {
        if !run.provisionalText.isEmpty { return "Typing…" }
        switch run.blockingReason {
        case .approval(let id): return "Approve or deny below"
        case .userInput: return "Reply below"
        case .reconciliation: return "Confirm what happened"
        case .paused: return "Resume to continue"
        case .foreground: return "Return to the app to resume"
        case .modelResource: return "Waiting for the model"
        case nil: return "\(run.steps.count) step\(run.steps.count == 1 ? "" : "s")"
        }
    }

    // MARK: Steps

    private func stepsList(_ run: AgentRunPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(run.steps) { step in
                HStack(alignment: .top, spacing: Theme.Space.xs) {
                    stepIcon(step)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    private func stepIcon(_ step: AgentRunStep) -> some View {
        Group {
            switch step.status {
            case .succeeded: Image(systemName: "checkmark").foregroundStyle(Theme.fitGreen)
            case .failed: Image(systemName: "xmark").foregroundStyle(Theme.danger)
            case .uncertain: Image(systemName: "questionmark").foregroundStyle(Theme.fitAmber)
            case .waiting: Image(systemName: "hourglass").foregroundStyle(Theme.accent)
            case .running: ProgressView().controlSize(.mini).tint(Theme.accent)
            case .pending: Image(systemName: "circle.dashed").foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.caption2)
        .frame(width: 14, height: 14)
    }

    // MARK: Approval card

    private func approvalCard(_ approval: AgentApprovalCard, run: AgentRunPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("Approve \(approval.toolName)?", systemImage: approval.isExternalWrite ? "externaldrive.fill.badge.exclamationmark" : "eye.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let destination = approval.destination {
                row("Destination", destination)
            }
            if !approval.preview.isEmpty {
                Text(approval.preview)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.sm)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .textSelection(.enabled)
            }
            if !approval.dataCategories.isEmpty {
                row("Data", approval.dataCategories.joined(separator: ", "))
            }
            HStack(spacing: Theme.Space.sm) {
                Button {
                    Task { await store.decideApproval(conversationID: conversationID, approvalID: approval.approvalID, approved: false) }
                } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioButtonStyle(.secondary))
                .accessibilityLabel("Deny \(approval.toolName)")

                Button {
                    Task { await store.decideApproval(conversationID: conversationID, approvalID: approval.approvalID, approved: true) }
                } label: {
                    Text(approval.isExternalWrite ? "Approve once" : "Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioButtonStyle(.primary))
                .accessibilityLabel("Approve \(approval.toolName)")
            }
            Text("Approving authorizes only this exact prepared operation. Denying continues without it.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.sm)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    // MARK: User input

    private func userInputCard(_ request: UserInputRequest, run: AgentRunPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("The agent needs an answer", systemImage: "questionmark.bubble.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(request.prompt)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            HStack(spacing: Theme.Space.sm) {
                TextField("Your answer…", text: $userResponse, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .lineLimit(1 ... 4)
                    .padding(Theme.Space.sm)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .onSubmit { sendResponse() }
                Button(action: sendResponse) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(userResponse.isEmpty ? Theme.textTertiary : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(userResponse.isEmpty)
                .accessibilityLabel("Send answer to agent")
            }
        }
        .padding(Theme.Space.sm)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private func sendResponse() {
        let text = userResponse
        userResponse = ""
        Task { await store.respond(conversationID: conversationID, text: text) }
    }

    // MARK: Reconciliation

    private func reconciliationCard(_ reason: AgentBlockingReason, run: AgentRunPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("Did the external action happen?", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("The tool stopped before its outcome could be proven. The run will not replay it. Tell the agent what actually happened.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            if case .reconciliation(let invocationID) = reason {
                HStack(spacing: Theme.Space.sm) {
                    Button("It succeeded") {
                        Task { await store.reconcile(conversationID: conversationID, invocationID: invocationID, decision: .succeeded) }
                    }
                    .buttonStyle(StudioButtonStyle(.primary))
                    Button("It failed") {
                        Task { await store.reconcile(conversationID: conversationID, invocationID: invocationID, decision: .failed) }
                    }
                    .buttonStyle(StudioButtonStyle(.secondary))
                    Button("Abandon", role: .destructive) {
                        Task { await store.reconcile(conversationID: conversationID, invocationID: invocationID, decision: .abandoned) }
                    }
                    .buttonStyle(StudioButtonStyle(.secondary))
                }
            }
        }
        .padding(Theme.Space.sm)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    // MARK: Provisional output

    private func provisionalOutput(_ run: AgentRunPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if !run.reasoningText.isEmpty {
                Text("Reasoning…")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(run.provisionalText.isEmpty ? "Working…" : run.provisionalText)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
            Label("Not final — the agent is still working.", systemImage: "ellipsis.circle")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.sm)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ run: AgentRunPresentation) -> some View {
        if run.isActive || run.isResumable || run.state == .waitingForApproval
            || run.state == .waitingForUser || run.state == .waitingForReconciliation
        {
            HStack(spacing: Theme.Space.sm) {
                if run.isActive {
                    Button {
                        Task { await store.pause(conversationID: conversationID) }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(StudioButtonStyle(.secondary))
                    .accessibilityLabel("Pause run")
                    Button {
                        Task { await store.cancel(conversationID: conversationID) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(StudioButtonStyle(.secondary))
                    .accessibilityLabel("Stop run")
                } else if run.isResumable {
                    Button {
                        Task { await store.resume(conversationID: conversationID) }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(StudioButtonStyle(.primary))
                    .accessibilityLabel("Resume run")
                }
                if !run.isTerminal && run.state != .waitingForReconciliation {
                    Button(role: .destructive) {
                        Task { await store.cancel(conversationID: conversationID) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(StudioButtonStyle(.secondary))
                    .accessibilityLabel("Stop run")
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
