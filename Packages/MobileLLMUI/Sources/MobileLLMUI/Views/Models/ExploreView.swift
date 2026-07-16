// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// The Explore tier (DESIGN §6): live browse of Hugging Face's MLX checkpoints — hundreds of models,
/// searchable, sorted by downloads. A row taps into a detail sheet that reuses the curated `ModelCard`
/// (engine × precision matrix + fit + download), so a community model behaves like any other once picked.
/// These load generically from the model's own chat template, so each is flagged **Unverified**.
struct ExploreView: View {
    @Bindable var models: ModelManager
    @Bindable var settings: AppSettings
    var onUse: (LLMModel, LLMVariant, _ force: Bool) -> Void

    @State private var query = ""
    @State private var source: RemoteCatalog.Source = .mlx
    @State private var results: [RemoteModel] = []
    @State private var phase: Phase = .loading
    @State private var detail: LLMModel?
    @State private var opening: String?
    @State private var notice: String?
    @State private var selEngine: [String: EngineKind] = [:]
    @State private var selQuant: [String: QuantSpec] = [:]

    private enum Phase: Equatable { case loading, ready, failed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                searchField
                Segmented(selection: $source, options: RemoteCatalog.Source.allCases) { $0.label }
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Checkpoint format")
                sourceLine
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(Theme.fitAmber)
                        .padding(.horizontal, 2)
                        .onTapGesture { self.notice = nil }
                }
                content
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task(id: Reload(query: query, source: source)) { await runSearch() }
        .sheet(item: $detail) { model in detailSheet(model) }
    }

    /// Re-runs the search when either the text or the source changes.
    private struct Reload: Equatable { let query: String; let source: RemoteCatalog.Source }

    // MARK: Search + source

    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Theme.textTertiary)
            TextField("Search Hugging Face — Qwen, Gemma, Llama…", text: $query)
                .textFieldStyle(.plain).font(.subheadline)
                #if os(iOS)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.subheadline).foregroundStyle(Theme.textTertiary)
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var sourceLine: some View {
        Label {
            Text("Browsing ").foregroundStyle(Theme.textTertiary)
            + Text(source == .mlx ? RemoteCatalog.mlxOrg : RemoteCatalog.ggufOrgs.joined(separator: ", "))
                .foregroundStyle(Theme.textSecondary).fontWeight(.medium)
            + Text(" · sorted by downloads").foregroundStyle(Theme.textTertiary)
        } icon: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
        .font(.caption).foregroundStyle(Theme.textTertiary)
        .lineLimit(2)
        .padding(.horizontal, 2)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: Theme.Space.md) {
                ProgressView().tint(Theme.accent)
                Text("Reaching Hugging Face…").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xxl)
        case .failed:
            state(icon: "wifi.exclamationmark", title: "Couldn't reach Hugging Face",
                  msg: "Check your connection and try again.")
        case .ready where results.isEmpty:
            state(icon: "magnifyingglass", title: "No models found",
                  msg: query.isEmpty ? "Nothing to show." : "Nothing matches “\(query)”.")
        case .ready:
            ForEach(results) { row($0) }
        }
    }

    private func row(_ model: RemoteModel) -> some View {
        Button { open(model) } label: {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                FamilyMark(name: model.name)
                VStack(alignment: .leading, spacing: 3) {
                    // Community names get long ("gemma 4 12b coder fable5 composer2.5") — wrap to a second
                    // line at full size rather than shrinking the type.
                    Text(model.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: Theme.Space.sm) {
                        Label(Format.shortCount(model.downloads), systemImage: "arrow.down.circle")
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        // MLX groups quants at list time; a GGUF repo's quants are files we fetch on tap.
                        Text(model.variants.isEmpty ? model.publisher
                             : "\(model.variants.count) quant\(model.variants.count == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(Theme.accent).lineLimit(1)
                        Chip(text: "Unverified")
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                if opening == model.id {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                } else {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(Theme.Space.md)
            .studioCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(model.variants.count) precisions to download")
    }

    private func state(icon: String, title: String, msg: String) -> some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text(msg).font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xxl)
    }

    // MARK: Detail sheet — reuses the curated ModelCard

    private func detailSheet(_ model: LLMModel) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text("Community model from \(model.publisher). It loads from its own chat template — "
                         + "sizes are estimates and behavior isn't hand-verified.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    ModelCard(models: models, model: model, context: settings.contextLength,
                              enginePreference: settings.enginePreference, isRecommended: false,
                              engineSel: Binding(get: { selEngine[model.id] }, set: { selEngine[model.id] = $0 }),
                              quantSel: Binding(get: { selQuant[model.id] }, set: { selQuant[model.id] = $0 }),
                              onUse: { m, v, force in onUse(m, v, force); detail = nil },
                              onDelete: { v in models.delete(v) })
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
            .navigationTitle(model.displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    // MARK: Logic

    /// Open a row: MLX models already carry their quants; a GGUF repo's quant files are fetched now.
    private func open(_ remote: RemoteModel) {
        guard opening == nil else { return }
        if !remote.variants.isEmpty { return present(remote) }
        opening = remote.id
        Task {
            let quants = (try? await RemoteCatalog.quants(for: remote)) ?? []
            await MainActor.run {
                opening = nil
                guard !quants.isEmpty else {
                    notice = "No usable quant files in \(remote.name)."
                    return
                }
                present(RemoteModel(id: remote.id, name: remote.name, publisher: remote.publisher,
                                    engine: remote.engine, downloads: remote.downloads, variants: quants))
            }
        }
    }

    private func present(_ remote: RemoteModel) {
        let model = remote.asLLMModel(paramsBillions: RemoteModel.paramCount(from: remote.name))
        models.adopt(model)
        detail = model
    }

    private func runSearch() async {
        try? await Task.sleep(nanoseconds: 350_000_000)   // debounce keystrokes
        if Task.isCancelled { return }
        await MainActor.run { phase = .loading }
        do {
            let q = query.trimmingCharacters(in: .whitespaces)
            let src = source
            let r = q.isEmpty ? try await RemoteCatalog.trending(source: src)
                              : try await RemoteCatalog.search(q, source: src)
            if Task.isCancelled { return }
            await MainActor.run { results = r; phase = .ready }
        } catch {
            if Task.isCancelled { return }
            await MainActor.run { phase = .failed }
        }
    }

}

/// A model's mark: a monogram of its family (Qwen → Q, DeepSeek → DS) on a colour derived stably from
/// the family name. Muted earth tones only — a rainbow of avatars would fight the ink-wash palette, and
/// per-model artwork doesn't exist on the Hub for community checkpoints.
struct FamilyMark: View {
    let name: String

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(0.20))
            .frame(width: 38, height: 38)
            .overlay(
                Text(monogram)
                    .font(.system(size: monogram.count > 1 ? 13 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.28)))
            .accessibilityHidden(true)
    }

    private var family: String {
        let head = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).first.map(String.init) ?? name
        let letters = head.prefix { $0.isLetter }
        return letters.isEmpty ? String(head.prefix(2)) : String(letters)
    }

    /// CamelCase families become initials (DeepSeek → DS); everything else takes its first letter.
    private var monogram: String {
        let caps = family.filter(\.isUppercase)
        if caps.count >= 2 { return String(caps.prefix(2)) }
        return String(family.prefix(1)).uppercased()
    }

    /// Deterministic across launches (Swift's hashValue is per-process seeded, so fold the scalars).
    private var tint: Color {
        let hues: [Double] = [8, 28, 44, 96, 168, 205, 248, 320]   // muted, earthy — sits beside 宣纸/墨
        var acc = 0
        for scalar in family.lowercased().unicodeScalars { acc = (acc &* 31 &+ Int(scalar.value)) % 100_003 }
        return Color(hue: hues[abs(acc) % hues.count] / 360, saturation: 0.42, brightness: 0.52)
    }
}
