// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppUI

/// The chat composer (DESIGN §4): multiline auto-grow field, one morphing Send↔Stop button (no
/// reflow), an inline 🧠 thinking toggle, and a live context meter. Disabled when no model is loaded.
struct Composer: View {
    @Bindable var chat: ChatStore
    var thinkingCapable: Bool
    @FocusState private var focused: Bool

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
            HStack(alignment: .bottom, spacing: Theme.Space.sm) {
                if thinkingCapable { thinkingToggle }
                field
                sendOrStop
            }
        }
        .padding(Theme.Space.md)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().background(Theme.hairline) }
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
            .lineLimit(1...6)
            .focused($focused)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
            .disabled(!chat.hasModel)
            #if os(macOS)
            .onSubmit { if chat.canSend { chat.send() } }   // ⏎ sends on Mac; ⇧⏎ inserts a newline
            #endif
            .accessibilityLabel("Message")
    }

    private var placeholder: String {
        chat.hasModel ? "Message \(chat.activeModel?.model.displayName ?? "the model")…" : "Load a model to start"
    }

    // MARK: Thinking toggle

    private var thinkingToggle: some View {
        Button {
            withAnimation(Motion.select) { chat.thinkingEnabled.toggle() }
        } label: {
            Image(systemName: "brain")
                .font(.body)
                .foregroundStyle(chat.thinkingEnabled ? Theme.accent : Theme.textTertiary)
                .frame(width: 44, height: 44)
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
            if chat.isStreaming { chat.stop() } else { chat.send() }
        } label: {
            Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 44, height: 44)
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
