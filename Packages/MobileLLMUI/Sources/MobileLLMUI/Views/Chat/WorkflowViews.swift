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
                Text(record.title.isEmpty ? "Workflow" : "workflow: \(record.title)")
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
        switch record.status {
        case .running:
            "Running · \(record.aggregated.subagentCount) subagent"
                + (record.aggregated.subagentCount == 1 ? "" : "s")
        case .completed:
            "Completed · \(record.aggregated.subagentCount) subagents · "
                + Format.shortCount(record.aggregated.inputTokens + record.aggregated.outputTokens)
                + " tokens"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }
}

/// The workflow summary page (spec §20): a Claude Code-style tree of phases and their subagents,
/// with status, elapsed time, tokens, and tool-call counts. Shows nothing when no workflow exists.
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
                    title: "No workflow is running",
                    message: "Workflows appear here while they run, with each phase's status, elapsed "
                        + "time, tokens, and tool calls. The Workflow menu entry enables itself only "
                        + "while a workflow is active in this conversation."
                )
            } else {
                List {
                    ForEach(workflows) { workflow in
                        Section {
                            workflowHeader(workflow)
                            ForEach(workflow.phases) { phase in
                                WorkflowPhaseRow(phase: phase)
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
        }
        .navigationTitle("Workflow")
    }

    private func workflowHeader(_ workflow: WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workflow.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("\(workflow.status.label) · \(workflow.aggregated.subagentCount) subagents · "
                 + Format.shortCount(
                    workflow.aggregated.inputTokens + workflow.aggregated.outputTokens
                 ) + " tokens · \(workflow.aggregated.toolInvocationCount) tool calls")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 2)
    }
}

/// One phase node in the workflow tree.
struct WorkflowPhaseRow: View {
    let phase: WorkflowPhaseRecord

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
            Text("\(phase.status.label) · \(phase.childRunIDs.count) subagents · "
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
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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
