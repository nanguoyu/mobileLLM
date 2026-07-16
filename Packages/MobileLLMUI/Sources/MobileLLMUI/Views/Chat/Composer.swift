// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// The chat composer (DESIGN §4): multiline auto-grow field, one morphing Send↔Stop button (no
/// reflow), an inline 🧠 thinking toggle, a mic for dictation, and a live context meter. When no model
/// is loaded the input is replaced by a compact hint that routes to the model picker — so a model-less
/// thread is browsable but sending is clearly gated.
struct Composer: View {
    @Bindable var chat: ChatStore
    var thinkingCapable: Bool
    /// True while a model is loading (cold start / switch) — shows a loading hint instead of the picker CTA.
    var isLoadingModel: Bool = false
    /// Route to the Models screen (the no-model CTA).
    var onOpenModels: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var dictation = DictationService()
    /// The draft text captured when dictation started, so live partial results replace (not duplicate).
    @State private var dictationBase = ""
    /// Composer controls scale with Dynamic Type instead of a hard 44pt.
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = 44

    private var usage: (used: Int, cap: Int) { chat.contextUsage() }

    private var meterColor: Color {
        let ratio = usage.cap > 0 ? Double(usage.used) / Double(usage.cap) : 0
        if ratio >= 0.98 { return Theme.danger }
        if ratio >= 0.85 { return Theme.fitAmber }
        return Theme.textTertiary
    }

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            contextMeter
            if chat.hasModel {
                HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                    if thinkingCapable { thinkingToggle }
                    micButton
                    field
                    sendOrStop
                }
            } else {
                noModelBar
            }
        }
        .padding(Theme.Space.md)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().background(Theme.hairline) }
        .onChange(of: dictation.transcript) { _, transcript in
            guard dictation.isRecording else { return }
            chat.draft = merge(base: dictationBase, dictated: transcript)
        }
        .onChange(of: dictation.state) { _, state in
            switch state {
            case .denied:
                chat.showToast(Toast("Allow microphone and speech access in Settings to dictate.",
                                     kind: .warning, autoDismiss: 4))
            case .unavailable:
                chat.showToast(Toast("Dictation isn't available for this language.",
                                     kind: .warning, autoDismiss: 4))
            case .idle, .recording:
                break
            }
        }
        .onDisappear { dictation.stop() }   // never leave the audio session running behind us
    }

    private func merge(base: String, dictated: String) -> String {
        if base.isEmpty { return dictated }
        if dictated.isEmpty { return base }
        return base + " " + dictated
    }

    // MARK: No-model hint

    private var noModelBar: some View {
        HStack(spacing: Theme.Space.sm) {
            if isLoadingModel {
                ProgressView().controlSize(.small)
                Text("Loading model…")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "cpu").foregroundStyle(Theme.accent)
                Text("Add a model to start chatting.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.sm)
                Button("Choose a model") { onOpenModels() }
                    .buttonStyle(StudioButtonStyle(.primary))
            }
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLoadingModel ? "Loading model" : "No model loaded")
        .accessibilityHint(isLoadingModel ? "" : "Choose a model to start chatting")
    }

    // MARK: Context meter

    private var contextMeter: some View {
        HStack(spacing: Theme.Space.xs) {
            Spacer()
            if usage.used > 0 {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption2).foregroundStyle(meterColor)
                Text(Format.context(usage.used, usage.cap))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(meterColor)
                    .accessibilityLabel("Context used")
                    .accessibilityValue("\(usage.used) of \(usage.cap) tokens")
            }
        }
        .frame(height: 14)
    }

    // MARK: Field

    private var field: some View {
        TextField(placeholder, text: $chat.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1...6)
            .focused($focused)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
            #if os(macOS)
            .onSubmit { if chat.canSend { chat.send(); focused = false } }   // ⏎ sends on Mac; ⇧⏎ inserts a newline
            #endif
            .accessibilityLabel("Message")
    }

    private var placeholder: String {
        "Message \(chat.activeModel?.model.displayName ?? "the model")…"
    }

    // MARK: Dictation

    private var micButton: some View {
        Button {
            if dictation.isRecording {
                dictation.stop()
            } else {
                dictationBase = chat.draft
                dictation.start()
            }
        } label: {
            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                .font(.body)
                .foregroundStyle(dictation.isRecording ? Theme.accent : Theme.textTertiary)
                .frame(width: controlSize, height: controlSize)
                .background(dictation.isRecording ? Theme.accentSoft : Theme.surface2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(alignment: .topTrailing) { if dictation.isRecording { RecordingDot() } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dictate")
        .accessibilityValue(dictation.isRecording ? "Recording" : "Off")
        .accessibilityAddTraits(dictation.isRecording ? [.isSelected] : [])
    }

    // MARK: Thinking toggle

    private var thinkingToggle: some View {
        Button {
            withAnimation(Motion.select) { chat.thinkingEnabled.toggle() }
        } label: {
            Image(systemName: "brain")
                .font(.body)
                .foregroundStyle(chat.thinkingEnabled ? Theme.accent : Theme.textTertiary)
                .frame(width: controlSize, height: controlSize)
                .background(chat.thinkingEnabled ? Theme.accentSoft : Theme.surface2,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thinking mode")
        .accessibilityValue(chat.thinkingEnabled ? "On" : "Off")
        .accessibilityAddTraits(chat.thinkingEnabled ? [.isSelected] : [])
    }

    // MARK: Send / Stop

    private var sendOrStop: some View {
        Button {
            if chat.isStreaming {
                chat.stop()
            } else {
                dictation.stop()
                chat.send()
                focused = false   // dismiss keyboard on send
            }
        } label: {
            Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: controlSize, height: controlSize)
                .background(sendBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!chat.isStreaming && !chat.canSend)
        .accessibilityLabel(chat.isStreaming ? "Stop" : "Send")
    }

    private var sendBackground: Color {
        if chat.isStreaming { return Theme.danger }
        return chat.canSend ? Theme.accent : Theme.fitGray
    }
}

/// The pulsing cinnabar seal dot that marks an active recording.
private struct RecordingDot: View {
    @State private var pulsing = false
    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 8, height: 8)
            .opacity(pulsing ? 1 : 0.3)
            .padding(4)
            .onAppear {
                guard !Motion.reduce else { pulsing = true; return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulsing = true }
            }
            .accessibilityHidden(true)
    }
}
