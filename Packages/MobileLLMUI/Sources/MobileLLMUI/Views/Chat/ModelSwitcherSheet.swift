// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// The quick model switcher (DESIGN §4): the active model is a header tap-target that opens this
/// sheet to activate any installed model, or points at Models to download one. A tapped row shows an
/// inline spinner and the sheet stays up until the load succeeds (then dismisses) or fails (stays, so
/// you can pick another) — never a silent dismiss into a still-loading model.
struct ModelSwitcherSheet: View {
    let container: AppContainer
    var onOpenModels: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// The variant this sheet kicked off (drives the row spinner + the dismiss-on-success).
    @State private var activating: String?

    private var installed: [(LLMModel, LLMVariant)] {
        let all = container.models.allModels.flatMap { model in
            model.variants.filter { container.models.isInstalled($0) }.map { (model, $0) }
        }
        // The resident model leads the list — it's the row you're most likely orienting around.
        let activeID = container.models.active?.variant.id
        return all.filter { $0.1.id == activeID } + all.filter { $0.1.id != activeID }
    }

    /// Configured online services that are ready to send: a model id is set and the service's Keychain
    /// key is present. The online selection is first-class: it needs no installed weights, so it must
    /// appear even on a device with zero local models.
    private var onlineServices: [OnlineService] {
        container.settings.onlineServices.filter { service in
            service.modelID.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
                && (try? container.openAICredentials.loadAPIKey(serviceID: service.id)) != nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if onlineServices.isEmpty && installed.isEmpty {
                    ChatPlaceholder(icon: "square.and.arrow.down",
                                    title: "No models installed",
                                    message: "Download a model to start chatting on-device.",
                                    actionTitle: "Open Models", action: { dismiss(); onOpenModels() })
                } else {
                    List {
                        if !onlineServices.isEmpty {
                            Section("Online") {
                                ForEach(onlineServices) { service in
                                    onlineRow(service)
                                }
                            }
                        }
                        if !installed.isEmpty {
                            Section("On-device") {
                                ForEach(installed, id: \.1.id) { model, variant in
                                    row(model, variant)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.bg)
                }
            }
            .navigationTitle("Switch model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        // Success: the model we kicked off is now resident → close the sheet.
        .onChange(of: container.models.active?.variant.id) { _, newID in
            if let activating, newID == activating { dismiss() }
        }
        // Activation ended: if the tapped variant is now resident, close (covers re-tapping the ALREADY
        // active model, where `active?.variant.id` never *changes* so the onChange above can't fire);
        // otherwise it failed → stop the spinner, keep the sheet up.
        .onChange(of: container.models.activatingVariantID) { _, current in
            guard current == nil, let tapped = activating else { return }
            if container.models.active?.variant.id == tapped { dismiss() } else { activating = nil }
        }
    }

    private func onlineRow(_ service: OnlineService) -> some View {
        let isActive = container.settings.onlineActiveService?.id == service.id
        return Button {
            container.settings.setOnlineServiceEnabled(id: service.id, enabled: true)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(OnlineModelIdentity.displayLabel(service.name))
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text("\(service.modelID ?? "") · \(service.baseURL)")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isActive ? Theme.accentSoft : Color.clear)
        .accessibilityLabel(OnlineModelIdentity.displayLabel(service.name))
        .accessibilityValue(isActive ? "Active" : "")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func row(_ model: LLMModel, _ variant: LLMVariant) -> some View {
        let isActive = container.models.active?.variant.id == variant.id
        let isActivating = activating == variant.id || container.models.activatingVariantID == variant.id
        let presentation = container.models.fitPresentation(model, variant, context: container.settings.contextLength)
        return Button {
            // Model selection is exclusive: picking an on-device model turns the online service off.
            container.settings.openAIOnlineEnabled = false
            activating = variant.id
            container.activate(model, variant: variant)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    // Show quant + engine so the two 1-bit variants (MLX vs llama.cpp) are distinguishable.
                    Text("\(variant.quant.displayName) · \(variant.engine.label)")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if isActivating {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                } else {
                    LLMFitBadge(presentation: presentation)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(container.models.activatingVariantID != nil)
        .listRowBackground(isActive ? Theme.accentSoft : Color.clear)
        .accessibilityLabel("\(model.displayName), \(variant.quant.displayName), \(variant.engine.label)")
        .accessibilityValue(isActivating ? "Loading" : (isActive ? "Active" : ""))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
