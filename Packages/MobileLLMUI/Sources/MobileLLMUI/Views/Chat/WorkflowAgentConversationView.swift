// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts
import AgentRuntime

/// A task's continuing conversation. The original workflow result keeps its historical identity.
struct WorkflowAgentConversationView: View {
    let store: WorkflowStore
    let workflowID: UUID
    let call: DynamicWorkflowChildPresentation
    let conversationID: UUID
    @State private var session: AgentSessionView?
    @State private var observer: AgentRunStore?
    @State private var draft = ""
    @State private var sending = false
    @State private var pendingMessageID: MessageID?
    @State private var error: String?
    @State private var refreshGeneration = 0
    @State private var copiedRunID: AgentRunID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool

    private var workflow: DynamicWorkflowPresentation? { store.summary(workflowID: workflowID)?.dynamic }
    private var parentFinished: Bool {
        guard let state = workflow?.state else { return false }
        return [.completed, .failed, .cancelled].contains(state)
    }
    private var canInteract: Bool {
        parentFinished || (workflow?.state == .running && store.executingWorkflowIDs.contains(workflowID))
    }
    private var current: AgentSessionTurnView? { session?.turns.last }
    private var followup: Bool { (session?.turns.count ?? 0) > 1 }
    private var needsResume: Bool {
        guard let current else { return false }
        guard let state = current.status?.state else { return true }
        if state == .paused || state == .waitingForForeground { return true }
        if state.isTerminal { return session?.snapshot.pendingTurns.isEmpty == false }
        return !current.isRunningInThisProcess && ![.waitingForApproval, .waitingForUser, .waitingForReconciliation].contains(state)
    }
    private var refreshKey: String { "\(refreshGeneration)-\(workflow?.state.rawValue ?? "none")" }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                if let brief = call.task?.instruction {
                    DisclosureGroup("Original assignment") {
                        Text(brief).font(.callout).foregroundStyle(Theme.textSecondary).padding(.top, 8)
                    }.studioCard()
                }
                if let session {
                    if let answer = session.turns.first?.answer {
                        answerCard(answer, title: "Original result", id: session.snapshot.seedRunID)
                    }
                    ForEach(session.messages) { message in
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            HStack {
                                Text(message.sender == nil ? "You" : "Coordinating agent").font(.callout.weight(.semibold))
                                Spacer()
                                Text(message.included ? "Included in a request" : "Saved · Pending")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Text(message.text).textSelection(.enabled)
                                .accessibilityIdentifier("workflow.session.message.\(message.id)")
                        }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
                        if let turn = session.turns.dropFirst().first(where: { $0.inputIDs.last == message.id }) {
                            if let answer = turn.answer {
                                answerCard(answer, title: "Agent", id: turn.runID)
                            } else if let failure = turn.status?.failure?.safeMessage {
                                Text(failure).font(.callout).foregroundStyle(Theme.danger)
                            }
                        }
                    }
                    if let current, current.status?.state.isTerminal != true {
                        HStack(spacing: Theme.Space.sm) {
                            if current.isRunningInThisProcess { ProgressView() }
                            Text(needsResume ? "Resume to continue" : stateTitle(current.status?.state))
                                .font(.callout).foregroundStyle(Theme.textSecondary)
                        }.accessibilityIdentifier("workflow.session.state")
                    }
                } else if error == nil {
                    ProgressView("Reading agent conversation…")
                }
                if let message = error ?? observer?.recoveryError {
                    Text(message).font(.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
                        .accessibilityIdentifier("workflow.session.error")
                }
                Color.clear.frame(height: 1).id("session.latest")
            }
            .frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading)
            .padding(Theme.Space.lg).frame(maxWidth: .infinity)
        }
        .onChange(of: session?.messages.count ?? 0) { _, _ in scrollToLatest(proxy) }
        .onChange(of: current?.answer) { _, _ in scrollToLatest(proxy) }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("workflow.session.conversation")
        .background(Theme.bg).foregroundStyle(Theme.textPrimary)
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationTitle(call.taskTitle)
        .toolbar {
            if current?.status?.state.isTerminal == false, canInteract, !needsResume {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(followup ? "Pause agent" : "Pause workflow", systemImage: "pause") {
                            Task {
                                if followup { await observer?.pause(conversationID: conversationID) }
                                else { await store.pauseDynamic(workflowID: workflowID) }
                                refreshGeneration += 1
                            }
                        }
                        Button(followup ? "Stop agent" : "Stop workflow", systemImage: "stop", role: .destructive) {
                            Task {
                                if followup { await observer?.cancel(conversationID: conversationID) }
                                else { await store.stopDynamic(workflowID: workflowID) }
                                refreshGeneration += 1
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Agent controls")
                }
            }
        }
        .task(id: refreshKey) { await refreshUntilIdle() }
        .onDisappear { observer?.discard(conversationID: conversationID); observer = nil }
    }

    private var inputBar: some View {
        VStack(spacing: Theme.Space.sm) {
            if !canInteract, let workflow {
                Text("Resume the workflow to continue this agent.").font(.callout)
                WorkflowActionBar(store: store, workflowID: workflowID, state: workflow.state,
                                  attached: store.executingWorkflowIDs.contains(workflowID))
            } else if needsResume, parentFinished {
                Button("Resume agent", systemImage: "play.fill") {
                    Task {
                        do { try await store.resumeTaskSession(workflowID: workflowID, callID: call.callID); error = nil }
                        catch { self.error = error.localizedDescription }
                        refreshGeneration += 1
                    }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("workflow.session.resume")
            }
            if canInteract, let observer {
                if !followup, observer.presentation(for: conversationID)?.state == .waitingForReconciliation {
                    Text("Review the uncertain action from the workflow controls.").font(.callout)
                } else {
                    AgentDockedBar(store: observer, conversationID: conversationID)
                }
            }
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                TextField("Message this agent…", text: $draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).padding(12)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
                    .focused($inputFocused).disabled(sending || !canInteract)
                    .accessibilityIdentifier("workflow.session.input")
                    .onChange(of: draft) { _, _ in if !sending { pendingMessageID = nil } }
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }.buttonStyle(.borderedProminent).clipShape(Circle())
                    .disabled(sending || !canInteract || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send to agent").accessibilityIdentifier("workflow.session.send")
            }
            Text(parentFinished ? "Continue with this agent’s model and tools." : "Updates reach a working agent at its next step. Finished tasks queue a follow-up.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }.padding().background(Theme.surface)
    }

    private func answerCard(_ text: String, title: String, id: AgentRunID) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Button(copiedRunID == id ? "Copied" : "Copy", systemImage: copiedRunID == id ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(text)
                    copiedRunID = id
                }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
            MarkdownMessage(text: text).textSelection(.enabled)
                .accessibilityIdentifier("workflow.session.answer.\(id)")
        }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo("session.latest", anchor: .bottom)
            }
        }
    }

    private func send() {
        guard !sending, canInteract else { return }
        let text = draft
        let id = pendingMessageID ?? MessageID(rawValue: UUID())
        pendingMessageID = id
        sending = true
        inputFocused = false
        Task {
            defer { sending = false; refreshGeneration += 1 }
            do {
                try await store.sendTaskMessage(workflowID: workflowID, callID: call.callID, id: id, text: text)
                draft = ""
                pendingMessageID = nil
                error = nil
            } catch {
                self.error = error.localizedDescription
                if let saved = try? await store.taskSession(workflowID: workflowID, callID: call.callID),
                   saved.messages.contains(where: { $0.id == id }) {
                    session = saved
                    draft = ""
                    pendingMessageID = nil
                }
            }
        }
    }

    private func refreshUntilIdle() async {
        while !Task.isCancelled {
            do {
                let value = try await store.taskSession(workflowID: workflowID, callID: call.callID)
                guard !Task.isCancelled else { return }
                session = value
                if canInteract, let current, current.status?.state.isTerminal == false,
                   observer?.presentation(for: conversationID)?.runID != current.runID {
                    observer?.discard(conversationID: conversationID)
                    observer = try await store.observeTask(workflowID: workflowID, callID: call.callID)
                }
                if needsResume || (current?.status?.state.isTerminal == true && (parentFinished || value.snapshot.pendingTurns.isEmpty)) { return }
                try await Task.sleep(for: .milliseconds(750))
            } catch is CancellationError { return }
              catch { if !Task.isCancelled { self.error = error.localizedDescription }; return }
        }
    }

    private func stateTitle(_ state: AgentRunState?) -> String {
        switch state {
        case .waitingForApproval: "Approval needed"
        case .waitingForUser: "Reply needed"
        case .waitingForReconciliation: "Action needs review"
        case .waitingForModel: "Waiting for the model"
        case .executingTools: "Using tools"
        case .preparing, .created: "Preparing"
        case .paused, .pausing, .waitingForForeground: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        default: "Working"
        }
    }
}
