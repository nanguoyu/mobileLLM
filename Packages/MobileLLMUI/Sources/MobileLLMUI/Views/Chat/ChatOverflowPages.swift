// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

/// A consistent "this capability exists but is not enabled / has no data yet" page (spec §20:
/// unimplemented capabilities get a real page with explicit empty-state UX, never a missing item).
struct CapabilityEmptyState: View {
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
                                    .listRowBackground(Theme.surface)
                            }
                        }
                    }
                    if !resumableRuns.isEmpty {
                        Section("Paused") {
                            ForEach(resumableRuns, id: \.runID) { run in
                                runRow(run)
                                    .listRowBackground(Theme.surface)
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
                                .listRowBackground(Theme.surface)
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
/// tap; long-press / swipe renames or deletes a tag everywhere; a new tag can be created inline.
struct ProjectTagsSheet: View {
    let chat: ChatStore
    let conversationID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @State private var renamingTag: String?
    @State private var renameText = ""
    @State private var deletingTag: String?

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
                            .listRowBackground(Theme.surface)
                    } else {
                        ForEach(chat.allProjectTags, id: \.self) { tag in
                            tagRow(tag)
                                .listRowBackground(Theme.surface)
                                .contextMenu {
                                    Button {
                                        renameText = tag
                                        renamingTag = tag
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        deletingTag = tag
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                #if os(iOS)
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { deletingTag = tag }
                                    Button("Rename") {
                                        renameText = tag
                                        renamingTag = tag
                                    }
                                    .tint(Theme.accent)
                                }
                                #endif
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
                    .listRowBackground(Theme.surface)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Add to Project")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename tag", isPresented: Binding(
                get: { renamingTag != nil },
                set: { if !$0 { renamingTag = nil } }
            )) {
                TextField("Tag name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingTag = nil }
                Button("Save") {
                    if let renamingTag {
                        chat.renameProjectTag(renamingTag, to: renameText)
                    }
                    renamingTag = nil
                }
            }
            .confirmationDialog(
                "Delete this tag everywhere?",
                isPresented: Binding(
                    get: { deletingTag != nil },
                    set: { if !$0 { deletingTag = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let deletingTag {
                        chat.deleteProjectTag(deletingTag)
                    }
                    deletingTag = nil
                }
                Button("Cancel", role: .cancel) { deletingTag = nil }
            } message: {
                Text("The tag is removed from every conversation that uses it.")
            }
        }
    }

    private func tagRow(_ tag: String) -> some View {
        let isSelected = selected.contains(tag.lowercased())
        return Button {
            chat.toggleProjectTag(tag, on: conversationID)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tag)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(chat.projectTagCount(tag)) chat\(chat.projectTagCount(tag) == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
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
