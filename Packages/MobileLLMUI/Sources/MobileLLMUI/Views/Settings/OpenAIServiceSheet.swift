// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Settings surface for the OpenAI Responses API service: a user-editable base URL (gateway/proxy
/// supported) plus the API key, which lives in the device Keychain only (this-device-only, off-backup);
/// it is never written to UserDefaults, settings backups, or the repo.
struct OpenAIServiceSheet: View {
    let settings: AppSettings
    let store: any OpenAICredentialStoring
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var baseURL = ""
    @State private var modelID = ""
    @State private var stored = false
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Label(stored ? "Key stored on this device" : "No key stored",
                          systemImage: stored ? "checkmark.circle.fill" : "key.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(stored ? Theme.fitGreen : Theme.textSecondary)
                    Text("Used by the Responses API when an online model is selected. It never leaves "
                         + "this device except in the request itself.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }

                Text("API base URL").font(.subheadline.weight(.medium))
                TextField("https://api.openai.com/v1", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("OpenAI API base URL")

                Text("API key").font(.subheadline.weight(.medium))
                SecureField("sk-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("OpenAI API key")
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Text("Model (optional)").font(.subheadline.weight(.medium))
                TextField("e.g. gpt-4o-mini", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("OpenAI model")

                HStack(spacing: Theme.Space.md) {
                    Button("Save") {
                        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let normalized = OpenAIServiceConfiguration.normalizedBaseURL(trimmedURL)
                        else {
                            status = "Base URL must be a valid https URL."
                            return
                        }
                        settings.openAIBaseURL = normalized
                        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.openAIModelID = trimmedModel.isEmpty ? nil : trimmedModel
                        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            do {
                                try store.saveAPIKey(trimmed)
                                stored = true
                                key = ""
                            } catch {
                                status = "Couldn't save the key: \(error.localizedDescription)"
                                return
                            }
                        }
                        status = "Saved."
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Remove key", role: .destructive) {
                        do {
                            try store.deleteAPIKey()
                            stored = false
                            key = ""
                            status = "Removed."
                        } catch {
                            status = "Couldn't remove the key: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(Theme.textSecondary)
                }

                Text("Keychain storage is pinned to this device (accessible after first unlock), is not "
                     + "synced to iCloud, and is excluded from backups. The key is never committed to the "
                     + "repository or written to Settings.")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle("OpenAI service")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            stored = (try? store.loadAPIKey()) != nil
            baseURL = settings.openAIBaseURL
            modelID = settings.openAIModelID ?? ""
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 380)
        #endif
    }
}
