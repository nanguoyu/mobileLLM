// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts
import AgentRuntime
import LLMCore

/// Per-conversation settings (spec §20): reasoning + effort, approval mode, context, sampling, and the
/// reserved future slots (folder/file access and a shell terminal). Opened from the conversation's
/// top-right Settings button; New Chat lives in the list and ⌘N.
struct ConversationSettingsView: View {
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss

    private var chat: ChatStore { container.chat }
    private var settings: AppSettings { container.settings }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    reasoningSection
                    approvalSection
                    contextSection
                    samplingSection
                    futureSection
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .navigationTitle("Conversation settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
    }

    // MARK: Reasoning

    private var reasoningSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Reasoning")
            Toggle(isOn: Binding(get: { chat.composerThinkingEnabled },
                                 set: { chat.composerThinkingEnabled = $0 })) {
                Text("Thinking").font(.subheadline).foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            HStack {
                Text("Effort").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                        Button { chat.conversationReasoningEffort = effort } label: {
                            if chat.effectiveReasoningEffort == effort {
                                Label(effort.rawValue.capitalized, systemImage: "checkmark")
                            } else {
                                Text(effort.rawValue.capitalized)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(chat.effectiveReasoningEffort.rawValue.capitalized)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            Text("Effort applies to services that expose a reasoning-effort knob; local engines treat it "
                 + "as advisory. Medium is the default.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.md)
        .studioCard()
    }

    // MARK: Approval

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Approval")
            approvalOption("Ask", mode: .ask,
                           detail: "Approve per policy: external reads and online inference on first use")
            approvalOption("Safe preset", mode: .safePreset,
                           detail: "Auto-approve in-app/reads and online model; ask for writes and dangerous actions")
            approvalOption("Full access", mode: .fullAccess,
                           detail: "Auto-approve everything inside the run ceiling")
            if chat.conversationApprovalMode != nil {
                Divider()
                Button(role: .destructive) {
                    chat.conversationApprovalMode = nil
                } label: {
                    HStack(spacing: Theme.Space.sm) {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundStyle(Theme.textTertiary)
                        Text("Reset to default (Safe preset)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("approval.reset-default")
            }
            Text("A conversation without an override follows the product default — currently Safe "
                 + "preset.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.md)
        .studioCard()
    }

    private func approvalOption(
        _ title: String,
        mode: AgentApprovalMode?,
        detail: String
    ) -> some View {
        let isSelected = mode.map { chat.effectiveApprovalMode == $0 } ?? false
        return Button {
            chat.conversationApprovalMode = mode
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Context

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Context")
            HStack {
                Text("Context length").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    Button {
                        chat.setConversationContextLength(nil)
                    } label: {
                        if chat.conversationContextOverride == nil {
                            Label("Follow settings (\(Format.shortCount(contextDefault)))",
                                  systemImage: "checkmark")
                        } else {
                            Text("Follow settings (\(Format.shortCount(contextDefault)))")
                        }
                    }
                    Divider()
                    ForEach(contextOptions, id: \.self) { n in
                        Button {
                            chat.setConversationContextLength(n)
                        } label: {
                            if chat.conversationContextOverride == n {
                                Label(Format.shortCount(n), systemImage: "checkmark")
                            } else {
                                Text(Format.shortCount(n))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Format.shortCount(contextShown))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            Text(contextFootnote).font(.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.md)
        .studioCard()
    }

    private var contextOptions: [Int] {
        if chat.isOnlineActive { return OnlineModelIdentity.contextLadder }
        guard let model = chat.activeModel?.model else { return ContextPolicy.ladder }
        return ContextPolicy.options(for: model)
    }

    private var contextDefault: Int {
        chat.isOnlineActive ? settings.onlineContextLength : settings.contextLength
    }

    private var contextShown: Int {
        if chat.isOnlineActive {
            return min(chat.onlineContextRequest, OnlineModelIdentity.maximumContextTokens)
        }
        if let model = chat.activeModel?.model {
            return ContextPolicy.effective(requested: chat.localContextRequest, model: model)
        }
        return chat.localContextRequest
    }

    private var contextFootnote: String {
        if chat.isOnlineActive {
            return "Online services use the setting up to the service window; device RAM doesn't bind it."
        }
        return "Local models are clamped by their native context and device memory."
    }

    // MARK: Sampling

    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Sampling")
            samplingRow("Temperature", value: String(format: "%.2f", chat.conversationTemperature),
                        options: [0.0, 0.2, 0.5, 0.7, 0.9, 1.0],
                        defaultLabel: String(format: "%.2f", settings.temperature),
                        selected: { chat.conversationSamplingOverride?.temperature },
                        set: { chat.setConversationTemperature($0) })
            samplingRow("Top-p", value: String(format: "%.2f", chat.conversationTopP),
                        options: [0.8, 0.9, 0.95, 1.0],
                        defaultLabel: String(format: "%.2f", settings.topP),
                        selected: { chat.conversationSamplingOverride?.topP },
                        set: { chat.setConversationTopP($0) })
            samplingRow("Max tokens", value: chat.conversationOutputBudgetLabel,
                        options: chat.isOnlineActive
                            ? [0, 512, 1_024, 2_048, 4_096, 8_192, 16_384]
                            : [512, 1_024, 2_048, 4_096],
                        defaultLabel: chat.isOnlineActive
                            ? (settings.onlineMaxTokens == 0 ? "Auto" : "\(settings.onlineMaxTokens)")
                            : "\(settings.maxTokens)",
                        selected: { chat.conversationSamplingOverride?.maxTokens.map(Double.init) },
                        set: { chat.setConversationMaxTokens($0.map(Int.init)) },
                        label: {
                            chat.isOnlineActive && $0 == 0 ? "Auto (model max)" : "\(Int($0))"
                        })
            if chat.isOnlineActive {
                Text("Auto lets the online service use the model's own output maximum; explicit values clamp to the service window.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Space.md)
        .studioCard()
    }

    private func samplingRow<Value: Hashable>(
        _ title: String,
        value: String,
        options: [Value],
        defaultLabel: String,
        selected: @escaping () -> Value?,
        set: @escaping (Value?) -> Void,
        label: @escaping (Value) -> String = { String(describing: $0) }
    ) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            Menu {
                Button { set(nil) } label: {
                    if selected() == nil {
                        Label("Follow (\(defaultLabel))", systemImage: "checkmark")
                    } else {
                        Text("Follow (\(defaultLabel))")
                    }
                }
                Divider()
                ForEach(options, id: \.self) { option in
                    Button { set(option) } label: {
                        if selected() == option {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: Future slots

    private var futureSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            sectionTitle("Workspace")
            futureRow("Files", systemImage: "folder", detail: "Folder browsing and file reading — coming soon")
            futureRow("Terminal", systemImage: "terminal", detail: "Shell terminal window — coming soon")
        }
        .padding(Theme.Space.md)
        .studioCard()
    }

    private func futureRow(_ title: String, systemImage: String, detail: String) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: systemImage).foregroundStyle(Theme.textTertiary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Text(detail).font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
    }
}
