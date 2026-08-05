// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

/// A consistent "this capability exists but is not enabled / has no data yet" page (spec §20:
/// unimplemented capabilities get a real page with explicit empty-state UX, never a missing item).
private struct CapabilityEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

/// Workflow summary (spec §20/§23): the live Claude Code-style tree of running subagents. The top-right
/// entry is disabled while nothing is running; this page is the destination that entry opens.
struct WorkflowSummaryPage: View {
    var body: some View {
        CapabilityEmptyState(
            icon: "point.3.connected.trianglepath.dotted",
            title: "No workflow is running",
            message: "Workflows appear here while they run, with each subagent's status, elapsed time, "
                + "tokens, and tool calls. The Workflow menu entry enables itself only while a workflow "
                + "is active in this conversation."
        )
        .navigationTitle("Workflow")
    }
}

/// Files (spec §20 reserved section): the page exists now; content lands with the sandbox runtime.
struct FilesPage: View {
    var body: some View {
        CapabilityEmptyState(
            icon: "folder",
            title: "Files",
            message: "File access is not enabled yet. When the sandbox runtime lands, this page will "
                + "browse the conversation's workspace and artifacts."
        )
        .navigationTitle("Files")
    }
}

/// Terminal (spec §20 reserved section): the page exists now; content lands with the sandbox runtime.
struct TerminalPage: View {
    var body: some View {
        CapabilityEmptyState(
            icon: "terminal",
            title: "Terminal",
            message: "The shell terminal is not enabled yet. When the sandbox runtime lands, this page "
                + "will run commands inside the conversation's sandbox."
        )
        .navigationTitle("Terminal")
    }
}

/// Background tasks (spec §19.2/§20): active, waiting, paused, and recoverable agent runs for this
/// app. Read-only status with Pause/Resume for the runs the store can command.
struct BackgroundTasksPage: View {
    let chat: ChatStore
    let store: AgentRunStore?

    private var liveRuns: [AgentRunPresentation] {
        guard let store else { return [] }
        return store.runs.values
            .filter { $0.isActive || $0.isWaiting }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var resumableRuns: [AgentRunPresentation] {
        guard let store else { return [] }
        return store.runs.values
            .filter { $0.isResumable }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if liveRuns.isEmpty, resumableRuns.isEmpty, store?.recoverableRuns.isEmpty ?? true {
                CapabilityEmptyState(
                    icon: "timer",
                    title: "No background tasks",
                    message: "Active, waiting, paused, and recoverable agent runs appear here."
                )
            } else {
                List {
                    if !liveRuns.isEmpty {
                        Section("Active & waiting") {
                            ForEach(liveRuns, id: \.runID) { run in
                                runRow(run)
                            }
                        }
                    }
                    if !resumableRuns.isEmpty {
                        Section("Paused") {
                            ForEach(resumableRuns, id: \.runID) { run in
                                runRow(run)
                            }
                        }
                    }
                    if let store, !store.recoverableRuns.isEmpty {
                        Section("Recoverable") {
                            ForEach(store.recoverableRuns) { run in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(for: run.conversationID))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("\(run.state.stateLabel) · \(Format.relative(run.updatedAt))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.sidebar)
                #endif
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
        }
        .navigationTitle("Background tasks")
    }

    private func runRow(_ run: AgentRunPresentation) -> some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: run.conversationID))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(run.stateLabel) · \(Format.relative(run.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if run.isActive {
                Button {
                    Task { await store?.pause(conversationID: run.conversationID) }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(StudioButtonStyle(.secondary))
                .labelStyle(.iconOnly)
                .accessibilityLabel("Pause \(title(for: run.conversationID))")
            } else if run.isResumable {
                Button {
                    Task { await store?.resume(conversationID: run.conversationID) }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(StudioButtonStyle(.primary))
                .labelStyle(.iconOnly)
                .accessibilityLabel("Resume \(title(for: run.conversationID))")
            }
        }
        .padding(.vertical, 2)
    }

    private func title(for conversationID: UUID) -> String {
        chat.conversations.first(where: { $0.id == conversationID })?.title ?? "Conversation"
    }
}

/// Project tag picker (spec §20: Project is pure tag grouping, many-to-many). Existing tags toggle on
/// tap; a new tag can be created inline and is selected immediately.
struct ProjectTagsSheet: View {
    let chat: ChatStore
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""

    private var selected: Set<String> {
        Set(chat.projectTags(for: conversationID).map { $0.lowercased() })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Tags") {
                    if chat.allProjectTags.isEmpty {
                        Text("No tags yet — create the first one below.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(chat.allProjectTags, id: \.self) { tag in
                            Button {
                                chat.toggleProjectTag(tag, on: conversationID)
                            } label: {
                                HStack {
                                    Text(tag)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    if selected.contains(tag.lowercased()) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("New tag") {
                    HStack {
                        TextField("Tag name", text: $newTag)
                            .textFieldStyle(.plain)
                        Button("Add") { addTag() }
                            .disabled(normalizedNewTag.isEmpty)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.sidebar)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Add to Project")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var normalizedNewTag: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTag() {
        let tag = normalizedNewTag
        guard !tag.isEmpty else { return }
        var tags = chat.projectTags(for: conversationID)
        if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
            chat.setProjectTags(tags, for: conversationID)
        }
        newTag = ""
    }
}

private extension AgentRunPresentation {
    var stateLabel: String {
        state?.stateLabel ?? "In progress"
    }
}

private extension AgentRunState {
    var stateLabel: String {
        switch self {
        case .waitingForApproval: "Waiting for approval"
        case .waitingForUser: "Waiting for your answer"
        case .waitingForReconciliation: "Needs review"
        case .paused: "Paused"
        case .waitingForForeground: "Backgrounded"
        case .generating, .synthesizing, .executingTools: "Working…"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        default: "In progress"
        }
    }
}
