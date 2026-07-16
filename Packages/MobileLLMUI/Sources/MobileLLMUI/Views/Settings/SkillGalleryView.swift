// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Browse the community Skill Gallery without leaving the app — the repo's **Discussions → Skills** board,
/// rendered as ink-wash cards. Each post that carries a parseable SKILL.md installs with one tap (reusing
/// `SkillStore.create`, so it lands identical to a manual `Import SKILL.md`); posts that only link out are
/// still listed so they can be opened on GitHub. Additive discovery — the manual import path is untouched.
///
/// States mirror `ExploreView`: a loading spinner while GitHub answers, a failed card with Retry + an
/// "open on GitHub" escape hatch (the anonymous rate limit lives here), and an empty invite to contribute.
struct SkillGalleryView: View {
    let store: SkillStore
    @Environment(\.dismiss) private var dismiss

    @State private var items: [SkillGallery.GalleryItem] = []
    @State private var phase: Phase = .loading
    @State private var selected: SkillGallery.GalleryItem?

    private enum Phase: Equatable { case loading, ready, failed(String) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Skills shared by the community on GitHub Discussions. Tap one to preview it, then "
                     + "install with a tap — it joins your custom skills like any other.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                content
                footer
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: Theme.Layout.form).frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("Community Skills")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { await load() }
        .sheet(item: $selected) { item in
            detailSheet(item)
            #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
            #endif
        }
    }

    // MARK: Content states

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: Theme.Space.md) {
                ProgressView().tint(Theme.accent)
                Text("Reaching GitHub…").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xxl)
        case .failed(let message):
            failedState(message)
        case .ready where items.isEmpty:
            emptyState
        case .ready:
            VStack(spacing: Theme.Space.md) {
                ForEach(items) { row($0) }
            }
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text("Couldn't load community skills")
                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text(message).font(.caption).foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.md) {
                Button { Task { await load() } } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle(.secondary))
                Link(destination: SkillGallery.boardURL) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(StudioButtonStyle(.secondary))
            }
            .font(.subheadline)
            .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text("No skills shared yet")
                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text("Be the first — post one in Discussions → Skills.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Link(destination: SkillGallery.boardURL) {
                Label("Open the board", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(StudioButtonStyle(.secondary)).font(.subheadline)
            .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
    }

    // MARK: Row

    private func row(_ item: SkillGallery.GalleryItem) -> some View {
        Button { selected = item } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                Text(item.emoji).font(.title3).frame(width: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(item)).font(.caption).foregroundStyle(Theme.textTertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    meta(item)
                }
                Spacer(minLength: Theme.Space.sm)
                trailing(item)
            }
            .padding(Theme.Space.md)
            .studioCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(subtitle(item))
        .accessibilityHint(item.isInstallable ? "Opens a preview to install" : "Opens on GitHub")
    }

    @ViewBuilder private func trailing(_ item: SkillGallery.GalleryItem) -> some View {
        if item.isInstalled(in: store) {
            Chip(text: "Installed", filled: true, size: .small)
        } else if !item.isInstallable {
            Chip(text: "On GitHub", size: .small)
        } else {
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private func meta(_ item: SkillGallery.GalleryItem) -> some View {
        // Upvotes aren't in the Atom feed (the only anonymous window onto the board), so the row shows
        // just the author — honest over a permanent "▲0".
        HStack(spacing: 5) {
            Text("by \(item.author)").lineLimit(1)
        }
        .font(.caption2).foregroundStyle(Theme.textTertiary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("by \(item.author)")
    }

    private func subtitle(_ item: SkillGallery.GalleryItem) -> String {
        if let p = item.parsed { return p.summary.isEmpty ? "Community skill" : p.summary }
        return "No importable SKILL.md — open on GitHub to view."
    }

    // MARK: Footer

    private var footer: some View {
        Link(destination: SkillGallery.boardURL) {
            Label("Share your own in Discussions → Skills", systemImage: "square.and.pencil")
                .font(.caption).foregroundStyle(Theme.accent)
        }
        .padding(.top, Theme.Space.xs)
    }

    // MARK: Detail sheet

    private func detailSheet(_ item: SkillGallery.GalleryItem) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    meta(item)
                    if let parsed = item.parsed {
                        previewCard(item, parsed: parsed)
                    } else {
                        notImportableCard
                    }
                    Link(destination: item.url) {
                        Label("Open on GitHub", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                    Text("Share your own in Discussions → Skills.")
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: Theme.Layout.form).frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
            .navigationTitle(item.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { selected = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    if item.isInstalled(in: store) {
                        Label("Installed", systemImage: "checkmark").foregroundStyle(Theme.fitGreen)
                    } else {
                        Button("Install") { install(item) }.disabled(!item.isInstallable)
                    }
                }
            }
        }
    }

    /// Mirrors `SkillImportView`'s preview card: name, summary, the honest capability badges, then a clipped
    /// instructions preview — so a gallery install shows the same "here's what you're adding" surface.
    private func previewCard(_ item: SkillGallery.GalleryItem, parsed p: SkillIO.ParsedSkill) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text(item.emoji).font(.title3).accessibilityHidden(true)
                Text(p.name).font(.headline).foregroundStyle(Theme.textPrimary)
            }
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

    private var notImportableCard: some View {
        Label("This post doesn't include an importable SKILL.md — it may link to one instead. Open it on "
              + "GitHub to read it.", systemImage: "doc.questionmark")
            .font(.caption).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Space.md)
            .studioCard()
    }

    // MARK: Actions

    private func load() async {
        phase = .loading
        do {
            items = try await SkillGallery.fetch()
            phase = .ready
        } catch {
            let message = (error as? SkillGallery.GalleryError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message)
        }
    }

    private func install(_ item: SkillGallery.GalleryItem) {
        guard let p = item.parsed else { return }
        store.create(name: p.name, emoji: item.emoji,
                     summary: p.summary.isEmpty ? "Imported skill" : p.summary,
                     instructions: p.instructions)
        selected = nil
    }
}

#if DEBUG
#Preview("Skill Gallery") {
    let container = AppContainer.preview()
    return NavigationStack { SkillGalleryView(store: container.skills) }
        .tint(Theme.accent)
}
#endif
