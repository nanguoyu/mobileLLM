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

/// A single tool the assistant invoked — a running spinner while it works, the seal (✓) + result when
/// it returns. The red seal is the app's mark of a completed, authentic action.
struct ToolActivityRow: View {
    let run: ToolRun
    private var argSummary: String {
        guard let data = run.arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !obj.isEmpty else { return "" }
        return obj.map { "\($0.value)" }.joined(separator: ", ")
    }
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if run.result == nil {
                ProgressView().controlSize(.mini).tint(Theme.accent)
            } else {
                Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(run.result == nil ? "Using \(prettyName)…" : prettyName + (argSummary.isEmpty ? "" : "(\(argSummary))"))
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let r = run.result {
                    Text("→ \(r)").font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.result == nil ? "Using \(prettyName)" : "\(prettyName) returned \(run.result ?? "")")
    }
    private var prettyName: String { run.name.replacingOccurrences(of: "_", with: " ").capitalized }
}

/// A committed assistant turn that produced no answer — the user tapped Stop, or generation failed.
/// A compact, honest row with a working Retry, in place of the old "0 tok · stop: cancelled" ghost.
struct EmptyReplyRow: View {
    let outcome: Message.EmptyOutcome
    var onRetry: (() -> Void)?

    private var label: String { outcome == .stopped ? "Stopped" : "Couldn't generate a reply" }
    private var icon: String { outcome == .stopped ? "stop.circle" : "exclamationmark.triangle" }
    private var tint: Color { outcome == .stopped ? Theme.textTertiary : Theme.danger }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(label).font(.subheadline).foregroundStyle(Theme.textSecondary)
            if let onRetry {
                Button { onRetry() } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
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
    var toolRuns: [ToolRun] = []
    /// Set when a completed turn produced no answer (stopped / failed) — renders the Retry row instead of
    /// a ghost stats line.
    var emptyOutcome: Message.EmptyOutcome?
    var onCopy: (() -> Void)?
    var onRegenerate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if !reasoning.isEmpty {
                ThinkingDisclosure(reasoning: reasoning, phase: disclosurePhase, displayMode: displayMode)
            }
            if !toolRuns.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(toolRuns) { ToolActivityRow(run: $0) }
                }
            }
            if !answer.isEmpty {
                answerBody
            } else if !isStreaming, let emptyOutcome {
                // Interrupted/failed before the first token: an honest, retryable row — not a "0 tok" ghost.
                EmptyReplyRow(outcome: emptyOutcome, onRetry: onRegenerate)
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
