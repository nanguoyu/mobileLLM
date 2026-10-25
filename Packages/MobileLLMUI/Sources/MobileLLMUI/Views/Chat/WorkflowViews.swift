// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

/// The message-anchored workflow record row (spec §20/§23): a live Claude Code-style record below
/// its initiating message, clickable to the summary page in its completed state.
struct WorkflowMessageRow: View {
    let record: WorkflowMessageRecord

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: statusSymbol)
                .font(.subheadline)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title.isEmpty ? "Workflow" : record.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workflow: \(record.title)")
        .accessibilityValue(statusText)
        .accessibilityIdentifier("workflow.row")
    }

    private var statusSymbol: String {
        switch record.status {
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .running: Theme.accent
        case .completed: Theme.fitGreen
        case .failed: Theme.danger
        case .cancelled: Theme.textTertiary
        }
    }

    private var statusText: String {
        if let dynamic = record.dynamic {
            let state = dynamic.state == .generatingCandidate
                ? dynamic.planning.map { WorkflowDisplay.planningStatus($0.state) } ?? "Planning"
                : dynamic.state.displayLabel(attached: record.isAttachedInCurrentProcess == true)
            var parts = [state]
            if let goal = dynamic.goal, !goal.tasks.isEmpty {
                parts.append(WorkflowGoalDisplay.summary(goal))
            } else if !WorkflowDisplay.tasks(dynamic.childCalls ?? []).isEmpty {
                parts.append(WorkflowDisplay.summary(dynamic.childCalls ?? []))
            }
            return parts.joined(separator: " · ")
        }
        switch record.status {
        case .running:
            var parts = ["Running"]
            if record.totalPhaseCount > 0 {
                let current = min(record.completedPhaseCount + 1, record.totalPhaseCount)
                parts.append("phase \(current)/\(record.totalPhaseCount)")
            }
            parts.append(
                "\(record.completedSubagentCount)/\(record.totalSubagentCount) subagents"
            )
            if record.aggregated.inputTokens + record.aggregated.outputTokens > 0
                || record.aggregated.toolInvocationCount > 0
            {
                parts.append(
                    Format.shortCount(
                        record.aggregated.inputTokens + record.aggregated.outputTokens
                    ) + " tokens · "
                        + "\(Format.shortCount(record.aggregated.toolInvocationCount)) tool calls"
                )
            }
            return parts.joined(separator: " · ")
        case .completed:
            return "Completed · \(record.completedPhaseCount)/\(record.totalPhaseCount) phases · "
                + "\(record.completedSubagentCount)/\(record.totalSubagentCount) subagents · "
                + Format.shortCount(record.aggregated.inputTokens + record.aggregated.outputTokens)
                + " tokens · \(Format.shortCount(record.aggregated.toolInvocationCount)) tool calls"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// The unified workflow page (spec §20/§34): legacy staged records retain their phase tree while
/// Dynamic Workflows expose the exact source, runtime activity, and durable run controls.
struct WorkflowSummaryPage: View {
    let store: WorkflowStore?
    let conversationID: UUID?

    private var workflows: [WorkflowSummary] {
        guard let store else { return [] }
        return store.workflows.values
            .filter { conversationID == nil || $0.conversationID == conversationID }
            .sorted { $0.startTime > $1.startTime }
    }

    var body: some View {
        Group {
            if workflows.isEmpty {
                CapabilityEmptyState(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Your agent tasks",
                    message: "In a chat, choose Work with agents from the + menu and describe your goal. Completed tasks remain available here."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.xxl) {
                        if let error = store?.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger).studioCard()
                                .accessibilityIdentifier("workflow.error")
                        }
                        ForEach(workflows) { workflow in
                            if let dynamic = workflow.dynamic {
                                WorkflowTaskWorkspace(workflow: workflow, dynamic: dynamic, store: store)
                            } else {
                                VStack(alignment: .leading, spacing: Theme.Space.md) {
                                    workflowHeader(workflow)
                                    ForEach(workflow.phases) { phase in
                                        WorkflowPhaseRow(
                                            phase: phase,
                                            totalChildren: workflow.plan?.phases.first(where: { $0.sequence == phase.sequence })?.childInstructions.count ?? phase.childRunIDs.count,
                                            childInstructions: workflow.plan?.phases.first(where: { $0.sequence == phase.sequence })?.childInstructions ?? []
                                        )
                                    }
                                }.studioCard()
                            }
                        }
                    }
                    .frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading)
                    .padding(Theme.Space.lg).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle("Agent tasks")
    }

    private func workflowHeader(_ workflow: WorkflowSummary) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(workflow.dynamic.map {
                    $0.state.displayLabel(
                        attached: store?.executingWorkflowIDs.contains(workflow.id) == true
                    )
                } ?? workflow.status.label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("workflow.state")
            }
            Spacer(minLength: 0)
            if workflow.dynamic == nil && workflow.status == .running
                && store?.executingWorkflowIDs.contains(workflow.id) != true
            {
                Button {
                    Task { await store?.resume(workflowID: workflow.id) }
                } label: {
                    if store?.resumingWorkflowIDs.contains(workflow.id) == true {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Resume", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store?.resumeHandler == nil
                    || store?.resumingWorkflowIDs.contains(workflow.id) == true)
                .accessibilityIdentifier("workflow.resume")
            }
        }
        .padding(.vertical, 2)
    }

}

