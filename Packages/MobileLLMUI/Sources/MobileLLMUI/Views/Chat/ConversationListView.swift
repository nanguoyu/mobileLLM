// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// The conversation list (DESIGN §4): recency-grouped (Pinned / Today / …), searchable, with pin +
/// swipe-delete-with-undo. Selecting a row activates it; `onSelect` lets iOS push the thread.
struct ConversationListView: View {
    @Bindable var chat: ChatStore
    var onSelect: (UUID) -> Void = { _ in }

    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    private var groups: [(Format.RecencyGroup, [Conversation])] {
        let filtered = filteredConversations()
        return Format.RecencyGroup.allCases.compactMap { group in
            let items = filtered.filter { Format.group(for: $0.indexEntry) == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    var body: some View {
        Group {
            if chat.conversations.isEmpty {
                ChatPlaceholder(icon: "bubble.left.and.text.bubble.right",
                                title: "No conversations yet",
                                message: "Start a new chat — everything stays on your device.",
                                actionTitle: "New chat", action: { startNew() })
            } else {
                VStack(spacing: 0) {
                    searchField
                    list
                }
                .background(Theme.bg)
            }
        }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil },
                                                   set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { chat.rename(renaming.id, to: renameText) }
                renaming = nil
            }
        }
    }

    /// The app's warm search field (replaces the system `.searchable` chrome so search matches the
    /// ink-wash surface instead of a stark platform bar).
    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Theme.textTertiary)
            TextField("Search chats", text: $query)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background(Theme.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .padding(.horizontal, Theme.Space.lg).padding(.top, Theme.Space.sm).padding(.bottom, Theme.Space.xs)
    }

    private var list: some View {
        List {
            ForEach(groups, id: \.0) { group, items in
                Section {
                    ForEach(items) { convo in
                        row(convo)
                    }
                } header: {
                    Text(group.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
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
        .overlay(alignment: .bottom) {
            if filteredConversations().isEmpty && !query.isEmpty {
                Text("No chats match “\(query)”.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary).padding()
            }
        }
    }

    private func row(_ convo: Conversation) -> some View {
        Button { chat.select(convo.id); onSelect(convo.id) } label: {
            HStack(spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if convo.pinned {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.accent)
                        }
                        Text(convo.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    Text(convo.preview)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.sm)
                Text(Format.relative(convo.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(convo.id == chat.activeID ? Theme.accentSoft : Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { chat.delete(convo.id) } label: { Label("Delete", systemImage: "trash") }
                .tint(Theme.danger)
        }
        .swipeActions(edge: .leading) {
            Button { chat.togglePin(convo.id) } label: {
                Label(convo.pinned ? "Unpin" : "Pin", systemImage: convo.pinned ? "pin.slash" : "pin")
            }
            .tint(Theme.accent)
        }
        .contextMenu {
            Button { chat.togglePin(convo.id) } label: {
                Label(convo.pinned ? "Unpin" : "Pin", systemImage: convo.pinned ? "pin.slash" : "pin")
            }
            Button { beginRename(convo) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { chat.delete(convo.id) } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityLabel(convo.title)
        .accessibilityValue(convo.preview)
    }

    // MARK: Actions

    private func startNew() { chat.newConversation() }

    private func beginRename(_ convo: Conversation) {
        renameText = convo.title
        renaming = convo
    }

    private func filteredConversations() -> [Conversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return chat.conversations }
        return chat.conversations.filter { convo in
            convo.title.lowercased().contains(needle)
                || convo.messages.contains { $0.answer.lowercased().contains(needle) }
        }
    }
}
