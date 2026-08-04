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

/// The user turn — a right-aligned accent bubble (DESIGN §4), with any attached image thumbnails stacked
/// above the text. An image-only turn (no text) shows just the thumbnails.
struct UserBubble: View {
    let message: Message
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Loads a committed attachment's bytes from the store (nil on the previews/paths that don't render them).
    var attachmentLoader: ((ImageRef) async -> Data?)?

    private var attachments: [ImageRef] { message.attachments ?? [] }

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if !attachments.isEmpty, let attachmentLoader {
                    AttachmentThumbnails(refs: attachments, load: attachmentLoader)
                }
                if !message.answer.isEmpty {
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
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard !attachments.isEmpty else { return message.answer }
        let noun = attachments.count == 1 ? "attached image" : "\(attachments.count) attached images"
        return message.answer.isEmpty ? noun : "\(noun). \(message.answer)"
    }
}

/// The image attachments on a user turn — one thumbnail up to ~200pt, or a 2-up grid for several.
struct AttachmentThumbnails: View {
    let refs: [ImageRef]
    let load: (ImageRef) async -> Data?

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.xs),
                            count: refs.count == 1 ? 1 : 2)
        LazyVGrid(columns: columns, alignment: .trailing, spacing: Theme.Space.xs) {
            ForEach(refs) { ref in
                AttachmentThumbnail(ref: ref, load: load)
            }
        }
        .frame(maxWidth: refs.count == 1 ? 200 : 220)
    }
}

/// One attachment thumbnail — loads its bytes lazily from the store, decodes, and renders rounded.
struct AttachmentThumbnail: View {
    let ref: ImageRef
    let load: (ImageRef) async -> Data?
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.surface2)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        .task(id: ref.id) {
            if image == nil, let data = await load(ref), let decoded = Image(attachmentData: data) {
                image = decoded
            }
        }
        .accessibilityLabel("attached image")
    }
}

/// Pure display policy for a tool run. A memory's canonical English sentence is internal data: chat shows
/// whether it was saved, while Settings → Memory remains the transparent, editable source of truth.
struct ToolActivityPresentation: Equatable {
    enum State: Equatable { case running, succeeded, failed }

    let state: State
    let title: String
    let detail: String?
    let accessibilityLabel: String

    init(run: ToolRun) {
        if run.name == ToolID.remember.rawValue {
            if run.result == nil {
                state = .running
                title = "Saving to memory…"
            } else if run.result.map(Self.isFailureResult) == true {
                state = .failed
                title = "Couldn't save to memory"
            } else if run.result == "Already in memory." {
                state = .succeeded
                title = "Already in memory"
            } else {
                state = .succeeded
                title = "Saved to memory"
            }
            detail = nil
            accessibilityLabel = title
            return
        }

        let prettyName = run.name.replacingOccurrences(of: "_", with: " ").capitalized
        let summary = Self.argumentSummary(run.arguments)
        let invocation = prettyName + (summary.isEmpty ? "" : "(\(summary))")
        if let result = run.result {
            let failed = Self.isFailureResult(result)
            state = failed ? .failed : .succeeded
            title = failed ? "\(invocation) failed" : invocation
            detail = "→ \(result)"
            accessibilityLabel = failed ? "\(prettyName) failed. \(result)" : "\(prettyName) returned \(result)"
        } else {
            state = .running
            title = "Using \(prettyName)…"
            detail = nil
            accessibilityLabel = "Using \(prettyName)"
        }
    }

    /// Tools intentionally report recoverable failures as strings so the model can correct its call. Keep
    /// that transport contract, but do not paint those results with a green success seal in chat.
    private static func isFailureResult(_ result: String) -> Bool {
        let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("error:")
            || normalized.hasPrefix("tool error:")
            || (normalized.hasPrefix("mcp tool ") && normalized.contains(" failed:"))
            || normalized.hasPrefix("couldn't ")
            || normalized.hasPrefix("search failed")
            || normalized.hasPrefix("web search failed")
            || normalized.hasPrefix("calendar access is off")
            || normalized.hasPrefix("reminders access is off")
            || normalized.hasPrefix("location access is off")
            || normalized.hasPrefix("location is unavailable")
    }

    private static func argumentSummary(_ arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !obj.isEmpty else { return "" }
        return obj.map { "\($0.value)" }.joined(separator: ", ")
    }
}

/// A single tool the assistant invoked — a running spinner while it works, the seal (✓) + result when
/// it returns. Memory is intentionally quieter: the row confirms the action without exposing or
/// duplicating its canonical internal sentence.
struct ToolActivityRow: View {
    let run: ToolRun

    var body: some View {
        let presentation = ToolActivityPresentation(run: run)
        HStack(spacing: Theme.Space.sm) {
            if presentation.state == .running {
                ProgressView().controlSize(.mini).tint(Theme.accent)
            } else {
                Image(systemName: presentation.state == .failed
                      ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(presentation.state == .failed ? Theme.danger : Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let detail = presentation.detail {
                    Text(detail).font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("assistant.tool.run")
    }
}

/// A committed assistant turn that produced no answer — the user tapped Stop, or generation failed.
/// A compact, honest row with a working Retry, in place of the old "0 tok · stop: cancelled" ghost.
struct EmptyReplyRow: View {
    let outcome: Message.EmptyOutcome
    var onRetry: (() -> Void)?

    private var label: String {
        switch outcome {
        case .stopped: "Stopped"
        case .noReply: "The model didn't reply"
        case .failed: "Couldn't generate a reply"
        }
    }
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
        // Retry is an action, not descriptive text. Keep it independently focusable for VoiceOver.
        .accessibilityElement(children: .contain)
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Assistant answer")
                    .accessibilityValue(answer)
                    .accessibilityIdentifier("assistant.answer")
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    MarkdownMessage(text: answer)
                        // Markdown rendering may consume underscores or split one answer into several
                        // accessibility nodes. Keep the exact raw answer available as one value.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Assistant answer")
                        .accessibilityValue(answer)
                        .accessibilityIdentifier("assistant.answer")
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
            .accessibilityIdentifier("assistant.stats")
    }
}
