// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Settings → Behavior → Skills, and the composer's "Manage Skills…". The library of instruction packs a
/// user can activate per conversation (Skills v1). Built-ins come first (immutable — opened read-only with
/// a Duplicate action), then the user's custom skills (editable + swipe-to-delete). Mirrors the settings
/// screens' structure; a `List` here (rather than ToolsView's scroll of cards) buys native swipe-to-delete.
struct SkillsView: View {
    let store: SkillStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SkillEditorTarget?
    @State private var pendingDelete: Skill?
    @State private var showImport = false
    @State private var showGallery = false

    var body: some View {
        List {
            Section {
                Text("Skills are reusable instruction packs. Turn one on for a conversation from the "
                     + "composer's + menu — its instructions guide the model for that thread only.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(store.builtInSkills) { skill in
                    skillRow(skill)
                }
            } header: {
                sectionHeader("Built-in")
            }

            Section {
                if store.customSkills.isEmpty {
                    Text("No custom skills yet. Tap + to create one, or duplicate a built-in to start from it.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(store.customSkills) { skill in
                        skillRow(skill)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = skill } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(Theme.danger)
                            }
                    }
                }
            } header: {
                sectionHeader("Custom")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Skills")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showGallery = true } label: {
                        Label("Browse Community Skills…", systemImage: "square.grid.2x2")
                    }
                    Divider()
                    Button { editing = .new } label: { Label("New Skill", systemImage: "square.and.pencil") }
                    Button { showImport = true } label: {
                        Label("Import SKILL.md…", systemImage: "square.and.arrow.down")
                    }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add skill")
            }
        }
        .sheet(item: $editing) { target in
            SkillEditorView(store: store, target: target)
            #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
            #endif
        }
        .sheet(isPresented: $showImport) {
            NavigationStack { SkillImportView(store: store) }
            #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
            #endif
        }
        .sheet(isPresented: $showGallery) {
            NavigationStack { SkillGalleryView(store: store) }
            #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
            #endif
        }
        .alert("Delete this skill?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { skill in
            Button("Delete", role: .destructive) { store.delete(id: skill.id); pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { skill in
            Text("“\(skill.name)” will be removed. Conversations using it fall back to your normal prompt. "
                 + "This can't be undone.")
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        Button { editing = skill.isBuiltIn ? .view(skill) : .edit(skill) } label: {
            HStack(spacing: Theme.Space.md) {
                Text(skill.emoji).font(.title3)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(skill.summary).font(.caption).foregroundStyle(Theme.textTertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.sm)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .accessibilityLabel(skill.name)
        .accessibilityValue(skill.summary)
        .accessibilityHint(skill.isBuiltIn ? "Built-in skill, opens read-only" : "Edit skill")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension SkillsView {
    /// One-line status for the Settings → "Skills" row: how many are available, and how many are custom.
    static func summary(for store: SkillStore) -> String {
        let total = store.skills.count
        let custom = store.customSkills.count
        var text = "\(total) skill\(total == 1 ? "" : "s")"
        if custom > 0 { text += " · \(custom) custom" }
        return text
    }
}

// MARK: - Editor

/// What the editor sheet is doing: creating a new custom skill, editing an existing custom one, or
/// showing a built-in read-only (with Duplicate).
enum SkillEditorTarget: Identifiable {
    case new
    case edit(Skill)
    case view(Skill)   // built-in, read-only

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let s): "edit-\(s.id.uuidString)"
        case .view(let s): "view-\(s.id.uuidString)"
        }
    }
}

/// Create / edit a custom skill, or view a built-in read-only. Built-ins can't be changed here — the
/// Duplicate button makes an editable copy instead (Skills v1 keeps the starters trustworthy).
struct SkillEditorView: View {
    let store: SkillStore
    let target: SkillEditorTarget
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var emoji: String
    @State private var summary: String
    @State private var instructions: String
    @State private var confirmDelete = false

    /// A gentle starting skeleton for a brand-new skill — usable as-is, meant to be replaced.
    private static let template = """
    Act as a <role>.
    - <the first rule the model should follow>
    - <the second rule>
    Keep answers <length / tone>.
    """

    init(store: SkillStore, target: SkillEditorTarget) {
        self.store = store
        self.target = target
        switch target {
        case .new:
            _name = State(initialValue: "")
            _emoji = State(initialValue: "✨")
            _summary = State(initialValue: "")
            _instructions = State(initialValue: Self.template)
        case .edit(let s), .view(let s):
            _name = State(initialValue: s.name)
            _emoji = State(initialValue: s.emoji)
            _summary = State(initialValue: s.summary)
            _instructions = State(initialValue: s.instructions)
        }
    }

    private var isReadOnly: Bool { if case .view = target { return true } else { return false } }
    private var isNew: Bool { if case .new = target { return true } else { return false } }
    private var editingSkill: Skill? {
        if case .edit(let s) = target { return s } else { return nil }
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    if isReadOnly {
                        Label("Built-in skill — read-only. Duplicate it to make an editable copy.",
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    identityRow
                    labeledField("Summary", text: $summary,
                                 placeholder: "One line on when to use it")
                    instructionsField
                    if let skill = editingSkill {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete skill", systemImage: "trash")
                                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.danger)
                                .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.md)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card,
                                                                                style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                    .strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                        .alert("Delete this skill?", isPresented: $confirmDelete) {
                            Button("Delete", role: .destructive) { store.delete(id: skill.id); dismiss() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("“\(skill.name)” will be removed. This can't be undone.")
                        }
                    }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isReadOnly ? "Close" : "Cancel") { dismiss() }
                }
                // Share as SKILL.md — round-trips with the AI Edge Gallery community format, so a skill
                // written here can be posted to either ecosystem's discussions as-is.
                ToolbarItem(placement: .secondaryAction) {
                    ShareLink(item: SkillIO.export(viewedSkill),
                              subject: Text(viewedSkill.name),
                              preview: SharePreview("\(viewedSkill.emoji) \(viewedSkill.name) — SKILL.md")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share as SKILL.md")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isReadOnly {
                        Button("Duplicate") { store.duplicate(viewedSkill); dismiss() }
                    } else {
                        Button("Save") { save() }.disabled(!canSave)
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        if isReadOnly { return name }
        return isNew ? "New skill" : "Edit skill"
    }

    private var viewedSkill: Skill {
        if case .view(let s) = target { return s }
        return Skill(name: name, emoji: emoji, summary: summary, instructions: instructions)
    }

    /// Emoji glyph + name on one row (the two things that identify a skill in the menu and the chip).
    private var identityRow: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Emoji").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                TextField("✨", text: $emoji)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .frame(width: 56)
                    .textFieldStyle(.plain)
                    .padding(.vertical, Theme.Space.sm)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
                    .disabled(isReadOnly)
                    // One emoji only — collapse a paste of several to the first character.
                    .onChange(of: emoji) { _, new in
                        let one = SkillStore.oneEmoji(new)
                        if one != new { emoji = one }
                    }
                    .accessibilityLabel("Skill emoji")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                TextField("Skill name", text: $name)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .padding(Theme.Space.sm)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
                    .disabled(isReadOnly)
                    .accessibilityLabel("Skill name")
            }
        }
    }

    private var instructionsField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Instructions").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text("Appended to the system prompt while this skill is active. Keep it short and imperative — "
                 + "it's charged to the context window on every turn, and small models follow a few sharp "
                 + "rules better than many soft ones.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $instructions)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
                .disabled(isReadOnly)
                .accessibilityLabel("Skill instructions")
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...3)
                .font(.callout)
                .textFieldStyle(.plain)
                .padding(Theme.Space.sm)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
                .disabled(isReadOnly)
                .accessibilityLabel(label)
        }
    }

    private func save() {
        guard canSave else { return }
        if let skill = editingSkill {
            store.update(Skill(id: skill.id, name: name, emoji: emoji, summary: summary,
                               instructions: instructions, isBuiltIn: false))
        } else {
            store.create(name: name, emoji: emoji, summary: summary, instructions: instructions)
        }
        dismiss()
    }
}

#if DEBUG
#Preview("Skills") {
    let container = AppContainer.preview()
    return NavigationStack { SkillsView(store: container.skills) }
        .tint(Theme.accent)
}
#endif
