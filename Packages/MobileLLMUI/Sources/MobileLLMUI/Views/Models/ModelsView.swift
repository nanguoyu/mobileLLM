// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Model manager (DESIGN §4): catalog cards with the device-recommended default pinned first, a fit
/// badge, an MLX ↔ llama.cpp engine picker + a quant selector that reflow together and live-update fit
/// + size, the reused download meter with pause/resume, delete, an Active tag, and the honest
/// experimental "Try anyway" for the 27B on an 8 GB phone.
struct ModelsView: View {
    @Bindable var models: ModelManager
    @Bindable var settings: AppSettings
    /// Activate a variant (the container runs the OOM pre-flight + syncs the chat's active model).
    var onUse: (LLMModel, LLMVariant, _ force: Bool) -> Void

    /// Per-model selection overrides (nil = follow the engine preference / default quant).
    @State private var selectedEngine: [String: EngineKind] = [:]
    @State private var selectedQuant: [String: QuantSpec] = [:]
    @State private var pendingDelete: (model: LLMModel, variant: LLMVariant)?
    @State private var filter: ModelFilter = .all
    @State private var query = ""
    @State private var tier: Tier = .featured

    /// The two-tier library: curated (verified + adapted) vs live Hugging Face browse.
    private enum Tier: String, CaseIterable {
        case featured, explore
        var label: String { self == .featured ? "Featured" : "Explore" }
    }

    /// Catalog filter (the catalog now spans several families, so it needs search + shape). No "Chinese"
    /// filter: every seed family except Gemma is Chinese-strong, so it barely narrows anything —
    /// "Multimodal" is the distinction that actually matters.
    private enum ModelFilter: String, CaseIterable {
        case all, runs, installed, reasoning, multimodal
        var label: String {
            switch self {
            case .all: "All"; case .runs: "Runs here"; case .installed: "Installed"
            case .reasoning: "Reasoning"; case .multimodal: "Multimodal"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Segmented(selection: $tier, options: Tier.allCases) { $0.label }
                .frame(maxWidth: 360)
                .padding(.horizontal, Theme.Space.lg)
                .padding(.top, Theme.Space.md).padding(.bottom, Theme.Space.sm)
                .accessibilityLabel("Model library")
            if tier == .featured {
                featuredScroll
            } else {
                ExploreView(models: models, settings: settings, onUse: onUse)
            }
        }
        .background(Theme.bg)
        .onAppear { models.refreshInstalled() }
        .alert(pendingDelete.map { "Delete \($0.model.displayName)?" } ?? "",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { target in
            Button("Delete", role: .destructive) { models.delete(target.variant) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Frees the disk space. You can download it again anytime.")
        }
    }

    private var featuredScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if hasNoDownloadedModel { firstRunHeader }
                activeSection
                storageHeader
                searchField
                filterChips
                ForEach(visibleFamilies, id: \.self) { family in
                    familySection(family)
                }
                if visibleFamilies.isEmpty { emptyState }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    /// The resident model, pinned above everything (only when no search/filter narrows the list — a
    /// filtered view should show exactly what was asked for). Reuses ModelCard so engine/quant/fit stay
    /// live; the family section below still lists it in catalog order.
    @ViewBuilder private var activeSection: some View {
        if query.isEmpty, filter == .all, let active = models.active,
           let model = models.model(id: active.model.id) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(Theme.fitGreen)
                    Text("In use").font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 2)
                ModelCard(models: models,
                          model: model,
                          context: settings.contextLength,
                          enginePreference: settings.enginePreference,
                          isRecommended: false,
                          engineSel: engineBinding(for: model),
                          quantSel: quantBinding(for: model),
                          onUse: onUse,
                          onDelete: { variant in pendingDelete = (model, variant) })
            }
        }
    }

    /// Nothing DOWNLOADABLE is on disk yet. The OS-provided model deliberately doesn't count: it needs no
    /// download, so having it doesn't mean the user has fetched a model of their own — and "Get started"
    /// is exactly the nudge to do that. Keying this off `installed.isEmpty` would silently hide the
    /// first-run guidance on every device with Apple Intelligence switched on.
    private var hasNoDownloadedModel: Bool {
        !models.allModels.contains { model in
            model.variants.contains { !$0.isSystemProvided && models.isInstalled($0) }
        }
    }

