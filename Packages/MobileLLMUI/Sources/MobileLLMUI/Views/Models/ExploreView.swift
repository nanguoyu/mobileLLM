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
    @State private var results: [RemoteModel] = []
    @State private var phase: Phase = .loading
    @State private var detail: LLMModel?
    @State private var selEngine: [String: EngineKind] = [:]
    @State private var selQuant: [String: QuantSpec] = [:]

    private enum Phase: Equatable { case loading, ready, failed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                searchField
                sourceLine
                content
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .task(id: query) { await runSearch() }
        .sheet(item: $detail) { model in detailSheet(model) }
    }

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
            + Text("mlx-community").foregroundStyle(Theme.textSecondary).fontWeight(.medium)
            + Text(" · sorted by downloads").foregroundStyle(Theme.textTertiary)
        } icon: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
        .font(.caption).foregroundStyle(Theme.textTertiary)
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
            HStack(spacing: Theme.Space.md) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accentSoft)
                    .frame(width: 36, height: 36)
                    .overlay(Text(initials(model.name)).font(.caption.weight(.bold).monospaced()).foregroundStyle(Theme.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    HStack(spacing: Theme.Space.sm) {
                        Label(Format.shortCount(model.downloads), systemImage: "arrow.down.circle")
                            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        Text("\(model.variants.count) quant\(model.variants.count == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(Theme.accent)
                        Chip(text: "Unverified")
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
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

    private func open(_ remote: RemoteModel) {
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
            let r = q.isEmpty ? try await RemoteCatalog.trending() : try await RemoteCatalog.search(q)
            if Task.isCancelled { return }
            await MainActor.run { results = r; phase = .ready }
        } catch {
            if Task.isCancelled { return }
            await MainActor.run { phase = .failed }
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let s = (parts.first.map(String.init) ?? name).prefix(3)
        return String(s).uppercased()
    }
}
