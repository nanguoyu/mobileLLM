// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

enum WorkflowGoalDisplay {
    static func summary(_ goal: WorkflowGoalPresentation) -> String {
        let completed = goal.tasks.filter { $0.state == .completed }.count
        return "\(goal.tasks.count) \(goal.tasks.count == 1 ? "task" : "tasks") · \(completed) completed"
    }

    static func title(_ task: WorkflowTaskNode) -> String {
        WorkflowDisplay.taskName(id: task.id, agent: task.agent)
    }

    static func call(_ task: WorkflowTaskNode, in calls: [DynamicWorkflowChildPresentation]) -> DynamicWorkflowChildPresentation? {
        if let id = task.activeCallID, let current = calls.first(where: { $0.callID == id }) { return current }
        return calls.last { $0.task?.taskID == task.id }
    }

    static func levels(_ goal: WorkflowGoalPresentation) -> [String: Int] {
        let nodes = Dictionary(goal.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let results = Dictionary(goal.results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resultLevels: [String: Int] = [:]
        func resultLevel(_ id: String, path: Set<String>) -> Int {
            if let level = resultLevels[id] { return level }
            guard !path.contains(id), let result = results[id] else { return 0 }
            let level = (result.inputArtifactIDs.map { resultLevel($0, path: path.union([id])) }.max() ?? -1) + 1
            resultLevels[id] = level
            return level
        }
        var levels: [String: Int] = [:]
        func level(_ id: String, path: Set<String>) -> Int {
            if let known = levels[id] { return known }
            guard !path.contains(id), let task = nodes[id] else { return 0 }
            let dependencies = task.dependencies.map { level($0, path: path.union([id])) + 1 }
            let pinned = (task.artifactInputs ?? []).map { resultLevel($0, path: []) + 1 }
            let value = (dependencies + pinned).max() ?? 0
            levels[id] = value
            return value
        }
        for task in goal.tasks { _ = level(task.id, path: []) }
        return levels
    }

    static func status(_ task: WorkflowTaskNode, goal: WorkflowGoalPresentation,
                       dynamic: DynamicWorkflowPresentation, attached: Bool) -> String {
        if task.state == .completed { return "Completed" }
        if let call = call(task, in: dynamic.childCalls ?? []), task.activeCallID == call.callID {
            if call.status == .completed { return "Result ready" }
            return call.statusText(workflowState: dynamic.state, attached: attached)
        }
        if task.state == .failed { return "Needs work" }
        if [.completed, .cancelled, .failed].contains(dynamic.state) { return "Not started" }
        if dynamic.state == .paused || dynamic.state == .waitingForForeground { return "Paused" }
        if !attached && dynamic.state == .running { return "Needs resume" }
        let blocked = task.dependencies.contains { id in goal.tasks.first(where: { $0.id == id })?.state != .completed }
        if blocked { return "Waiting for inputs" }
        return task.state == .needsReview ? "Ready for review" : "Ready"
    }
}

struct WorkflowGoalTasks: View {
    let goal: WorkflowGoalPresentation
    let dynamic: DynamicWorkflowPresentation
    let attached: Bool
    let excluding: Set<String>
    let open: (String) -> Void

    var body: some View {
        let levels = WorkflowGoalDisplay.levels(goal)
        let stages = Set(goal.tasks.filter { !excluding.contains($0.id) }.map { levels[$0.id, default: 0] }).sorted()
        ForEach(stages, id: \.self) { stage in
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.sm) {
                    Text("\(stage + 1)").font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.surface2, in: Capsule()).accessibilityHidden(true)
                    Text("Stage \(stage + 1)").font(.headline)
                    Spacer()
                    Text(stage == 0 ? "Independent work" : "Uses earlier results").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                ForEach(goal.tasks.filter { !excluding.contains($0.id) && levels[$0.id, default: 0] == stage }) { task in
                    taskCard(task)
                }
            }
        }
    }

