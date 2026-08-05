// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Settings (DESIGN §4): default model, chat behavior, sampling (progressive-disclosure Advanced),
/// appearance, data & privacy, and about. Section/row builders in a clean studio style.
struct SettingsView: View {
    let container: AppContainer
    @Bindable var settings: AppSettings
    @State private var confirmDeleteChats = false
    @State private var confirmEraseAll = false
    @State private var eraseError: String?
    @State private var storageBytes: Int64 = 0
    @State private var showTools = false
    @State private var showSystemPrompt = false
    @State private var showSkills = false
    @State private var showMemory = false
    @State private var showOpenAI = false

    init(container: AppContainer) {
        self.container = container
        self._settings = Bindable(wrappedValue: container.settings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                behaviorSection
                onlineSection
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
        .alert("Delete all chats?", isPresented: $confirmDeleteChats) {
            Button("Delete all chats", role: .destructive) { deleteAllChats() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every conversation and image attachment on this device. Models, memory, skills, "
                 + "settings, and MCP credentials are kept. This can't be undone.")
        }
        .alert("Erase all app data?", isPresented: $confirmEraseAll) {
            Button("Erase everything", role: .destructive) { eraseAllAppData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Returns mobileLLM to a fresh install. It permanently removes chats and attachments, "
                 + "memory, custom skills, settings, MCP credentials, community-model records, and every "
                 + "downloaded model. Calendar events or reminders already created outside the app are "
                 + "not changed. This can't be undone.")
        }
        .alert("Some data wasn't erased",
               isPresented: Binding(get: { eraseError != nil },
                                    set: { if !$0 { eraseError = nil } })) {
            Button("OK", role: .cancel) { eraseError = nil }
        } message: {
            Text(eraseError ?? "Try the erase again.")
        }
        // A sheet, not a push: the macOS detail column isn't inside a NavigationStack.
        .sheet(isPresented: $showTools) {
            NavigationStack {
                ToolsView(settings: settings,
                          eventStore: container.toolEventStore,
                          locationProvider: container.toolLocationProvider)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showSystemPrompt) {
            NavigationStack { SystemPromptEditor(settings: settings) }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
            #endif
        }
        .sheet(isPresented: $showSkills) {
            NavigationStack { SkillsView(store: container.skills) }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showMemory) {
            NavigationStack { MemoryView(book: container.memory, settings: settings) }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showOpenAI) {
            NavigationStack {
                OnlineServicesView(settings: settings, store: container.openAICredentials)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 440)
            #endif
        }
    }

    /// One-line status for the system-prompt row: the stock prompt, off, or a custom preview.
    private var systemPromptSummary: String {
        let text = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Off — no instructions are sent" }
        if SystemPrompt.isStandard(settings.systemPrompt) { return "Standard prompt" }
        return "Custom · \(text.replacingOccurrences(of: "\n", with: " ").prefix(60))"
    }

    // MARK: Model

    // There is deliberately NO "default model" or "engine preference" here anymore: conversations
    // remember their own model, an explicitly opened thread restores its choice, and a new chat uses the
    // last-used identity. Launch restores that identity without loading weights and leaves history
    // unselected. `settings.defaultModelID` is the auto-tracked fallback, never user-facing.

    // MARK: Behavior

    private var behaviorSection: some View {
        section("Behavior", icon: "text.bubble") {
            // A row, not an inline editor — the full-height TextEditor ate half the settings screen.
            Button { showSystemPrompt = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "text.quote")
                        .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System prompt").font(.subheadline).foregroundStyle(Theme.textPrimary)
                        Text(systemPromptSummary).font(.caption).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().background(Theme.hairline)
            skillsRow
            Divider().background(Theme.hairline)
            memoryRow
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
                    Text("Allow selected tools").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text("Only tools selected below are exposed to the model. The model decides whether "
                         + "to call one; every call adds another model pass, and network tools such as web "
                         + "search, Wikipedia, and remote MCP also wait for the network.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .tint(Theme.accent)
            manageToolsRow
        }
    }

    // MARK: Skills

    private var skillsRow: some View {
        Button { showSkills = true } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "sparkles")
                    .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(SkillsView.summary(for: container.skills))
                        .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Memory

    /// Its own row in Behavior, beside System prompt and Skills — memory is a thing the app knows about
    /// you, not a tool setting, and it was unreviewable while its only surface was a switch two screens
    /// deep in Choose tools. The switch stays there; what's remembered lives here.
    private var memoryRow: some View {
        Button { showMemory = true } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "bookmark")
                    .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(MemoryView.summary(book: container.memory, settings: settings))
                        .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The count comes from a mirror of the durable store; a chat that saved a fact while Settings was
        // on screen must not leave the row reading "Nothing saved yet".
        .task { await container.memory.refresh() }
    }

    // MARK: Choose tools

    // MARK: Online models

    @ViewBuilder private var onlineSection: some View {
        section("Online models", icon: "network") {
            Divider().background(Theme.hairline)
            Button { showOpenAI = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "key.horizontal")
                        .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Online services").font(.subheadline).foregroundStyle(Theme.textPrimary)
                        Text(onlineSummary)
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Online services")
            .accessibilityValue("\(settings.onlineServices.count) services")
            Text("Add one or more OpenAI-compatible services. Each key lives in the device Keychain "
                 + "only — never synced, backed up, or committed. Sends use the active service.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private var onlineSummary: String {
        if let service = settings.onlineActiveService {
            return "\(settings.onlineServices.count) service\(settings.onlineServices.count == 1 ? "" : "s") · On · \(service.name)"
        }
        if settings.onlineServices.isEmpty {
            return "No services configured"
        }
        return "\(settings.onlineServices.count) service\(settings.onlineServices.count == 1 ? "" : "s") · Off"
    }

    // MARK: Choose tools

    @ViewBuilder private var manageToolsRow: some View {
        Divider().background(Theme.hairline)
        Button { showTools = true } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose tools").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(ToolsView.summary(for: settings)).font(.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Sampling

    private var samplingSection: some View {
        section("Sampling", icon: "slider.horizontal.3") {
            sliderRow("Temperature", value: $settings.temperature, range: 0...1.5, step: 0.05, format: "%.2f")
            sliderRow("Top-p", value: $settings.topP, range: 0...1, step: 0.01, format: "%.2f")
            stepperRow("Max tokens", value: $settings.maxTokens, range: 128...4096, step: 128)
            if settings.openAIOnlineEnabled {
                HStack {
                    Text("Online max output").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Menu {
                        Button("Auto (model max)") { settings.onlineMaxTokens = 0 }
                        Divider()
                        ForEach([512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536],
                                id: \.self)
                        { value in
                            Button("\(value)") { settings.onlineMaxTokens = value }
                        }
                    } label: {
                        Text(settings.onlineMaxTokens == 0 ? "Auto" : "\(settings.onlineMaxTokens)")
                            .font(.subheadline).foregroundStyle(Theme.accent)
                    }
                    .fixedSize()
                }
                Text("Auto omits the limit so the service uses the model's own maximum; explicit values are sent as max_output_tokens.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
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
        let online = container.chat.isOnlineActive
        let model = contextModel
        let options = online
            ? OnlineModelIdentity.contextLadder
            : (model.map { ContextPolicy.options(for: $0) } ?? ContextPolicy.ladder)
        let shown = online
            ? min(settings.onlineContextLength, OnlineModelIdentity.maximumContextTokens)
            : (model.map { ContextPolicy.effective(requested: settings.contextLength, model: $0) }
                ?? settings.contextLength)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Context length").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach(options, id: \.self) { n in
                        Button {
                            if online { settings.onlineContextLength = n } else { settings.contextLength = n }
                        } label: {
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
        container.models.active?.model ?? container.models.model(id: settings.defaultModelID)
    }

    /// Green / amber / red per rung. `.tight` alone isn't the answer — it's returned both for "runs, but
    /// deep into the budget" and for "that context is way over the ceiling", so ask `ContextPolicy.fits`.
    private func fitSymbol(_ n: Int) -> String {
        // Online inference owns no device KV cache: every rung up to the service window fits.
        if container.chat.isOnlineActive { return "circle.fill" }
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
        if container.chat.isOnlineActive {
            let window = Format.shortCount(OnlineModelIdentity.maximumContextTokens)
            return "Online services use the setting as-is, up to the service window (\(window)); device "
                + "RAM doesn't bind it. Longer context costs more tokens on the service."
        }
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
            Button(role: .destructive) { confirmDeleteChats = true } label: {
                Label("Delete all chats", systemImage: "trash")
            }
            .buttonStyle(StudioButtonStyle(.secondary))
            Button(role: .destructive) { confirmEraseAll = true } label: {
                Label("Erase all app data", systemImage: "externaldrive.badge.xmark")
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
            return base + " Nothing is sent to a server. (Turning on Tools lets the model reach the web — "
                 + "search, a webpage reader, Wikipedia — or an MCP server you configure, and lets tools you "
                 + "enable touch your calendar, reminders, or location, but only when it invokes that tool.)"
        }
        let hasMCP = settings.mcpServers.contains(where: \.isEnabled)
        return base + " Tools are on: when the model uses a web tool it sends that query or its arguments to "
             + "that endpoint — a search engine, a page you link, or Wikipedia"
             + (hasMCP ? ", or an MCP server you've enabled." : " (and any MCP server you add).")
             + " The calendar, reminders, and location tools read or write that system data only when the "
             + "model calls them, each asks the system for permission when selected, and only if you select "
             + "it in Choose tools."
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

    private func deleteAllChats() {
        Task {
            do {
                try await container.deleteAllChats()
                storageBytes = await container.conversationStore.storageBytes()
                container.chat.showToast(Toast("All chats and attachments deleted", kind: .success))
            } catch {
                container.chat.showToast(Toast("Chats couldn't be deleted: \(error.localizedDescription)",
                                               kind: .error, autoDismiss: nil))
            }
        }
    }

    private func eraseAllAppData() {
        Task {
            do {
                try await container.eraseAllAppData()
                storageBytes = 0
                container.chat.showToast(Toast("All mobileLLM data erased", kind: .success))
            } catch {
                eraseError = error.localizedDescription
                storageBytes = await container.conversationStore.storageBytes()
            }
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

/// The system-prompt editor, in its own sheet — full-height editing space without eating the settings
/// screen. Reset restores the stock prompt; clearing it entirely is a valid "off" state that sticks.
struct SystemPromptEditor: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Prepended to every chat. Keep it short — it's charged to the context window on "
                     + "every turn, and small models follow three sharp rules better than ten soft ones.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $settings.systemPrompt)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 280)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.xs)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .strokeBorder(Theme.hairline))
                    .accessibilityLabel("System prompt")
                if !SystemPrompt.isStandard(settings.systemPrompt) {
                    Button("Reset to the standard prompt") { settings.systemPrompt = SystemPrompt.standard }
                        .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .navigationTitle("System prompt")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(container: AppContainer.preview())
}
#endif
