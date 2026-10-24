// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

/// Uses the same run inspector and commands as task details; it never displays coordinator notes.
struct WorkflowPlanningInspector: View {
    let store: WorkflowStore?
    let workflowID: UUID
    @State private var observer: AgentRunStore?
    @State private var error: String?
    private var workflow: WorkflowSummary? { store?.summary(workflowID: workflowID) }
    private var planning: WorkflowPlanningPresentation? { workflow?.dynamic?.planning }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text(planning.map { WorkflowDisplay.planningStatus($0.state) } ?? "Planning finished")
                    .font(.title2.weight(.semibold))
                Text("The coordinator prepares the tasks and their handoffs. Review its access requests here.")
                    .font(.body).foregroundStyle(Theme.textSecondary)
                if let observer, let conversationID = workflow?.conversationID,
                   let run = observer.presentation(for: conversationID), let state = run.state, !state.isTerminal {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        if [.paused, .waitingForForeground].contains(state) {
                            Button("Resume planning", systemImage: "play.fill") {
                                Task { await observer.resume(conversationID: conversationID) }
                            }
                        } else if ![.waitingForApproval, .waitingForUser, .waitingForReconciliation, .pausing].contains(state) {
                            Button("Pause planning", systemImage: "pause.fill") {
                                Task { await observer.pause(conversationID: conversationID) }
                            }
                        }
                        Button("Stop planning", role: .destructive) {
                            Task { await observer.cancel(conversationID: conversationID) }
                        }
                    }.buttonStyle(.bordered).controlSize(.large)
                }
                if let message = error ?? observer?.recoveryError {
                    Text(message).font(.callout).foregroundStyle(Theme.danger)
                }
            }
            .frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading)
            .padding(Theme.Space.lg).frame(maxWidth: .infinity)
        }
        .background(Theme.bg).foregroundStyle(Theme.textPrimary)
        .navigationTitle("Planning")
        .safeAreaInset(edge: .bottom) {
            if let observer, let conversationID = workflow?.conversationID {
                AgentDockedBar(store: observer, conversationID: conversationID)
            }
        }
        .task { await connect() }
        .onDisappear {
            if let conversationID = workflow?.conversationID { observer?.discard(conversationID: conversationID) }
            observer = nil
        }
    }

    private func connect() async {
        do {
            let value = try await store?.observePlanning(workflowID: workflowID)
            if Task.isCancelled {
                if let conversationID = workflow?.conversationID { value?.discard(conversationID: conversationID) }
            } else { observer = value }
        } catch { self.error = "Planning actions could not connect: \(error.localizedDescription)" }
    }
}
