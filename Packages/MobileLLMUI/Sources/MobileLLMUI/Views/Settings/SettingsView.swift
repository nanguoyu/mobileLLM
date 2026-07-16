// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Settings (DESIGN §4): default model, chat behavior, sampling (progressive-disclosure Advanced),
/// appearance, data & privacy, and about. Section/row builders in a clean studio style.
struct SettingsView: View {
    let container: AppContainer
    @Bindable var settings: AppSettings
    @State private var confirmDeleteAll = false
    @State private var storageBytes: Int64 = 0
    @State private var showAddMCP = false
    @State private var newMCPName = ""
    @State private var newMCPURL = ""
    @State private var newMCPToken = ""

    init(container: AppContainer) {
        self.container = container
        self._settings = Bindable(wrappedValue: container.settings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                modelSection
                behaviorSection
                samplingSection
                appearanceSection
                privacySection
                aboutSection
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.xl)
        }
        .scrollDismissesKeyboard(.interactively)   // drag to dismiss the system-prompt keyboard
        .background(Theme.bg)
        .task { storageBytes = await container.conversationStore.storageBytes() }
        .alert("Delete all data?", isPresented: $confirmDeleteAll) {
            Button("Delete everything", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every conversation on this device. Downloaded models are kept. This can't be undone.")
        }
        .sheet(isPresented: $showAddMCP) { addMCPSheet }
    }

    // MARK: Model