    /// First-run guidance (DESIGN §4): nothing is installed yet, so make the very first action obvious —
    /// a pinned card for the device-recommended model with a one-tap "Get started" download.
    private var firstRunHeader: some View {
        let model = models.recommendedModel
        let variant = AppSettings.preferredVariant(for: model, device: models.device,
                                                   preference: settings.enginePreference,
                                                   context: settings.contextLength)
        let downloading = models.isDownloading(variant)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("Get started", systemImage: "sparkles")
                .font(.headline).foregroundStyle(Theme.textPrimary)
            Text("Download \(model.displayName) to start chatting on-device. Everything runs locally — "
                 + "no account, and nothing leaves your device.")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { models.download(variant) } label: {
                Label(downloading ? "Downloading \(model.displayName)…"
                                  : "Get \(model.displayName) · \(Format.bytes(variant.onDiskBytes))",
                      systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(StudioButtonStyle(.primary))
            .disabled(downloading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioCard()
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
    }

    // MARK: Family sections

    /// Families with at least one model matching the current filter, in catalog order.
    private var visibleFamilies: [LLMFamily] {
        var seen: [LLMFamily] = []
        for model in models.catalog where matches(model) && !seen.contains(model.family) {
            seen.append(model.family)
        }
        return seen
    }

    private func familyModels(_ family: LLMFamily) -> [LLMModel] {
        models.catalog.filter { $0.family == family && matches($0) }
    }

    @ViewBuilder private func familySection(_ family: LLMFamily) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.xs) {
                Text(family.displayName)
                    .font(.headline).foregroundStyle(Theme.textPrimary)
                if family == models.recommendedModel.family {
                    Chip(text: "Recommended", filled: true)
                }
                Spacer()
                Text(familyModels(family).first?.publisher ?? "")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 2)
            ForEach(familyModels(family)) { model in
                ModelCard(models: models,
                          model: model,
                          context: settings.contextLength,
                          enginePreference: settings.enginePreference,
                          isRecommended: model.id == models.recommendedModel.id,
                          engineSel: engineBinding(for: model),
                          quantSel: quantBinding(for: model),
                          onUse: onUse,
                          onDelete: { variant in pendingDelete = (model, variant) })
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: filter == .installed ? "square.and.arrow.down" : "line.3.horizontal.decrease.circle")
                .font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text(filter == .installed ? "No models downloaded yet" : "Nothing matches this filter")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }

    // MARK: Search + filter

    private var searchField: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Theme.textTertiary)
            TextField("Search models — name, publisher…", text: $query)
                .textFieldStyle(.plain).font(.subheadline)
                #if os(iOS)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.subheadline).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(ModelFilter.allCases, id: \.self) { f in
                    let on = filter == f
                    Button { withAnimation(Motion.select) { filter = f } } label: {
                        Text(f.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                            .padding(.horizontal, Theme.Space.md).padding(.vertical, 7)
                            .background(on ? Theme.accent : Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func matches(_ model: LLMModel) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, !"\(model.displayName) \(model.publisher)".lowercased().contains(q) { return false }
        switch filter {
        case .all: return true
        case .runs: return model.variants.contains { variant in
            // For the OS-provided model, "runs here" is an availability question, not a memory one: its
            // fit is always comfortable, so keying off fit alone would list it under "Runs here" on a
            // device where Apple Intelligence is off or ineligible.
            if variant.isSystemProvided { return models.systemModelStatus.isAvailable }
            return models.fitPresentation(model, variant, context: settings.contextLength) != .unsupported
        }
        case .installed: return model.variants.contains { models.isInstalled($0) }
        case .reasoning: return model.architecture.thinkingCapable
        case .multimodal: return !model.architecture.extraModalities.isEmpty
        }
    }

    private var storageHeader: some View {
        HStack {
            Label("On-device models", systemImage: "internaldrive")
                .font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(Format.bytes(models.installedBytes)) used")
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 2)
    }

    private func engineBinding(for model: LLMModel) -> Binding<EngineKind?> {
        Binding(get: { selectedEngine[model.id] }, set: { selectedEngine[model.id] = $0 })
    }

    private func quantBinding(for model: LLMModel) -> Binding<QuantSpec?> {
        Binding(get: { selectedQuant[model.id] }, set: { selectedQuant[model.id] = $0 })
    }
}

/// One catalog card, data-driven so every model renders the same anatomy. Reused by the Explore detail.
struct ModelCard: View {
    @Bindable var models: ModelManager
    let model: LLMModel
    let context: Int
    let enginePreference: EnginePreference
    let isRecommended: Bool
    @Binding var engineSel: EngineKind?
    @Binding var quantSel: QuantSpec?
    var onUse: (LLMModel, LLMVariant, Bool) -> Void
    var onDelete: (LLMVariant) -> Void

    /// The engine the card defaults to when the user hasn't picked one: the Auto-policy's choice for
    /// this device + preference (so the picker starts on the recommended engine).
    private var defaultEngine: EngineKind {
        AppSettings.preferredVariant(for: model, device: models.device,
                                     preference: enginePreference, context: context).engine
    }
    private var engine: EngineKind { engineSel ?? defaultEngine }
    private var quantsForEngine: [QuantSpec] { model.variants(for: engine).map(\.quant) }
    /// The selected quant, clamped to one the current engine actually ships (engine switches reflow it).
    private var quant: QuantSpec {
        let sel = quantSel ?? model.defaultVariant
        return quantsForEngine.contains(sel) ? sel : (quantsForEngine.first ?? model.defaultVariant)
    }
    private var variant: LLMVariant { model.variant(engine: engine, quant: quant) ?? model.defaultVariantValue }

    private var engineBinding: Binding<EngineKind> {
        Binding(get: { engine }, set: { engineSel = $0 })
    }

    private var presentation: ModelManager.FitPresentation {
        models.fitPresentation(model, variant, context: context)
    }

    /// The OS's model is usable only when the system says so — memory was never the question, and the fit
    /// verdict for it is always `.comfortable` (it costs us nothing). So when it ISN'T available the fit
    /// affordances are suppressed rather than rendered: a green "Runs great" beside "Apple Intelligence is
    /// turned off" contradicts itself, and a gray "Needs more memory" would blame the wrong thing entirely.
    /// The row states the real reason instead.
    private var systemModelBlocked: Bool {
        variant.isSystemProvided && !models.systemModelStatus.isAvailable
    }

    private var isActive: Bool { models.active?.variant.id == variant.id }
    private var isInstalled: Bool { models.isInstalled(variant) }
    private var download: VariantDownload? { models.downloadState(variant) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            Text("\(model.publisher) · \(model.summary)")
                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
            if !model.architecture.extraModalities.isEmpty { modalityRow }
            engineAndQuant
            if presentation == .experimental && !isActive {
                Text("This model is larger than the safe budget on this device — it may be interrupted "
                     + "by the system. You can still try it.")
                    .font(.caption2).foregroundStyle(Theme.fitAmber).lineLimit(3)
            }
            actionArea
        }
        .studioCard()
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 1.5))
    }

    /// What the checkpoint natively accepts beyond text. Vision GGUF variants with an mmproj can now take
    /// image input for real (llama.cpp mtmd); everything else stays honestly text-only, so the note never
    /// over-promises.
    private var modalityRow: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(model.architecture.extraModalities, id: \.self) { m in
                Label(m.label, systemImage: m.icon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Space.xs).padding(.vertical, 3)
                    .background(Theme.surface2, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .accessibilityLabel("Model supports \(m.label) input")
            }
            Text(modalityFootnote)
                .font(.caption2).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
    }

    /// Honest modality status: a GGUF vision variant that ships an mmproj projector takes image input now
    /// (llama.cpp mtmd), so say so; MLX vision + audio aren't wired, so they stay "text-only".
    private var modalityFootnote: String {
        let visionReady = model.variants(for: .llamaCpp).contains { $0.supportsVisionInput }
        return visionReady ? "· image input works (llama.cpp)" : "· text-only here for now"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.displayName)
                .font(.headline).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
            if isRecommended { Chip(text: "Recommended", filled: true) }
            Spacer()
            if !systemModelBlocked { LLMFitBadge(presentation: presentation) }
        }
    }

    @ViewBuilder private var engineAndQuant: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // Engine picker (only when the model ships more than one engine). Switching reflows the
            // precision chips + live-updates the fit badge above.
            if model.engines.count > 1 {
                matrixRow(label: "Engine") {
                    Segmented(selection: engineBinding, options: model.engines) { $0.label }
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Inference engine")
                }
            }
            // Precision as chips — each carries its own fit dot, so the whole matrix reads at a glance.
            matrixRow(label: "Precision") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(quantsForEngine, id: \.self) { q in precisionChip(q) }
                    }
                    .padding(.vertical, 1)
                }
            }
            HStack(spacing: Theme.Space.xs) {
                Text(variant.quant.displayName).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                Text("·").foregroundStyle(Theme.textTertiary)
                // An OS-provided model has no download: "Zero KB" would be a technically-true absurdity,
                // so say what's actually true instead.
                Text(variant.isSystemProvided ? "Built into the system"
                                              : Format.bytes(variant.onDiskBytes))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.top, 1)
        }
    }

    private func matrixRow<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)   // never hyphenate ("PRECI-SION") — shrink instead
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 74, alignment: .leading)
            content()
        }
    }

    private func precisionChip(_ q: QuantSpec) -> some View {
        let on = q == quant
        return Button { withAnimation(Motion.select) { quantSel = q } } label: {
            HStack(spacing: 5) {
                Circle().fill(fitColor(for: q))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(.white.opacity(on ? 0.5 : 0), lineWidth: 1))
                Text(q.displayName).font(.caption.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.sm).padding(.vertical, 6)
            .background(on ? Theme.accent : Theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(q.displayName), \(fitWord(for: q))")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// The fit dot colour for a precision on this device (each chip rates its own variant). A system
    /// model the OS won't give us reads gray — it can't be used — but never green, which is what the
    /// memory-only verdict would otherwise say.
    private func fitColor(for q: QuantSpec) -> Color {
        guard let v = model.variant(engine: engine, quant: q) else { return Theme.fitGray }
        if systemModelBlocked { return Theme.fitGray }
        switch models.fitPresentation(model, v, context: context) {
        case .comfortable: return Theme.fitGreen
        case .tight, .experimental: return Theme.fitAmber
        case .unsupported: return Theme.fitGray
        }
    }

    private func fitWord(for q: QuantSpec) -> String {
        guard let v = model.variant(engine: engine, quant: q) else { return "unavailable" }
        // Gray here is not a memory verdict, so don't say "won't fit" — it fits fine; the OS just isn't
        // offering it.
        if systemModelBlocked { return "unavailable" }
        switch models.fitPresentation(model, v, context: context) {
        case .comfortable: return "runs great"
        case .tight: return "tight"
        case .experimental: return "experimental"
        case .unsupported: return "won't fit"
        }
    }

    // MARK: Action area (tri-state)

    @ViewBuilder private var actionArea: some View {
        // The OS-provided model is a different shape entirely: it has no download, paused, error or
        // delete state — only "ready to use" or "here's exactly why it isn't".
        if variant.isSystemProvided {
            systemModelRow
        } else if let download, models.isDownloading(variant) {
            downloadingRow(download)
        } else if let download, download.isPaused {
            pausedRow(download)
        } else if let download, let error = download.error {
            errorRow(error)
        } else if isInstalled {
            installedRow
        } else {
            downloadRow
        }
    }

    /// The OS's own model: nothing to download, nothing to delete. When Apple Intelligence is off or the
    /// device isn't eligible, the card states the real reason from the system's own verdict and offers NO
    /// button — a Use that can only fail is worse than no Use at all (A4). No fake progress either: there
    /// is no download to show, and `.modelNotReady` resolves itself without us.
    @ViewBuilder private var systemModelRow: some View {
        if let reason = models.systemModelStatus.unavailableReason {
            Label(reason.message, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(model.displayName) is unavailable. \(reason.message)")
        } else if isActive {
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
        } else {
            HStack(spacing: Theme.Space.sm) {
                Button { onUse(model, variant, false) } label: {
                    if isActivating {
                        HStack(spacing: Theme.Space.xs) {
                            ProgressView().controlSize(.small).tint(Theme.onAccent)
                            Text("Loading…")
                        }
                    } else {
                        Label("Use", systemImage: "bolt.fill")
                    }
                }
                .buttonStyle(StudioButtonStyle(.primary))
                .disabled(activationBusy)
                .accessibilityLabel(isActivating ? "Loading \(model.displayName)" : "Use \(model.displayName)")
                Text("Ready — no download needed")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
    }

    private func downloadingRow(_ download: VariantDownload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.sm) {
                ProgressView(value: download.fraction).tint(Theme.accent)
                Button { models.pauseDownload(variant) } label: {
                    Image(systemName: "pause.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain).accessibilityLabel("Pause download")
            }
            Text(download.meter.compactDetail ?? "Downloading… \(Int(download.fraction * 100))%")
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("Keep mobileLLM open while downloading — it resumes automatically if interrupted.")
                .font(.caption2).foregroundStyle(Theme.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloading \(model.displayName)")
        .accessibilityValue(download.meter.detail ?? "\(Int(download.fraction * 100)) percent")
    }

    private func pausedRow(_ download: VariantDownload) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Button { models.download(variant) } label: {
                Label("Resume · \(Int(download.fraction * 100))%", systemImage: "arrow.down.circle")
            }
            .buttonStyle(StudioButtonStyle(.secondary))
            Spacer()
        }
    }

    private func errorRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message).font(.caption2).foregroundStyle(Theme.danger).lineLimit(2)
            Button { models.download(variant) } label: {
                Label("Retry download", systemImage: "arrow.clockwise")
            }
            .buttonStyle(StudioButtonStyle(.secondary))
        }
    }

    /// This variant is the one currently loading (the user tapped Use / Try anyway).
    private var isActivating: Bool { models.activatingVariantID == variant.id }
    /// An activation is in flight somewhere — every Use button disables so a second tap can't re-enter it.
    private var activationBusy: Bool { models.activatingVariantID != nil }
    private var loadingLabel: String {
        if let p = models.loadProgress { return "Loading \(Int(p * 100))%" }
        return "Loading…"
    }

    @ViewBuilder private var installedRow: some View {
        HStack(spacing: Theme.Space.sm) {
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            } else if presentation == .unsupported {
                Text("Needs more memory").font(.caption).foregroundStyle(Theme.textTertiary)
            } else {
                Button {
                    onUse(model, variant, presentation == .experimental)
                } label: {
                    if isActivating {
                        HStack(spacing: Theme.Space.xs) {
                            ProgressView().controlSize(.small).tint(Theme.onAccent)
                            Text(loadingLabel)
                        }
                    } else {
                        Label(presentation == .experimental ? "Try anyway" : "Use",
                              systemImage: presentation == .experimental ? "exclamationmark.triangle" : "bolt.fill")
                    }
                }
                .buttonStyle(StudioButtonStyle(.primary))
                // Disable every Use while a load is running (per-variant spinner shows which one).
                .disabled(activationBusy)
                .accessibilityLabel(isActivating ? "Loading \(model.displayName)"
                                    : (presentation == .experimental ? "Try \(model.displayName) anyway" : "Use \(model.displayName)"))
            }
            Spacer()
            Button(role: .destructive) { onDelete(variant) } label: {
                Image(systemName: "trash").foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain).disabled(isActivating).accessibilityLabel("Delete \(model.displayName)")
        }
    }

    private var downloadRow: some View {
        HStack {
            Button { models.download(variant) } label: {
                Label("Download · \(Format.bytes(variant.onDiskBytes))", systemImage: "arrow.down.circle")
            }
            .buttonStyle(StudioButtonStyle(.secondary))
            Spacer()
        }
    }
}

#if DEBUG
#Preview("Models") {
    let container = AppContainer.preview()
    return ModelsView(models: container.models, settings: container.settings) { _, _, _ in }
}
#endif