/// One phase node in the workflow tree.
struct WorkflowPhaseRow: View {
    let phase: WorkflowPhaseRecord
    let totalChildren: Int
    let childInstructions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: phase.status.symbol)
                    .font(.caption)
                    .foregroundStyle(phase.status.color)
                    .accessibilityHidden(true)
                Text(phase.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let endTime = phase.endTime, let startTime = phase.startTime {
                    Text(Format.duration(endTime.timeIntervalSince(startTime)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text("\(phase.status.label) · \(phase.completedChildCount)/\(totalChildren) subagents · "
                 + Format.shortCount(phase.stats.inputTokens + phase.stats.outputTokens)
                 + " tokens · \(phase.stats.toolInvocationCount) tool calls")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            if !phase.acceptanceCriteria.isEmpty {
                Text("Accept: \(phase.acceptanceCriteria)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            if !childInstructions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(childInstructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: childStatus(index).symbol)
                                .font(.caption2)
                                .foregroundStyle(childStatus(index).color)
                                .accessibilityHidden(true)
                            Text(instruction)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func childStatus(_ index: Int) -> (symbol: String, color: Color) {
        if index < phase.completedChildCount {
            return ("checkmark.circle.fill", Theme.fitGreen)
        }
        if index == phase.completedChildCount, phase.status == .running {
            return ("arrow.triangle.2.circlepath", Theme.accent)
        }
        return ("circle", Theme.textTertiary)
    }
}

private extension WorkflowStatus {
    var label: String {
        switch self {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

private extension WorkflowPhaseStatus {
    var label: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: Theme.textTertiary
        case .running: Theme.accent
        case .waiting: Theme.textSecondary
        case .completed: Theme.fitGreen
        case .failed: Theme.danger
        case .cancelled: Theme.textTertiary
        }
    }
}

extension DynamicWorkflowPresentationState {
    var label: String { displayLabel(attached: true) }

    func displayLabel(attached: Bool) -> String {
        switch self {
        case .generatingCandidate: "Planning"
        case .waitingForLaunchApproval: "Ready to run"
        case .queued: "Approved — ready to start"
        case .running: attached ? "Running" : "Interrupted — Resume to continue"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .waitingForForeground: "Waiting for foreground"
        case .waitingForReconciliation: "Needs your review"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Denied or stopped"
        }
    }
}

extension DynamicWorkflowChildStatus {
    var label: String {
        switch self {
        case .prepared: "Prepared"
        case .submitted: "Submitted"
        case .completed: "Completed"
        case .failed: "Failed"
        case .unavailable: "Unavailable"
        case .stopped: "Stopped"
        case .uncertain: "Needs reconciliation"
        }
    }

    var symbol: String {
        switch self {
        case .prepared: "circle"
        case .submitted: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle.fill"
        case .uncertain: "questionmark.diamond.fill"
        }
    }

    var color: Color {
        switch self {
        case .prepared: Theme.textTertiary
        case .submitted: Theme.accent
        case .completed: Theme.fitGreen
        case .failed, .unavailable, .uncertain: Theme.danger
        case .stopped: Theme.textSecondary
        }
    }
}