    private var modelSection: some View {
        section("Model", icon: "cpu") {
            HStack {
                Text("Default model").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach(container.models.catalog) { model in
                        Button(model.displayName) { settings.defaultModelID = model.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(LLMCatalog.model(id: settings.defaultModelID)?.displayName ?? "Choose")
                            .font(.subheadline).foregroundStyle(Theme.accent)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                }
                .fixedSize()
            }
            Text("Used for new chats. Manage downloads on the Models screen.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
            Divider().background(Theme.hairline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Inference engine").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Segmented(selection: $settings.enginePreference, options: EnginePreference.allCases) { $0.label }
                    .accessibilityLabel("Inference engine")
                Text("Auto picks the best-fitting engine for your device. MLX keeps weights resident; "
                     + "llama.cpp memory-maps them — better for large models on memory-tight phones.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Behavior

    private var behaviorSection: some View {
        section("Behavior", icon: "text.bubble") {
            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt").font(.subheadline).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $settings.systemPrompt)
                    .font(.callout)
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.xs)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
                    .accessibilityLabel("System prompt")
                Text("Sets the assistant's persona + rules for every new chat.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Divider().background(Theme.hairline)
            Toggle(isOn: $settings.thinkingDefault) {
                Text("Thinking mode by default").font(.subheadline).foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Show reasoning").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Segmented(selection: $settings.thinkingDisplay, options: ThinkingDisplayMode.allCases) { $0.label }
            }
            Divider().background(Theme.hairline)
            Toggle(isOn: $settings.toolsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tools").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text("Let the model use a calculator and the clock (on-device) and a Wikipedia lookup "
                         + "(reaches the network only when it searches). Adds a round-trip; some models call "
                         + "tools more reliably than others.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .tint(Theme.accent)
            if settings.toolsEnabled { mcpServers }
        }
    }

    // MARK: MCP servers

    @ViewBuilder private var mcpServers: some View {
        Divider().background(Theme.hairline)
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("MCP servers").font(.subheadline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { newMCPName = ""; newMCPURL = ""; newMCPToken = ""; showAddMCP = true } label: {
                    Label("Add", systemImage: "plus").font(.caption.weight(.medium))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            Text("Connect remote Model Context Protocol servers (HTTPS) to give the model more tools.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
            ForEach(settings.mcpServers) { server in
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.caption).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.name).font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        Text(server.url).font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer()
                    Button(role: .destructive) { removeMCP(server) } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Remove \(server.name)")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func removeMCP(_ server: MCPServer) {
        settings.mcpServers.removeAll { $0.id == server.id }
    }

    private func addMCP() {
        let url = newMCPURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let name = newMCPName.trimmingCharacters(in: .whitespaces)
        let token = newMCPToken.trimmingCharacters(in: .whitespaces)
        settings.mcpServers.append(MCPServer(name: name.isEmpty ? url : name, url: url,
                                             token: token.isEmpty ? nil : token))
        showAddMCP = false
    }

    private var addMCPSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Add a remote MCP server. Only HTTPS servers work on device; a token is optional.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    mcpField("Name", text: $newMCPName, placeholder: "My server")
                    mcpField("Server URL", text: $newMCPURL, placeholder: "https://host/mcp", mono: true)
                    mcpField("Bearer token (optional)", text: $newMCPToken, placeholder: "", mono: true, secure: true)
                }
                .padding(Theme.Space.lg)
            }
            .background(Theme.bg)
            .navigationTitle("New MCP server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAddMCP = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addMCP() }
                        .disabled(newMCPURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
    }

    private func mcpField(_ label: String, text: Binding<String>, placeholder: String,
                          mono: Bool = false, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textFieldStyle(.plain)
            .font(mono ? .callout.monospaced() : .callout)
            #if os(iOS)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            #endif
            .padding(Theme.Space.sm)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    // MARK: Sampling

    private var samplingSection: some View {
        section("Sampling", icon: "slider.horizontal.3") {
            sliderRow("Temperature", value: $settings.temperature, range: 0...1.5, step: 0.05, format: "%.2f")
            sliderRow("Top-p", value: $settings.topP, range: 0...1, step: 0.01, format: "%.2f")
            stepperRow("Max tokens", value: $settings.maxTokens, range: 128...4096, step: 128)
            HStack {
                Text("Context length").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach([2048, 4096, 8192, 16384, 32768], id: \.self) { n in
                        Button(Format.shortCount(n)) { settings.contextLength = n }
                    }
                } label: {
                    Text(Format.shortCount(settings.contextLength)).font(.subheadline).foregroundStyle(Theme.accent)
                }
                .fixedSize()
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    stepperRow("Top-k", value: $settings.topK, range: 0...100, step: 5)
                    sliderRow("Repetition penalty", value: $settings.repetitionPenalty, range: 1...1.5, step: 0.01, format: "%.2f")
                    HStack {
                        Text("KV cache").font(.subheadline).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Menu {
                            Button("Full (unquantized)") { settings.kvBits = 0 }
                            Button("4-bit") { settings.kvBits = 4 }
                            Button("8-bit") { settings.kvBits = 8 }
                        } label: {
                            Text(settings.kvBits == 0 ? "Full" : "\(settings.kvBits)-bit")
                                .font(.subheadline).foregroundStyle(Theme.accent)
                        }
                        .fixedSize()
                    }
                    Text("4-bit KV keeps context memory low with little quality cost — the main memory lever.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, Theme.Space.xs)
            }
            .tint(Theme.accent)
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        section("Appearance", icon: "circle.lefthalf.filled") {
            Segmented(selection: $settings.appearance, options: AppearanceMode.allCases) { $0.label }
                .accessibilityLabel("Theme")
            Text("Match your system, or pin to Light or Dark.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Data & Privacy

    private var privacySection: some View {
        section("Data & Privacy", icon: "lock.shield") {
            Text("Everything is on-device. Your chats, prompts, and the model all stay on this device — "
                 + "nothing is sent to a server, and there's no account.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            row("Conversations on disk", Format.bytes(storageBytes))
            Button { Task { await exportAll() } } label: {
                Label("Export all chats (JSON)", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(StudioButtonStyle(.secondary))
            Button(role: .destructive) { confirmDeleteAll = true } label: {
                Label("Delete all data", systemImage: "trash")
            }
            .buttonStyle(StudioButtonStyle(.secondary))
        }
    }

    // MARK: About

    private var aboutSection: some View {
        section("About", icon: "info.circle") {
            row("Version", appVersion)
            row("Engine", "Pure Swift · MLX + llama.cpp")
            Text("A private, open-source runner for open-weight language models — everything runs on your "
                 + "device, nothing is sent to a server. Each model's provider and license are shown on "
                 + "its card in Models.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    // MARK: Actions

    private func deleteAll() {
        Task {
            try? await container.conversationStore.deleteAll()
            container.chat.reloadAfterWipe()
            storageBytes = await container.conversationStore.storageBytes()
            container.chat.showToast(Toast("All conversations deleted", kind: .success))
        }
    }

    private func exportAll() async {
        // MVP export: copy a JSON bundle of every chat to the clipboard. File/share export is TODO(v1.0).
        let convos = await container.conversationStore.loadAllLive()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(convos), let json = String(data: data, encoding: .utf8) {
            Clipboard.copy(json)
            container.chat.showToast(Toast("Copied \(convos.count) chats as JSON", kind: .success))
        }
    }

    // MARK: Builders

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label { Text(title.uppercased()) } icon: { Image(systemName: icon) }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }

    private func section(_ title: String, icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel(title, icon: icon)
            VStack(alignment: .leading, spacing: Theme.Space.md) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioCard()
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(key).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.md)
            Text(value).font(.subheadline).foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(key).accessibilityValue(value)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            Slider(value: value, in: range, step: step).tint(Theme.accent)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: format, value.wrappedValue))
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(value.wrappedValue)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
        }
        .accessibilityValue("\(value.wrappedValue)")
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(container: AppContainer.preview())
}
#endif
