// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Settings → Online models: a managed list of OpenAI-compatible Responses API services, mirroring the
/// MCP servers pattern. Each service owns its base URL, model id, and Keychain key; exactly one can be
/// armed as the active online model.
struct OnlineServicesView: View {
    @Bindable var settings: AppSettings
    let store: any OpenAICredentialStoring
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var editing: OnlineService?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Each service is an OpenAI-compatible Responses API endpoint. The key for each "
                     + "service lives in the device Keychain only — never synced, backed up, or "
                     + "committed. Sending to any service is data egress and asks for approval once "
                     + "per conversation.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)

                if settings.onlineServices.isEmpty {
                    emptyState
                } else {
                    ForEach(settings.onlineServices) { service in
                        Button { editing = service } label: { row(service) }
                            .buttonStyle(.plain)
                    }
                    Text("At most one service can be active at a time; the active one is what a send uses.")
                        .font(.caption).foregroundStyle(Theme.textTertiary).padding(.horizontal, 2)
                }

                Button { showAdd = true } label: {
                    Label("Add a service", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.md)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card,
                                                                        style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("Online models")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                OnlineServiceEditorView(settings: settings, store: store)
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
        }
        .sheet(item: $editing) { service in
            NavigationStack {
                OnlineServiceEditorView(settings: settings, store: store, serviceID: service.id)
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "network")
                .font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text("No online services yet").font(.subheadline.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text("Add an OpenAI-compatible endpoint to chat without loading a local model.")
                .font(.caption).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
        .studioCard()
    }

    private func row(_ service: OnlineService) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: service.isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(service.isEnabled ? Theme.fitGreen : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Text(service.summary)
                    .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            Text(keyLabel(service.id))
                .font(.caption2).foregroundStyle(Theme.textTertiary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.md)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(service.isEnabled ? Theme.fitGreen : Theme.hairline))
        .contentShape(Rectangle())
    }

    private func keyLabel(_ serviceID: String) -> String {
        ((try? store.loadAPIKey(serviceID: serviceID)) != nil) ? "Key stored" : "No key"
    }
}

/// Add/edit one online service: name, base URL, model, key (Keychain), active toggle, delete.
private struct OnlineServiceEditorView: View {
    @Bindable var settings: AppSettings
    let store: any OpenAICredentialStoring
    /// nil = adding a new service; otherwise the stable id being edited.
    let serviceID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var draftID = UUID().uuidString
    @State private var name = ""
    @State private var baseURL = ""
    @State private var modelID = ""
    @State private var maximumOutputTokens = ""
    @State private var key = ""
    @State private var enabled = false
    @State private var stored = false
    @State private var status = ""

    init(settings: AppSettings, store: any OpenAICredentialStoring, serviceID: String? = nil) {
        self.settings = settings
        self.store = store
        self.serviceID = serviceID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                field("Name (optional)", text: $name, placeholder: "e.g. My gateway")
                field("API base URL", text: $baseURL, placeholder: "https://api.openai.com/v1",
                      keyboard: .url)
                field("Model (optional)", text: $modelID, placeholder: "e.g. gpt-4o-mini")
                field("Max output tokens (optional)", text: $maximumOutputTokens,
                      placeholder: "e.g. 16384 — 0 = unknown (auto)")

                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("API key").font(.subheadline.weight(.medium))
                    SecureField(stored ? "Key stored — paste to replace" : "sk-…", text: $key)
                        .textFieldStyle(.plain)
                        .studioField()
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityLabel("API key")
                    Text(stored ? "Stored in the device Keychain. Leave empty to keep it."
                                : "Stored in the device Keychain only.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }

                Divider().background(Theme.hairline)
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active online model").font(.subheadline).foregroundStyle(Theme.textPrimary)
                        Text("The next message goes to this service instead of the on-device model.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .tint(Theme.accent)

                HStack(spacing: Theme.Space.md) {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                    if serviceID != nil {
                        Button("Delete service", role: .destructive) { delete() }
                            .buttonStyle(.bordered)
                    }
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .navigationTitle(serviceID == nil ? "Add service" : "Edit service")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { hydrate() }
        #if os(macOS)
        .frame(minWidth: 460)
        #endif
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        keyboard: FieldKeyboard = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label).font(.subheadline.weight(.medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .studioField()
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(keyboard == .url ? .URL : .default)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel(label)
        }
    }

    private enum FieldKeyboard {
        case `default`
        case url
    }

    private func hydrate() {
        if let serviceID,
           let service = settings.onlineServices.first(where: { $0.id == serviceID })
        {
            draftID = service.id
            name = service.name
            baseURL = service.baseURL
            modelID = service.modelID ?? ""
            maximumOutputTokens = service.maximumOutputTokens.map(String.init) ?? ""
            enabled = service.isEnabled
        } else {
            baseURL = settings.openAIBaseURL
            enabled = settings.onlineServices.isEmpty
        }
        stored = (try? store.loadAPIKey(serviceID: draftID)) != nil
    }

    private func save() {
        guard let normalized = OpenAIServiceConfiguration.normalizedBaseURL(baseURL) else {
            status = "Base URL must be a valid https URL."
            return
        }
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMaxOutput = maximumOutputTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedMaxOutput = Int(trimmedMaxOutput)
        if !trimmedMaxOutput.isEmpty, parsedMaxOutput == nil || parsedMaxOutput! < 0 {
            status = "Max output tokens must be a non-negative integer (0 = unknown)."
            return
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            do {
                try store.saveAPIKey(trimmedKey, serviceID: draftID)
                stored = true
                key = ""
            } catch {
                status = "Couldn't save the key: \(error.localizedDescription)"
                return
            }
        }
        settings.upsertOnlineService(OnlineService(
            id: draftID,
            name: name,
            baseURL: normalized,
            modelID: trimmedModel.isEmpty ? nil : trimmedModel,
            maximumOutputTokens: parsedMaxOutput.flatMap { $0 > 0 ? $0 : nil },
            isEnabled: enabled
        ))
        dismiss()
    }

    private func delete() {
        settings.removeOnlineService(id: draftID)
        try? store.deleteAPIKey(serviceID: draftID)
        dismiss()
    }
}