    private func taskCard(_ task: WorkflowTaskNode) -> some View {
        let status = WorkflowGoalDisplay.status(task, goal: goal, dynamic: dynamic, attached: attached)
        let call = WorkflowGoalDisplay.call(task, in: dynamic.childCalls ?? [])
        let active = task.activeCallID == call?.callID ? call : nil
        return Button { open(task.id) } label: {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(WorkflowGoalDisplay.title(task)).font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
                if let active, active.status != .completed {
                    WorkflowTaskStateLabel(call: active, state: dynamic.state, attached: attached)
                } else {
                    Label(status, systemImage: symbol(task))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(task.state == .completed ? Theme.fitGreen : task.state == .failed ? Theme.danger : Theme.textSecondary)
                }
                Text(task.instruction).font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(2)
                if !task.required { Text("Optional").font(.caption).foregroundStyle(Theme.textTertiary) }
                if task.id != task.agent {
                    Label(WorkflowDisplay.name(task.agent), systemImage: "person.crop.circle")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                let dependencies = task.dependencies.compactMap { id in goal.tasks.first { $0.id == id } }.map(WorkflowGoalDisplay.title)
                if !dependencies.isEmpty {
                    Label("Uses: " + dependencies.joined(separator: ", "), systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if !(task.artifactInputs ?? []).isEmpty {
                    Label("Includes saved feedback", systemImage: "doc.on.doc")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if let failure = task.failure { Text(WorkflowDisplay.issue(failure)).font(.caption).foregroundStyle(Theme.danger).lineLimit(2) }
            }
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).studioCard(Theme.Space.lg)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(WorkflowGoalDisplay.title(task)). \(status)")
        .accessibilityValue(String(task.instruction.prefix(160)))
        .accessibilityHint("View assignment, dependencies and saved results")
        .accessibilityIdentifier("workflow.task.\(task.id)")
    }

    private func symbol(_ task: WorkflowTaskNode) -> String {
        switch task.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .needsReview: "arrow.triangle.2.circlepath"
        case .running: "circle.dotted"
        case .pending: "clock"
        }
    }
}

struct WorkflowGoalInfo: View {
    let goal: WorkflowGoalPresentation
    @State private var showBudget = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let reason = goal.reason, goal.state != .completed, goal.state != .active {
                Label(WorkflowDisplay.issue(reason), systemImage: goal.state == .budgetExhausted ? "gauge.with.dots.needle.100percent" : "pause.circle")
                    .font(.callout).foregroundStyle(Theme.fitAmber).textSelection(.enabled).studioCard()
                    .accessibilityIdentifier("workflow.goal.reason")
            }
            DisclosureGroup("Goal and updates") {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text(goal.objective).textSelection(.enabled)
                    ForEach(Array(goal.amendments.enumerated()), id: \.element.id) { index, amendment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Update \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            Text(amendment.text).textSelection(.enabled)
                        }
                    }
                }.font(.callout).padding(.top, Theme.Space.sm)
            }.font(.callout.weight(.medium)).studioCard()
            DisclosureGroup(isExpanded: $showBudget) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    budgetRow("Model requests", .modelAttempts, id: "workflow.budget.models")
                    budgetRow("Tool calls", .toolInvocations, id: "workflow.budget.tools")
                    Text("Includes planning and recorded work from active agents.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }.padding(.top, Theme.Space.sm)
            } label: {
                HStack {
                    Text("Budget").font(.callout.weight(.medium))
                    Spacer()
                    Text("\(remaining(.modelAttempts)) requests left").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }.studioCard().accessibilityIdentifier("workflow.goal.budget")
        }
        .onChange(of: goal.state, initial: true) { _, state in if state == .budgetExhausted { showBudget = true } }
    }

    private func remaining(_ dimension: BudgetDimension) -> UInt64 {
        let limit = goal.budget.limits[dimension], used = goal.usage.quantities[dimension]
        return limit > used ? limit - used : 0
    }

    private func budgetRow(_ title: String, _ dimension: BudgetDimension, id: String) -> some View {
        LabeledContent(title, value: "\(goal.usage.quantities[dimension]) / \(goal.budget.limits[dimension])")
            .font(.callout).monospacedDigit().accessibilityIdentifier(id)
    }
}

struct WorkflowGoalTaskDetail: View {
    let store: WorkflowStore?
    let workflowID: UUID
    let taskID: String
    private var dynamic: DynamicWorkflowPresentation? { store?.summary(workflowID: workflowID)?.dynamic }
    private var task: WorkflowTaskNode? { dynamic?.goal?.tasks.first { $0.id == taskID } }

