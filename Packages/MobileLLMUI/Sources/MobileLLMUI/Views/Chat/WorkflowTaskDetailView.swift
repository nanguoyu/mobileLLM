// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

struct WorkflowTaskDetailView: View {
    let store: WorkflowStore?
    let workflowID: UUID
    let callID: WorkflowAgentCallID
    @State private var result: String?
    @State private var readError: String?
    @State private var loading = false
    @State private var copied = false
    @State private var observer: AgentRunStore?
    @State private var observationError: String?

    private var workflow: WorkflowSummary? { store?.summary(workflowID: workflowID) }
    private var dynamic: DynamicWorkflowPresentation? { workflow?.dynamic }
    private var calls: [DynamicWorkflowChildPresentation] { dynamic?.childCalls ?? [] }
    private var call: DynamicWorkflowChildPresentation? { calls.first { $0.callID == callID } }
    private var attached: Bool { store?.executingWorkflowIDs.contains(workflowID) == true }
    private var canInteract: Bool { attached && dynamic?.state == .running }
    private var observationKey: String { "\(call?.handleID?.rawValue.uuidString ?? "none")-\(canInteract)" }
    private var history: [DynamicWorkflowChildPresentation] {
        guard let call else { return [] }
        return calls.filter {
            if let taskID = call.task?.taskID { return $0.task?.taskID == taskID }
            return $0.ordinal == call.ordinal
        }.sorted { $0.ordinal == $1.ordinal ? $0.attempt < $1.attempt : $0.ordinal < $1.ordinal }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                if let call {
                    summary(call)
                    if let error = observationError ?? observer?.recoveryError {
                        Text(error).font(.callout).foregroundStyle(Theme.danger)
                    }
                    if let observer, let conversationID = workflow?.conversationID,
                       let run = observer.presentation(for: conversationID),
                       [.paused, .waitingForForeground].contains(run.state) {
                        AgentRunPanel(store: observer, conversationID: conversationID)
                    }
                    output(call)
                    inputs(call)
                    assignment(call)
                    if history.count > 1 {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Text("Task history").font(.headline)
                            ForEach(history) { item in
                                if item.callID == callID {
                                    Text("Call \(item.ordinal), attempt \(item.attempt) · Current view")
                                        .font(.callout).foregroundStyle(Theme.textSecondary)
                                } else {
                                    NavigationLink {
                                        WorkflowTaskDetailView(store: store, workflowID: workflowID, callID: item.callID)
                                    } label: {
                                        Label("Call \(item.ordinal), attempt \(item.attempt) · \(item.status.label)", systemImage: item.status.symbol)
                                            .font(.callout).frame(minHeight: 44)
                                    }
                                }
                            }
                        }.studioCard()
                    }
                    if canRestart(call) {
                        Button("Restart from this task", systemImage: "arrow.clockwise", action: restart)
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(store?.actioningWorkflowIDs.contains(workflowID) == true)
                            .accessibilityIdentifier("workflow.agent.restart")
                    }
                } else {
                    Text("This task record is no longer available.").foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading)
            .padding(Theme.Space.lg).frame(maxWidth: .infinity)
        }
        .background(Theme.bg).foregroundStyle(Theme.textPrimary)
        .safeAreaInset(edge: .bottom) {
            if let dynamic, dynamic.reconciliationCallID == callID {
                WorkflowActionBar(store: store, workflowID: workflowID,
                                  state: .waitingForReconciliation, attached: attached).padding()
            } else if let dynamic, !attached,
                      [.paused, .waitingForForeground, .running].contains(dynamic.state),
                      call?.status == .submitted || call?.status == .prepared {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resume the workflow to continue this task.").font(.callout)
                    WorkflowActionBar(store: store, workflowID: workflowID, state: dynamic.state, attached: false)
                }.padding().background(Theme.surface)
            } else if canInteract, let observer, let conversationID = workflow?.conversationID {
                if observer.presentation(for: conversationID)?.state == .waitingForReconciliation {
                    Text("Waiting for the workflow to record the uncertain action.").font(.callout).padding()
                } else {
                    AgentDockedBar(store: observer, conversationID: conversationID)
                }
            }
        }
        .navigationTitle(call?.taskTitle ?? "Task")
        .task(id: call?.hasResult == true) { await loadResult() }
        .task(id: observationKey) { await observe() }
        .onDisappear(perform: detach)
        .accessibilityIdentifier("workflow.task.detail")
    }

    private func summary(_ call: DynamicWorkflowChildPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            WorkflowTaskStateLabel(call: call, state: dynamic?.state ?? .failed, attached: attached)
            if let submitted = call.submittedAt {
                WorkflowElapsedLabel(start: submitted.date, end: call.settledAt?.date)
            }
            if let usage = call.usage {
                Text("\(Format.shortCount(Int64(clamping: usage.quantities[.inputTokens]))) input tokens · \(Format.shortCount(Int64(clamping: usage.quantities[.outputTokens]))) output tokens · \(usage.quantities[.toolInvocations]) tool calls")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if let detail = call.detail {
                Text(detail).font(.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
    }

    private func assignment(_ call: DynamicWorkflowChildPresentation) -> some View {
        DisclosureGroup("Assignment") {
            Text(call.task?.instruction ?? (call.isCoordinator ? "Coordinates this workflow using the recorded task results."
                                           : "This older run did not record a separate task brief."))
                .font(.body).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                .padding(.top, Theme.Space.sm)
        }.font(.callout.weight(.medium)).studioCard()
    }

    private func inputs(_ call: DynamicWorkflowChildPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Input results").font(.headline)
            if let task = call.task {
                if task.inputArtifactIDs.isEmpty {
                    Text("This task started independently.").font(.callout).foregroundStyle(Theme.textSecondary)
                }
                let sources = WorkflowDisplay.inputs(for: call, in: calls)
                ForEach(task.inputArtifactIDs, id: \.self) { id in
                    if let source = sources.first(where: { $0.task?.outputArtifactID == id }) {
                        NavigationLink {
                            WorkflowTaskDetailView(store: store, workflowID: workflowID, callID: source.callID)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(source.taskTitle, systemImage: "arrow.turn.down.right").font(.callout.weight(.medium))
                                Text("Call \(source.ordinal) · \(source.status.label)").font(.caption).foregroundStyle(Theme.textSecondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("workflow.input.\(id)")
                    } else {
                        Text("\(id) · Source record unavailable").font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                Text("Input links were not recorded by this version.").font(.callout).foregroundStyle(Theme.textSecondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
    }

    private func output(_ call: DynamicWorkflowChildPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Result").font(.headline)
            if let result {
                Button(copied ? "Copied" : "Copy result", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(result)
                    copied = true
                }.buttonStyle(.bordered).controlSize(.large)
                MarkdownMessage(text: result).textSelection(.enabled)
                    .accessibilityIdentifier("workflow.task.result")
            } else if loading {
                ProgressView("Reading saved result…")
            } else if let readError {
                Text(readError).font(.callout).foregroundStyle(Theme.danger)
                Button("Try reading again") { Task { await loadResult() } }
                    .buttonStyle(.bordered).controlSize(.large)
            } else {
                Text([.prepared, .submitted].contains(call.status)
                     ? "A result will appear here when this task completes." : "No public result was recorded.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
    }

    private func canRestart(_ call: DynamicWorkflowChildPresentation) -> Bool {
        guard dynamic?.state == .paused || dynamic?.state == .waitingForReconciliation,
              [.failed, .unavailable, .stopped, .uncertain].contains(call.status)
        else { return false }
        return !calls.contains { $0.ordinal == call.ordinal && $0.attempt > call.attempt }
    }

    private func restart() {
        Task { await store?.restartDynamic(workflowID: workflowID, callID: callID) }
    }

    private func loadResult() async {
        guard call?.hasResult == true, let store else { return }
        loading = true
        readError = nil
        defer { loading = false }
        do { result = try await store.result(workflowID: workflowID, callID: callID) }
        catch { readError = "Could not read the saved result: \(error.localizedDescription)" }
    }

    private func observe() async {
        guard canInteract else { detach(); return }
        guard observer == nil, let call, [.submitted, .uncertain].contains(call.status),
              call.handleID != nil, let store else { return }
        do {
            let value = try await store.observeTask(workflowID: workflowID, callID: callID)
            if Task.isCancelled {
                if let conversationID = workflow?.conversationID { value?.discard(conversationID: conversationID) }
            } else { observer = value }
        } catch { observationError = "Task actions could not connect: \(error.localizedDescription)" }
    }

    private func detach() {
        if let conversationID = workflow?.conversationID { observer?.discard(conversationID: conversationID) }
        observer = nil
    }
}
