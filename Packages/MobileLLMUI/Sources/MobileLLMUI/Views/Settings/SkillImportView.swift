// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Import a community skill in the AI Edge Gallery's SKILL.md format — by URL (a skill webhost, a GitHub
/// repo, or a direct .md link) or pasted markdown. Fetch → parse → PREVIEW with honest capability badges
/// (a `run_js`-dependent skill needs the JS runtime we don't ship yet; `require-secret` isn't wired) →
/// add. The text always imports; the badges tell the user what to adapt.
struct SkillImportView: View {
    let store: SkillStore
    @Environment(\.dismiss) private var dismiss

    private enum Source: String, CaseIterable { case url, paste
        var label: String { self == .url ? "From URL" : "Paste" }
    }

    @State private var source: Source = .url
    @State private var urlText = ""
    @State private var pasted = ""
    @State private var fetching = false
    @State private var error: String?
    @State private var preview: SkillIO.ParsedSkill?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Compatible with AI Edge Gallery community skills (SKILL.md). Paste a skill's "
                     + "webhost or repo link, or the markdown itself.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Segmented(selection: $source, options: Source.allCases) { $0.label }
                    .frame(maxWidth: 240)
                if source == .url { urlField } else { pasteField }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let preview { previewCard(preview) }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: Theme.Layout.form).frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("Import skill")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { add() }.disabled(preview == nil)
            }
        }
    }

    // MARK: Inputs

    private var urlField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            TextField("https://someone.github.io/some-skill/", text: $urlText)
                .textFieldStyle(.plain).font(.callout.monospaced())
                .foregroundStyle(Theme.textPrimary)
                #if os(iOS)
                .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                #endif
                .padding(Theme.Space.sm)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(Theme.hairline))
            Button {
                Task { await fetch() }
            } label: {
                if fetching {
                    HStack(spacing: Theme.Space.xs) { ProgressView().controlSize(.mini); Text("Fetching…") }
                } else {
                    Label("Fetch & preview", systemImage: "arrow.down.doc")
                }
            }
            .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
            .disabled(fetching || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            TextEditor(text: $pasted)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.xs)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(Theme.hairline))
            Button { parse(pasted) } label: { Label("Preview", systemImage: "eye") }
                .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Preview

    private func previewCard(_ p: SkillIO.ParsedSkill) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(p.name).font(.headline).foregroundStyle(Theme.textPrimary)
            if !p.summary.isEmpty {
                Text(p.summary).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if p.requiresJSRuntime {
                Label("Uses the Gallery's run_js tool — this app has no JS runtime yet, so those steps "
                      + "won't execute. The instructions still import for you to adapt.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(Theme.fitAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if p.requiresSecret {
                Label("Declares a secret requirement" + (p.secretNote.map { " (\($0))" } ?? "")
                      + " — secrets aren't wired here yet.",
                      systemImage: "key.fill")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().background(Theme.hairline)
            Text(p.instructions)
                .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                .lineLimit(14)
        }
        .padding(Theme.Space.md)
        .studioCard()
    }

    // MARK: Actions

    private func fetch() async {
        error = nil; preview = nil; fetching = true
        defer { fetching = false }
        let candidates = SkillIO.candidateURLs(from: urlText)
        guard !candidates.isEmpty else { error = "That doesn't look like a URL."; return }
        for url in candidates {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
               let text = String(data: data, encoding: .utf8),
               let parsed = SkillIO.parse(markdown: text) {
                preview = parsed
                return
            }
        }
        error = "Couldn't find a readable SKILL.md there. Try the direct link to the file."
    }

    private func parse(_ text: String) {
        error = nil
        preview = SkillIO.parse(markdown: text)
        if preview == nil {
            error = "That doesn't parse as SKILL.md — it needs `---` frontmatter with a name, then the "
                  + "instructions."
        }
    }

    private func add() {
        guard let p = preview else { return }
        _ = store.create(name: p.name, emoji: "📦",
                         summary: p.summary.isEmpty ? "Imported skill" : p.summary,
                         instructions: p.instructions)
        dismiss()
    }
}
