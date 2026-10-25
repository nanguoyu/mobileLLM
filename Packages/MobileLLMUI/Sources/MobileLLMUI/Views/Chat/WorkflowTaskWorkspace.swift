// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

struct WorkflowTaskWorkspace: View {
    let workflow: WorkflowSummary
    let dynamic: DynamicWorkflowPresentation
    let store: WorkflowStore?
    @State private var destination: Destination?

    private enum Destination: Identifiable {
        case task(WorkflowAgentCallID), goalTask(String), updateGoal, result, planning
        var id: String {
            switch self {
            case .task(let id): id.rawValue.uuidString
            case .goalTask(let id): "goal-task-" + id
            case .updateGoal: "update-goal"
            case .result: "result"
            case .planning: "planning"
            }
        }
    }

    private var calls: [DynamicWorkflowChildPresentation] { dynamic.childCalls ?? [] }
    private var tasks: [WorkflowTaskGroup] { WorkflowDisplay.tasks(calls) }
    private var attention: [DynamicWorkflowChildPresentation] { calls.filter(WorkflowDisplay.needsAttention) }
    private var stageTasks: [WorkflowTaskGroup] { tasks.filter { !WorkflowDisplay.needsAttention($0.latest) } }
    private var attached: Bool { store?.executingWorkflowIDs.contains(workflow.id) == true }
    private var phases: [String] {
        stageTasks.reduce(into: []) { values, task in
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
            if let goal = dynamic.goal { WorkflowGoalInfo(goal: goal) }
            if !attention.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Needs your attention").font(.headline)
                    ForEach(attention) { call in
                        WorkflowTaskCard(task: WorkflowTaskGroup(id: call.callID.rawValue.uuidString, calls: [call]),
                                         calls: calls, state: dynamic.state, attached: attached) { destination = .task(call.callID) }
                    }
                }
            }
            if tasks.isEmpty && (dynamic.goal?.tasks.isEmpty ?? true) {
                Label(emptyTaskMessage,
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout).foregroundStyle(Theme.textSecondary).studioCard()
            }
            if let goal = dynamic.goal {
                WorkflowGoalTasks(goal: goal, dynamic: dynamic, attached: attached,
                    excluding: Set(attention.compactMap { $0.task?.taskID })) { destination = .goalTask($0) }
            } else {
                ForEach(phases, id: \.self) { phase in
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(WorkflowDisplay.name(phase)).font(.headline).foregroundStyle(Theme.textPrimary)
                        ForEach(stageTasks.filter { ($0.latest.phase ?? "Tasks") == phase }) { task in
                            WorkflowTaskCard(task: task, calls: calls, state: dynamic.state, attached: attached) {
                                destination = .task(task.latest.callID)
                            }
                        }
                    }
                }
            }
            WorkflowDiagnostics(dynamic: dynamic)
        }
        .sheet(item: $destination) { target in
            NavigationStack {
                Group {
                    switch target {
                    case .task(let id):
                        WorkflowTaskDetailView(store: store, workflowID: workflow.id, callID: id)
                    case .goalTask(let id):
                        WorkflowGoalTaskDetail(store: store, workflowID: workflow.id, taskID: id)
                    case .updateGoal:
                        if let store { WorkflowGoalUpdateView(store: store, workflowID: workflow.id) }
                    case .planning:
                        WorkflowPlanningInspector(store: store, workflowID: workflow.id)
                    case .result:
                        ScrollView {
                            MarkdownMessage(text: workflow.finalAnswer ?? "No result was recorded.")
                                .textSelection(.enabled)
                                .frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading)
                                .padding(Theme.Space.lg).frame(maxWidth: .infinity)
                        }.background(Theme.bg).navigationTitle("Final result")
                    }
                }
                .toolbar {
                    if target.id != "update-goal" {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } }
                    }
                }
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
            HStack(spacing: 8) {
                Image(systemName: stateSymbol).accessibilityHidden(true)
                Text(stateText).accessibilityIdentifier("workflow.state")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(dynamic.state == .completed ? Theme.fitGreen : Theme.accent)
            if !tasks.isEmpty || !(dynamic.goal?.tasks.isEmpty ?? true) {
                Text(dynamic.goal.map(WorkflowGoalDisplay.summary) ?? WorkflowDisplay.summary(calls))
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("workflow.task.count")
            }
            WorkflowElapsedLabel(start: workflow.startTime, end: workflow.endTime)
            if let latest = dynamic.goal?.amendments.last {
                Text("Latest update: " + latest.text).font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .accessibilityIdentifier("workflow.goal.latest-update")
            }
            if (dynamic.goal?.pendingInputs.count ?? 0) > 0 {
                Label("Agents have saved updates to include", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption).foregroundStyle(Theme.fitAmber)
            }
            if let goal = dynamic.goal, goal.state != .budgetExhausted, store?.goalUpdateHandler != nil,
               ![.completed, .failed, .cancelled, .pausing].contains(dynamic.state) {
                Button("Update goal", systemImage: "square.and.pencil") { destination = .updateGoal }
                    .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("workflow.goal.update")
            }
            if dynamic.state == .generatingCandidate, dynamic.planning != nil {
                Button("Review planning", systemImage: "person.crop.circle.badge.questionmark") { destination = .planning }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("workflow.planning.review")
            }
            if workflow.finalAnswer != nil {
                Button("View final result", systemImage: "doc.text") { destination = .result }
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

    private var stateText: String {
        if dynamic.state == .generatingCandidate, let planning = dynamic.planning {
            return WorkflowDisplay.planningStatus(planning.state)
        }
        if dynamic.state == .paused, dynamic.goal?.state == .budgetExhausted { return "Limit reached" }
        if dynamic.state == .paused, dynamic.goal?.state == .blocked { return "Needs attention" }
        return dynamic.state.displayLabel(attached: attached)
    }

    private var emptyTaskMessage: String {
        if let planning = dynamic.planning,
           [.waitingForApproval, .waitingForUser, .waitingForReconciliation].contains(planning.state) {
            return "Review the planning request to continue."
        }
        return switch dynamic.state {
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
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        ForEach(calls) { call in
                            Text("\(call.ordinal). \(call.isCoordinator ? "Coordinator" : call.taskTitle) · attempt \(call.attempt) · \(call.status.label)")
                                .font(.callout).foregroundStyle(Theme.textSecondary)
                                .accessibilityIdentifier("workflow.agent.call")
                        }
                    }.padding(.top, Theme.Space.sm)
                } label: {
                    Text("Call history")
                        .accessibilityValue("\(calls.count) calls")
                        .accessibilityIdentifier("workflow.call.history")
                }
                if !dynamic.logs.isEmpty {
                    DisclosureGroup("Activity log") {
                        Text(dynamic.logs.suffix(20).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let source = dynamic.source {
                    DisclosureGroup("Workflow source") {
                        ScrollView([.horizontal, .vertical]) {
                            Text(source).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        .frame(height: 300)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Workflow source")
                        .accessibilityValue(source)
                        .accessibilityIdentifier("workflow.source")
                    }
                }
            }.padding(.top, Theme.Space.sm)
        }
        .font(.callout).foregroundStyle(Theme.textSecondary).studioCard()
    }
}
