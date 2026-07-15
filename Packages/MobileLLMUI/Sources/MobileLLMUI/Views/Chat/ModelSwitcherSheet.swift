// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppUI
import LLMCore

/// The quick model switcher (DESIGN §4): the active model is a header tap-target that opens this
/// sheet to activate any installed model, or points at Models to download one.
struct ModelSwitcherSheet: View {
    let container: AppContainer
    var onOpenModels: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var installed: [(LLMModel, LLMVariant)] {
        container.models.catalog.flatMap { model in
            model.variants.filter { container.models.isInstalled($0) }.map { (model, $0) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if installed.isEmpty {
                    ChatPlaceholder(icon: "square.and.arrow.down",
                                    title: "No models installed",
                                    message: "Download a model to start chatting on-device.",
                                    actionTitle: "Open Models", action: { dismiss(); onOpenModels() })
                } else {
                    List {
                        ForEach(installed, id: \.1.id) { model, variant in
                            row(model, variant)
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
    }

    private func row(_ model: LLMModel, _ variant: LLMVariant) -> some View {
        let isActive = container.models.active?.variant.id == variant.id
        let presentation = container.models.fitPresentation(model, variant, context: container.settings.contextLength)
        return Button {
            container.activate(model, variant: variant, force: presentation == .experimental)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text(variant.quant.displayName).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                } else {
                    LLMFitBadge(presentation: presentation)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isActive ? Theme.accentSoft : Color.clear)
        .accessibilityLabel("\(model.displayName), \(variant.quant.displayName)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
