// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Model manager (DESIGN §4): catalog cards with the device-recommended default pinned first, a fit
/// badge, a 1-bit ↔ ternary quant selector that live-updates fit + size, the reused download meter
/// with pause/resume, delete, an Active tag, and the honest experimental "Try anyway" for the 27B on
/// an 8 GB phone.
struct ModelsView: View {
    @Bindable var models: ModelManager
    @Bindable var settings: AppSettings
    /// Activate a variant (the container runs the OOM pre-flight + syncs the chat's active model).
    var onUse: (LLMModel, LLMVariant, _ force: Bool) -> Void

    /// Per-model selected quant (defaults to the model's default variant).
    @State private var selectedQuant: [String: QuantSpec] = [:]
    @State private var pendingDelete: (model: LLMModel, variant: LLMVariant)?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                storageHeader
                ForEach(Array(models.orderedCatalog.enumerated()), id: \.element.id) { index, model in
                    ModelCard(models: models,
                              model: model,
                              context: settings.contextLength,
                              isRecommended: index == 0,
                              quant: binding(for: model),
                              onUse: onUse,
                              onDelete: { variant in pendingDelete = (model, variant) })
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
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

    private func binding(for model: LLMModel) -> Binding<QuantSpec> {
        Binding(
            get: { selectedQuant[model.id] ?? model.defaultVariant },
            set: { selectedQuant[model.id] = $0 })
    }
}

/// One catalog card, data-driven so every model renders the same anatomy.
private struct ModelCard: View {
    @Bindable var models: ModelManager
    let model: LLMModel
    let context: Int
    let isRecommended: Bool
    @Binding var quant: QuantSpec
    var onUse: (LLMModel, LLMVariant, Bool) -> Void
    var onDelete: (LLMVariant) -> Void

    private var variant: LLMVariant { model.variant(for: quant) ?? model.defaultVariantValue }
    private var presentation: ModelManager.FitPresentation {
        models.fitPresentation(model, variant, context: context)
    }
    private var isActive: Bool { models.active?.variant.id == variant.id }
    private var isInstalled: Bool { models.isInstalled(variant) }
    private var download: VariantDownload? { models.downloadState(variant) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header
            Text("\(model.publisher) · \(model.summary)")
                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
            quantAndSize
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.displayName)
                .font(.headline).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
            if isRecommended { Chip(text: "Recommended", filled: true) }
            Spacer()
            LLMFitBadge(presentation: presentation)
        }
    }

    private var quantAndSize: some View {
        HStack(spacing: Theme.Space.sm) {
            Segmented(selection: $quant, options: model.variants.map(\.quant)) { $0.displayName }
                .frame(maxWidth: 220)
            Spacer(minLength: Theme.Space.sm)
            Text(Format.bytes(variant.onDiskBytes))
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .fixedSize()
        }
    }

    // MARK: Action area (tri-state)

    @ViewBuilder private var actionArea: some View {
        if let download, models.isDownloading(variant) {
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
                    Label(presentation == .experimental ? "Try anyway" : "Use",
                          systemImage: presentation == .experimental ? "exclamationmark.triangle" : "bolt.fill")
                }
                .buttonStyle(StudioButtonStyle(.primary))
            }
            Spacer()
            Button(role: .destructive) { onDelete(variant) } label: {
                Image(systemName: "trash").foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain).accessibilityLabel("Delete \(model.displayName)")
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
