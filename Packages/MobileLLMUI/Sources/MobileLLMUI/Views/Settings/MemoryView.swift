// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AppRuntime
import LLMCore

/// Settings → Behavior → Memory. What the assistant remembers about you, in the open: every saved fact,
/// newest first, labelled with who wrote it and when — editable, deletable, and addable by hand. Memory
/// used to be invisible (two tools and a JSON file, with the model as the only author and no way to see or
/// correct what it decided about you); this screen is the other half of the feature.
///
/// Mirrors `SkillsView`: a `List` (for native swipe-to-delete) over the ink-wash settings surface, an
/// editor sheet, and a confirm before anything is destroyed.
struct MemoryView: View {
    let book: MemoryBook
    /// The switch lives here too, not only in Manage tools. Injection isn't gated on the master tools
    /// switch (see `AppSettings.memoryEnabled`) but the Manage-tools row is hidden when tools are off — so
    /// the one surface that always reaches memory has to be the one that can turn it off.
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MemoryEditorTarget?
    @State private var pendingDelete: MemoryFact?
    @State private var confirmForgetAll = false

    var body: some View {
        List {
            Section {
                Text("Memory is what the model knows about you between chats. It saves a short note when "
                     + "you tell it something worth keeping, and the notes that matter to your question "
                     + "are added to its prompt before it answers. Everything here stays on this device.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: Binding(get: { settings.memoryEnabled },
                                     set: { settings.memoryEnabled = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use memory").font(.subheadline).foregroundStyle(Theme.textPrimary)
                        Text(settings.memoryEnabled
                             ? "Notes that matter to your question are added to the model's prompt."
                             : "These notes stay saved, but the model isn't shown them, and it won't "
                               + "take new ones.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)
                .listRowBackground(Theme.surface)
            }

            Section {
                if book.isEmpty {
                    Text("Nothing saved yet. Tap + to add something you want the model to know about you — "
                         + "or just tell it in a chat, and it'll note it down itself.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(book.facts) { fact in
                        factRow(fact)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = fact } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(Theme.danger)
                            }
                    }
                }
            } header: {
                sectionHeader(book.isEmpty ? "Saved" : "\(book.count) saved")
            }

            if !book.isEmpty {
                Section {
                    Button(role: .destructive) { confirmForgetAll = true } label: {
                        Label("Forget everything", systemImage: "trash")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.surface)
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
        .navigationTitle("Memory")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // The model writes to the store directly (the `remember` tool), so what's on screen is only ever a
        // mirror — re-read it on appear rather than trusting the copy the last chat left behind.
        .task { await book.refresh() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .new } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a memory")
            }
        }
        .sheet(item: $editing) { target in
            MemoryEditorView(book: book, target: target)
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 300)
            #endif
        }
        .alert("Delete this memory?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { fact in
            Button("Delete", role: .destructive) {
                let id = fact.id
                pendingDelete = nil
                Task { await book.delete(id: id) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { fact in
            // Quote the note so a mis-swipe is caught here, clipped so a long one can't push the buttons
            // off the alert.
            let text = fact.text.count > 80 ? String(fact.text.prefix(80)) + "…" : fact.text
            Text("“\(text)” will be forgotten. This can't be undone.")
        }
        .alert("Forget everything?", isPresented: $confirmForgetAll) {
            Button("Forget everything", role: .destructive) { Task { await book.deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(book.count) memories will be deleted from this device. This can't be undone.")
        }
    }

    private func factRow(_ fact: MemoryFact) -> some View {
        Button { editing = .edit(fact) } label: {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(fact.text).font(.subheadline).foregroundStyle(Theme.textPrimary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text(Self.provenance(fact)).font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: Theme.Space.sm)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .accessibilityLabel(fact.text)
        .accessibilityValue(Self.provenance(fact))
        .accessibilityHint("Edit this memory")
    }

    /// "Saved by mobileLLM · 2h" / "Added by you · Yesterday" — who wrote a note is what tells you whether
    /// to trust it, and when tells you whether it's still true.
    static func provenance(_ fact: MemoryFact, now: Date = Date()) -> String {
        let who = fact.source == .user ? "Added by you" : "Saved by mobileLLM"
        return "\(who) · \(Format.relative(fact.createdAt, now: now))"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension MemoryView {
    /// One-line status for the Settings → "Memory" row: how many facts, how many the user wrote — and
    /// whether the model is allowed to use them at all, since a count alone would imply it is.
    @MainActor static func summary(book: MemoryBook, settings: AppSettings) -> String {
        let count = book.count
        guard settings.memoryEnabled else { return count > 0 ? "Off · \(count) saved" : "Off" }
        guard count > 0 else { return "Nothing saved yet" }
        var text = "\(count) memor\(count == 1 ? "y" : "ies")"
        let mine = book.userAuthoredCount
        if mine > 0 { text += " · \(mine) added by you" }
        return text
    }
}

// MARK: - Editor

/// What the editor sheet is doing: adding the user's own fact, or correcting an existing one.
enum MemoryEditorTarget: Identifiable {
    case new
    case edit(MemoryFact)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let f): "edit-\(f.id)"
        }
    }
}

/// Write a memory by hand, or fix one the model got wrong. Deliberately plain: one text field, because a
/// memory is one short sentence — anything longer is an instruction, and that's what a skill is for.
struct MemoryEditorView: View {
    let book: MemoryBook
    let target: MemoryEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(book: MemoryBook, target: MemoryEditorTarget) {
        self.book = book
        self.target = target
        switch target {
        case .new: _text = State(initialValue: "")
        case .edit(let fact): _text = State(initialValue: fact.text)
        }
    }

    private var editingFact: MemoryFact? {
        if case .edit(let f) = target { return f } else { return nil }
    }
    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Write it as a fact about you, in the third person — the model reads these as "
                         + "notes it took. Keep it to one short sentence: it's charged to the context "
                         + "window whenever it's relevant.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $text)
                        .font(.callout)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Space.xs)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field,
                                                                         style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                            .strokeBorder(Theme.hairline))
                        .accessibilityLabel("Memory text")
                    if let fact = editingFact {
                        Text(MemoryView.provenance(fact))
                            .font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: Theme.Layout.form).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .navigationTitle(editingFact == nil ? "New memory" : "Edit memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let text = self.text
        let book = self.book
        if let fact = editingFact {
            Task { await book.update(id: fact.id, text: text) }
        } else {
            Task { await book.add(text) }
        }
        dismiss()
    }
}

#if DEBUG
#Preview("Memory") {
    let container = AppContainer.preview()
    return NavigationStack { MemoryView(book: container.memory, settings: container.settings) }
        .tint(Theme.accent)
}
#endif
