// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// A blinking caret shown at the tail of a streaming answer. Reduce-Motion → a steady bar.
struct TypingCaret: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(width: 8, height: 16)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                guard !Motion.reduce else { on = true; return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = false }
            }
            .accessibilityHidden(true)
    }
}

/// The user turn — a right-aligned accent bubble (DESIGN §4).
struct UserBubble: View {
    let message: Message
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.answer)
                .font(.body)
                .foregroundStyle(Theme.onAccent)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .contextMenu {
                    Button { onCopy?() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if onEdit != nil {
                        Button { onEdit?() } label: { Label("Edit & resend", systemImage: "pencil") }
                    }
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said")
        .accessibilityValue(message.answer)
    }
}

/// The assistant turn — full-width document text (no bubble) so markdown + code read cleanly
/// (DESIGN §4). Drives the thinking disclosure, an optional streaming caret, and a quiet action bar.
struct AssistantView: View {
    let reasoning: String
    let answer: String
    let disclosurePhase: ThinkingDisclosure.Phase
    let displayMode: ThinkingDisplayMode
    let isStreaming: Bool
    let stats: Stats?
    let modelName: String
    var onCopy: (() -> Void)?
    var onRegenerate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if !reasoning.isEmpty {
                ThinkingDisclosure(reasoning: reasoning, phase: disclosurePhase, displayMode: displayMode)
            }
            if !answer.isEmpty {
                answerBody
            } else if isStreaming && reasoning.isEmpty {
                // Warming: nothing to show yet — the composer owns the shimmer; keep a caret anchor.
                HStack(spacing: 4) { TypingCaret() }
            }
            if !isStreaming, let stats {
                statsFooter(stats)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var answerBody: some View {
        Group {
            if isStreaming {
                // Streaming: throttled markdown (~20 fps) with an inline block caret riding the tail —
                // a separate caret view can't sit at the end of block-rendered markdown, so the glyph is
                // appended to the text itself.
                StreamingMarkdown(text: answer)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    MarkdownMessage(text: answer)
                    actionBar
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: Theme.Space.md) {
            if let onCopy {
                Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Copy answer")
            }
            if let onRegenerate {
                Button { onRegenerate() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Regenerate answer")
            }
            Spacer()
        }
        .font(.caption)
        .padding(.top, 2)
    }

    private func statsFooter(_ stats: Stats) -> some View {
        Text(Format.statsFooter(stats, modelName: modelName))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            .accessibilityLabel("Generation stats")
            .accessibilityValue(Format.statsFooter(stats, modelName: modelName))
    }
}
