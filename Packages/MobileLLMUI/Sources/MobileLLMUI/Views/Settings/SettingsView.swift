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
    @State private var showMCP = false

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
        // A sheet, not a push: the macOS detail column isn't inside a NavigationStack.
        .sheet(isPresented: $showMCP) {
            NavigationStack { MCPServersView(settings: settings) }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
    }

    // MARK: Model

    private var modelSection: some View {
        section("Model", icon: "cpu") {
            HStack {
                Text("Default model").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    // Spans adopted community models too, so a downloaded Explore model can be the default.
                    ForEach(container.models.allModels) { model in
                        Button(model.displayName) { settings.defaultModelID = model.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(container.models.model(id: settings.defaultModelID)?.displayName ?? "Choose")
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
                HStack {
                    Text("System prompt").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if !SystemPrompt.isStandard(settings.systemPrompt) {
                        Button("Reset to default") { settings.systemPrompt = SystemPrompt.standard }
                            .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    }
                }
                TextEditor(text: $settings.systemPrompt)
                    .font(.callout)
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.xs)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
                    .accessibilityLabel("System prompt")
                Text("Prepended to every chat. Keep it short — it's charged to the context window on every "
                     + "turn, and small models follow three sharp rules better than ten soft ones.")
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
            if settings.toolsEnabled { mcpRow }
        }
    }

    // MARK: MCP servers

    @ViewBuilder private var mcpRow: some View {
        Divider().background(Theme.hairline)
        Button { showMCP = true } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP servers").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(mcpSummary).font(.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var mcpSummary: String {
        let all = settings.mcpServers
        guard !all.isEmpty else { return "Connect a remote server for more tools" }
        let on = all.count(where: \.isEnabled)
        return "\(all.count) configured" + (on < all.count ? " · \(all.count - on) off" : "")
    }

    // MARK: Sampling

    private var samplingSection: some View {
        section("Sampling", icon: "slider.horizontal.3") {
            sliderRow("Temperature", value: $settings.temperature, range: 0...1.5, step: 0.05, format: "%.2f")
            sliderRow("Top-p", value: $settings.topP, range: 0...1, step: 0.01, format: "%.2f")
            stepperRow("Max tokens", value: $settings.maxTokens, range: 128...4096, step: 128)
            contextRow
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
                    Text("4-bit KV keeps context memory low with little quality cost — the main memory lever. "
                         + "It's active on both engines; a change takes effect from your next message.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, Theme.Space.xs)
            }
            .tint(Theme.accent)
        }
    }

    // MARK: Context length

    /// Context is only meaningful **relative to a model**: the ladder stops at what the default model was
    /// trained for, and each rung carries the fit dot for this device — because the ceiling that actually
    /// binds is RAM, not the checkpoint. (A 9B trained to 256K still only fits ~16K on an 8 GB phone.)
    @ViewBuilder private var contextRow: some View {
        let model = contextModel
        let options = model.map { ContextPolicy.options(for: $0) } ?? ContextPolicy.ladder
        let shown = model.map { ContextPolicy.effective(requested: settings.contextLength, model: $0) }
            ?? settings.contextLength
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Context length").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach(options, id: \.self) { n in
                        Button { settings.contextLength = n } label: {
                            // The dot is the point: it says which rungs this device can actually hold.
                            Label(Format.shortCount(n), systemImage: fitSymbol(n))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Format.shortCount(shown)).font(.subheadline).foregroundStyle(Theme.accent)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .fixedSize()
            }
            Text(contextFootnote).font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    /// The model the ladder is measured against — whatever a new chat will actually load (adopted too).
    private var contextModel: LLMModel? {
        container.models.model(id: settings.defaultModelID) ?? container.models.active?.model
    }

    /// Green / amber / red per rung. `.tight` alone isn't the answer — it's returned both for "runs, but
    /// deep into the budget" and for "that context is way over the ceiling", so ask `ContextPolicy.fits`.
    private func fitSymbol(_ n: Int) -> String {
        guard let model = contextModel else { return "circle" }
        let device = container.models.device
        let variant = AppSettings.preferredVariant(for: model, device: device,
                                                   preference: settings.enginePreference, context: n)
        if LLMMemoryGovernor.plan(model: model, variant: variant, device: device, context: n) == .comfortable {
            return "circle.fill"
        }
        return ContextPolicy.fits(model: model, variant: variant, device: device, context: n)
            ? "exclamationmark.circle" : "xmark.circle"
    }

    private var contextFootnote: String {
        guard let model = contextModel else {
            return "How much conversation the model can see at once."
        }
        let native = Format.shortCount(model.architecture.nativeContext)
        let variant = AppSettings.preferredVariant(for: model, device: container.models.device,
                                                   preference: settings.enginePreference,
                                                   context: settings.contextLength)
        let fits = Format.shortCount(ContextPolicy.largestFitting(model: model, variant: variant,
                                                                  device: container.models.device))
        let clamped = ContextPolicy.effective(requested: settings.contextLength, model: model) < settings.contextLength
        let head = clamped
            ? "\(model.displayName) tops out at \(native), so that's what it runs at."
            : "\(model.displayName) supports up to \(native); this device holds about \(fits)."
        return head + " Longer context costs memory (it's the KV cache) and slows the first token — "
             + "it doesn't make the model smarter."
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
            Text(privacyBlurb)
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// Honest privacy copy: local by default, but tell the truth about what Tools can send and only when.
    /// Claiming "nothing is sent to a server" is false the moment a tool call reaches Wikipedia or an MCP
    /// server, so the sentence changes with the Tools setting.
    private var privacyBlurb: String {
        let base = "Your chats, prompts, and the models stay on this device — there's no account and no telemetry."
        guard settings.toolsEnabled else {
            return base + " Nothing is sent to a server. (Turning on Tools lets the model reach Wikipedia, or "
                 + "an MCP server you configure, but only when it invokes that tool.)"
        }
        let hasMCP = settings.mcpServers.contains(where: \.isEnabled)
        return base + " Tools are on: when the model uses one, it sends that query or its arguments to that "
             + "endpoint — Wikipedia for a lookup"
             + (hasMCP ? ", or an MCP server you've enabled." : " (and any MCP server you add).")
    }

    // MARK: About

    private var aboutSection: some View {
        section("About", icon: "info.circle") {
            row("Version", appVersion)
            row("Engine", "Pure Swift · MLX + llama.cpp")
            Text("A private, open-source runner for open-weight language models — everything runs on your "
                 + "device by default, with no account. The optional Tools feature can reach Wikipedia or "
                 + "MCP servers you configure, only when the model calls them. Each model's provider and "
                 + "license are shown on its card in Models.")
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

#if os(macOS)
/// The content of the macOS Settings scene (⌘,). Public so the App's `Settings { }` scene can host the
/// (internal) `SettingsView` with the app's tint + appearance applied. `NavigationStack` gives the sheets
/// it presents (MCP servers) a bar to hang their Done button on.
public struct MacSettingsWindow: View {
    private let container: AppContainer
    public init(container: AppContainer) { self.container = container }
    public var body: some View {
        NavigationStack {
            SettingsView(container: container)
        }
        .frame(minWidth: 480, minHeight: 560)
        .tint(Theme.accent)
        .background(Theme.bg)
        .preferredColorScheme(container.settings.appearance.colorScheme)
    }
}
#endif

#if DEBUG
#Preview("Settings") {
    SettingsView(container: AppContainer.preview())
}
#endif
