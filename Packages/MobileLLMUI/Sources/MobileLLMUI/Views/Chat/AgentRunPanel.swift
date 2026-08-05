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

/// The agent interaction surface inside one chat thread, modeled on Codex/Claude Code: a compact
/// activity row showing the CURRENT action, expanding into one row per tool call (each row shows the
/// exact arguments and result and expands for the full detail). Approvals, questions, and
/// reconciliation live in ``AgentDockedBar`` above the composer, not inside the thread.
struct AgentRunPanel: View {
    let store: AgentRunStore
    let conversationID: UUID
    @State private var expanded = false

    private var run: AgentRunPresentation? { store.presentation(for: conversationID) }

    var body: some View {
        if let run {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                activityRow(run)
                if expanded {
                    stepsList(run)
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
                    if !activitySubtitle(run).isEmpty {
                        Text(activitySubtitle(run))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
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
            case .completed where run.terminalReason == .completedWithFailures:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.fitAmber)
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

    /// The activity row is the CURRENT action, not a run-lifecycle label: "Using web search",
    /// "Typing…", "Approval needed", "Completed". Codex/Claude Code never surface pipeline stages.
    private func activityTitle(_ run: AgentRunPresentation) -> String {
        if let failure = run.failureMessage,
           run.state == .failed || run.terminalReason == .completedWithFailures
        {
            return failure
        }
        switch run.state {
        case .waitingForApproval: return "Approval needed"
        case .waitingForUser: return "Waiting for your answer"
        case .waitingForReconciliation: return "External result uncertain"
        case .paused: return "Run paused"
        case .waitingForForeground: return "Run backgrounded"
        case .completed where run.terminalReason == .completedWithFailures: return "Completed with issues"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        default:
            if let tool = runningToolStep(run) {
                return "Using \(AgentRunStore.readableToolName(tool.title))"
            }
            if !run.provisionalText.isEmpty { return "Typing…" }
            return "Working…"
        }
    }

    private func activitySubtitle(_ run: AgentRunPresentation) -> String {
        if let tool = runningToolStep(run) {
            let preview = AgentRunStore.actionPreview(
                toolName: tool.title,
                argumentsJSON: tool.detail
            )
            if !preview.isEmpty { return preview }
        }
        if !run.isTerminal, !run.provisionalText.isEmpty { return "Typing…" }
        switch run.blockingReason {
        case .approval: return "Approve or deny below"
        case .userInput: return "Reply below"
        case .reconciliation: return "Confirm below"
        case .paused: return "Resume to continue"
        case .foreground: return "Return to the app to resume"
        case .modelResource: return "Waiting for the model"
        case nil:
            if run.isTerminal, !run.steps.isEmpty {
                return "\(run.steps.count) action\(run.steps.count == 1 ? "" : "s")"
            }
            return ""
        }
    }

    private func runningToolStep(_ run: AgentRunPresentation) -> AgentRunStep? {
        run.steps.last {
            $0.kind == .toolCall && ($0.status == .running || $0.status == .pending)
        }
    }

    // MARK: Steps

    private func stepsList(_ run: AgentRunPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(run.steps) { step in
                AgentRunStepRow(step: step, terminal: run.isTerminal)
            }
        }
        .padding(.top, Theme.Space.xs)
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
                    // Stop lives on the composer's Send↔Stop button; duplicating it here would
                    // present two identical controls for one action.
                } else if run.isResumable {
                    Button {
                        Task { await store.resume(conversationID: conversationID) }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(StudioButtonStyle(.primary))
                    .accessibilityLabel("Resume run")
                }
            }
        }
    }
}

/// One expandable action row. Collapsed: icon + readable name + one-line preview of the concrete
/// arguments ("Search: current year"). Expanded: the full arguments and the tool's result.
private struct AgentRunStepRow: View {
    let step: AgentRunStep
    let terminal: Bool
    @State private var expanded = false

    private var isTool: Bool { step.kind == .toolCall }

    private var title: String {
        guard isTool else { return step.title }
        let name = AgentRunStore.readableToolName(step.title)
        return (step.status == .running || step.status == .pending) ? "Using \(name)" : name
    }

    private var preview: String {
        if isTool {
            return AgentRunStore.actionPreview(toolName: step.title, argumentsJSON: step.detail)
        }
        return step.detail
    }

    private var hasExpandedContent: Bool {
        !step.detail.isEmpty || !(step.resultText ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(Motion.spring) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: Theme.Space.xs) {
                    stepIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        if !preview.isEmpty {
                            Text(preview)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(expanded ? nil : 1)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .opacity(hasExpandedContent ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasExpandedContent)
            .accessibilityLabel(title)
            .accessibilityHint(hasExpandedContent ? "Show details" : "")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !step.detail.isEmpty {
                        detailBlock(isTool ? "Arguments" : "Details", step.detail)
                    }
                    if let resultText = step.resultText, !resultText.isEmpty {
                        detailBlock("Result", resultText)
                    }
                }
                .padding(.leading, Theme.Space.lg + Theme.Space.xs)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 3)
    }

    private var stepIcon: some View {
        Group {
            switch step.status {
            case .succeeded: Image(systemName: "checkmark").foregroundStyle(Theme.fitGreen)
            case .failed: Image(systemName: "xmark").foregroundStyle(Theme.danger)
            case .uncertain: Image(systemName: "questionmark").foregroundStyle(Theme.fitAmber)
            case .waiting: Image(systemName: "hourglass").foregroundStyle(Theme.accent)
            case .running where terminal:
                // A committed terminal event settles every in-flight step; spinners after "Completed"
                // would contradict the visible outcome.
                Image(systemName: "checkmark").foregroundStyle(Theme.fitGreen)
            case .running: ProgressView().controlSize(.mini).tint(Theme.accent)
            case .pending: Image(systemName: "circle.dashed").foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.caption2)
        .frame(width: 14, height: 14)
    }

    private func detailBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.sm)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
    }
}