    var body: some View {
        if let task, let dynamic {
            if (task.activeCallID != nil || [.completed, .failed].contains(task.state)),
               let call = WorkflowGoalDisplay.call(task, in: dynamic.childCalls ?? []) {
                WorkflowTaskDetailView(store: store, workflowID: workflowID, callID: call.callID)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        Text(task.instruction).textSelection(.enabled)
                        Label("Assigned to " + WorkflowDisplay.name(task.agent), systemImage: "person.crop.circle")
                            .font(.callout).foregroundStyle(Theme.textSecondary)
                        if let goal = dynamic.goal {
                            Text(WorkflowGoalDisplay.status(task, goal: goal, dynamic: dynamic,
                                attached: store?.executingWorkflowIDs.contains(workflowID) == true))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                            if !task.dependencies.isEmpty {
                                Text("Waiting for").font(.headline)
                                ForEach(task.dependencies, id: \.self) { id in
                                    NavigationLink {
                                        WorkflowGoalTaskDetail(store: store, workflowID: workflowID, taskID: id)
                                    } label: {
                                        Label(goal.tasks.first(where: { $0.id == id }).map(WorkflowGoalDisplay.title) ?? id,
                                              systemImage: "arrow.turn.down.right").frame(minHeight: 44)
                                    }
                                }
                            }
                            let earlier = (dynamic.childCalls ?? []).filter { $0.task?.taskID == task.id }
                            if !earlier.isEmpty {
                                Text("Previous attempts").font(.headline)
                                ForEach(earlier) { call in
                                    NavigationLink {
                                        WorkflowTaskDetailView(store: store, workflowID: workflowID, callID: call.callID)
                                    } label: {
                                        Label("Call \(call.ordinal) · \(call.status.label)", systemImage: "clock.arrow.circlepath")
                                            .frame(minHeight: 44)
                                    }
                                }
                            }
                        }
                    }.frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading).padding(Theme.Space.lg).frame(maxWidth: .infinity)
                }.background(Theme.bg).navigationTitle(WorkflowGoalDisplay.title(task))
            }
        } else { Text("This task record is unavailable.").foregroundStyle(Theme.textSecondary) }
    }
}

struct WorkflowGoalUpdateView: View {
    let store: WorkflowStore
    let workflowID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var messageID = MessageID()
    @State private var submittedText: String?
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var dynamic: DynamicWorkflowPresentation? { store.summary(workflowID: workflowID)?.dynamic }
    private var shouldResume: Bool {
        guard let dynamic, dynamic.goal?.state != .budgetExhausted else { return false }
        return [.paused, .waitingForForeground].contains(dynamic.state)
            || (dynamic.state == .running && !store.executingWorkflowIDs.contains(workflowID))
    }

    var body: some View {
        Form {
            Section("What should change?") {
                TextEditor(text: $text).frame(minHeight: 150).focused($focused).accessibilityLabel("Goal update")
                    .accessibilityIdentifier("workflow.goal.input")
                Text("Your update is saved and delivered to active agents at their next step.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if text.utf8.count > 16_384 { Text("This update is too long. Shorten it before sending.").foregroundStyle(Theme.danger) }
            if let error { Text(error).foregroundStyle(Theme.danger).accessibilityIdentifier("workflow.goal.error") }
            if let last = dynamic?.goal?.amendments.last {
                Section("Latest saved update") { Text(last.text).font(.callout).textSelection(.enabled) }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Update goal")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(sending) }
            ToolbarItem(placement: .confirmationAction) {
                Button(sending ? "Saving…" : shouldResume ? "Save and resume" : "Send update") { Task { await send() } }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 16_384)
                    .accessibilityIdentifier("workflow.goal.send")
            }
        }
        .interactiveDismissDisabled(sending)
        .task { focused = true }
    }

    @MainActor private func send() async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let submittedText, submittedText != value { messageID = MessageID() }
        submittedText = value
        sending = true; error = nil
        defer { sending = false }
        do {
            try await store.updateGoal(workflowID: workflowID, id: messageID, text: value, resumeAfterSave: shouldResume)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
