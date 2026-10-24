// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

struct WorkflowTaskWorkspace: View {
    let workflow: WorkflowSummary
    let dynamic: DynamicWorkflowPresentation
    let store: WorkflowStore?
    @State private var selectedCall: DynamicWorkflowChildPresentation?
    @State private var showsResult = false

    private var calls: [DynamicWorkflowChildPresentation] { dynamic.childCalls ?? [] }
    private var tasks: [WorkflowTaskGroup] { WorkflowDisplay.tasks(calls) }
    private var attached: Bool { store?.executingWorkflowIDs.contains(workflow.id) == true }
    private var phases: [String] {
        tasks.reduce(into: []) { values, task in
            let phase = task.latest.phase ?? "Tasks"
            if !values.contains(phase) { values.append(phase) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            overview
            if let failure = dynamic.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger).font(.callout).studioCard()
                    .accessibilityIdentifier("workflow.failure")
            }
            WorkflowActionBar(store: store, workflowID: workflow.id, state: dynamic.state, attached: attached)
            if tasks.isEmpty {
                Label(emptyTaskMessage,
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout).foregroundStyle(Theme.textSecondary).studioCard()
            }
            ForEach(phases, id: \.self) { phase in
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(WorkflowDisplay.name(phase)).font(.headline).foregroundStyle(Theme.textPrimary)
                    ForEach(tasks.filter { ($0.latest.phase ?? "Tasks") == phase }) { task in
                        WorkflowTaskCard(task: task, calls: calls, state: dynamic.state, attached: attached) {
                            selectedCall = task.latest
                        }
                    }
                }
            }
            WorkflowDiagnostics(dynamic: dynamic)
        }
        .sheet(item: $selectedCall) { call in
            NavigationStack {
                WorkflowTaskDetailView(store: store, workflowID: workflow.id, callID: call.callID)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedCall = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 540, minHeight: 600)
            #endif
        }
        .sheet(isPresented: $showsResult) {
            NavigationStack {
                ScrollView {
                    MarkdownMessage(text: workflow.finalAnswer ?? "No result was recorded.")
                        .textSelection(.enabled)
                        .frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading)
                        .padding(Theme.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .background(Theme.bg).navigationTitle("Final result")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsResult = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 540, minHeight: 600)
            #endif
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(workflow.title).font(.title2.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Label(dynamic.state.displayLabel(attached: attached), systemImage: stateSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(dynamic.state == .completed ? Theme.fitGreen : Theme.accent)
                .accessibilityIdentifier("workflow.state")
            if !tasks.isEmpty {
                Text(WorkflowDisplay.summary(calls))
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("workflow.task.count")
            }
            WorkflowElapsedLabel(start: workflow.startTime, end: workflow.endTime)
            if workflow.finalAnswer != nil {
                Button("View final result", systemImage: "doc.text") { showsResult = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("workflow.final.result")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).studioCard(Theme.Space.lg)
    }

    private var stateSymbol: String {
        switch dynamic.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused, .waitingForForeground: "pause.circle"
        case .cancelled: "stop.circle"
        default: "circle.dotted"
        }
    }

    private var emptyTaskMessage: String {
        switch dynamic.state {
        case .completed: "This task finished without delegated work."
        case .failed, .cancelled: "No delegated tasks were recorded."
        case .paused, .waitingForForeground: "The workflow paused before delegating work."
        case .running where !attached: "Resume this workflow to continue planning."
        default: "The coordinator is preparing the next work."
        }
    }
}

private struct WorkflowTaskCard: View {
    let task: WorkflowTaskGroup
    let calls: [DynamicWorkflowChildPresentation]
    let state: DynamicWorkflowPresentationState
    let attached: Bool
    let open: () -> Void

    private var call: DynamicWorkflowChildPresentation { task.latest }
    private var status: String { call.statusText(workflowState: state, attached: attached) }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.title).font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
                WorkflowTaskStateLabel(call: call, state: state, attached: attached)
                if let instruction = call.task?.instruction {
                    Text(instruction).font(.callout).foregroundStyle(Theme.textSecondary)
                        .lineLimit(3).multilineTextAlignment(.leading)
                }
                if let task = call.task, !task.inputArtifactIDs.isEmpty {
                    let inputs = WorkflowDisplay.inputs(for: call, in: calls)
                    Label("Uses: " + (inputs.isEmpty ? "Recorded earlier results" : inputs.map(\.taskTitle).joined(separator: ", ")),
                          systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if call.task != nil {
                    Label("Independent task", systemImage: "square.stack.3d.up")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if let detail = call.detail {
                    Text(detail).font(.callout).foregroundStyle(Theme.danger).lineLimit(3)
                }
                if task.calls.count > 1 {
                    Text("\(task.calls.count) recorded calls · View history")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioCard(Theme.Space.lg)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(task.title). \(status)")
        .accessibilityValue(String((call.task?.instruction ?? "").prefix(160)))
        .accessibilityHint("View task inputs and result")
        .accessibilityIdentifier("workflow.task.\(task.id)")
    }
}

struct WorkflowTaskStateLabel: View {
    let call: DynamicWorkflowChildPresentation
    let state: DynamicWorkflowPresentationState
    let attached: Bool

    private var busy: Bool {
        attached && state == .running && call.status == .submitted
            && [.generating, .executingTools, .validatingAction, .synthesizing].contains(call.executionState)
    }

    var body: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small).accessibilityHidden(true) }
            else { Image(systemName: call.status.symbol).accessibilityHidden(true) }
            Text(call.statusText(workflowState: state, attached: attached))
        }
        .font(.subheadline.weight(.medium)).foregroundStyle(call.status.color)
        .accessibilityElement(children: .combine)
    }
}

struct WorkflowElapsedLabel: View {
    let start: Date
    let end: Date?
    var body: some View {
        Group {
            if let end { elapsed(end) }
            else { TimelineView(.periodic(from: .now, by: 1)) { elapsed($0.date) } }
        }.font(.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
    }
    private func elapsed(_ date: Date) -> Text {
        Text("Elapsed \(Format.duration(max(0, date.timeIntervalSince(start))))")
    }
}

private struct WorkflowDiagnostics: View {
    let dynamic: DynamicWorkflowPresentation
    var body: some View {
        DisclosureGroup("Execution details") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                let calls = dynamic.childCalls ?? []
                Text("\(calls.count) calls · \(calls.filter(\.isCoordinator).count) coordination calls")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                ForEach(calls.filter(\.isCoordinator)) { call in
                    Label("Coordination \(call.ordinal) · \(call.status.label)", systemImage: call.status.symbol)
                        .font(.callout).foregroundStyle(Theme.textSecondary)
                }
                if !dynamic.logs.isEmpty {
                    DisclosureGroup("Activity log") {
                        Text(dynamic.logs.suffix(20).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let source = dynamic.source {
                    DisclosureGroup("Workflow source") {
                        ScrollView(.horizontal) {
                            Text(source).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }.padding(.top, Theme.Space.sm)
        }
        .font(.callout).foregroundStyle(Theme.textSecondary).studioCard()
    }
}
