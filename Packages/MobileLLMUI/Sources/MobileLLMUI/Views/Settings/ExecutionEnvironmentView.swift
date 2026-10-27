// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentRuntime

struct ExecutionEnvironmentView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var busy = false
    @State private var error: String?
    @State private var connecting: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $endpoint)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("execution.endpoint")
                SecureField(settings.sandboxConnection == nil ? "API key" : "API key (stored for this endpoint)", text: $apiKey)
                    .accessibilityIdentifier("execution.api-key")
                Button(busy ? "Checking…" : "Check and connect") { connect() }
                    .disabled(busy || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("execution.connect")
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(Theme.danger).font(.callout) }
            } header: { Text("OpenSandbox") } footer: {
                Text("Project files, commands and browser checks run on this server. The API key is stored in Keychain.")
            }
            if let connection = settings.sandboxConnection {
                Section {
                    Label("Connected to OpenSandbox \(connection.backendVersion)", systemImage: "checkmark.shield")
                        .foregroundStyle(Theme.fitGreen).accessibilityIdentifier("execution.connected")
                    Toggle("Allow for new tasks", isOn: $settings.sandboxEnabled)
                        .disabled(busy)
                        .accessibilityIdentifier("execution.enabled")
                    Text("New chats use this selection. For an existing chat, apply its tool settings before sending a new task.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Button("Remove saved connection", role: .destructive) {
                        connecting?.cancel()
                        do { try settings.disconnectSandbox(); apiKey = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("execution.remove")
                } header: { Text("Access") }
                Section {
                    if connection.capabilities.contains(.workspaceFiles) { Label("Workspace files", systemImage: "folder") }
                    if connection.capabilities.contains(.codeExecution) { Label("Commands and application servers", systemImage: "terminal") }
                    if connection.capabilities.contains(.applicationInspection) {
                        Label("Browser interaction and screenshots", systemImage: "globe")
                    }
                } header: { Text("Available capabilities") }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle("Execution environment")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear { endpoint = settings.sandboxConnection?.endpoint.absoluteString ?? "" }
        .onDisappear { connecting?.cancel() }
    }

    private func connect() {
        connecting?.cancel(); error = nil
        connecting = Task { @MainActor in
            busy = true
            defer { busy = false }
            do {
                let url = try OpenSandboxConnection.validatedEndpoint(endpoint)
                let key: String
                if !apiKey.isEmpty { key = apiKey }
                else if url == settings.sandboxConnection?.endpoint, let stored = try settings.sandboxAPIKey() { key = stored }
                else { throw OpenSandboxError.unavailable }
                let connection = try await OpenSandboxHTTPClient.connect(endpoint: url.absoluteString, apiKey: key)
                try Task.checkCancellation()
                try settings.configureSandbox(connection, apiKey: key)
                apiKey = ""
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
