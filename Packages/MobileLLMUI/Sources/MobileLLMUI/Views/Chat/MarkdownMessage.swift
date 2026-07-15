// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// A parsed block of assistant text: either prose (rendered as markdown) or a fenced code block.
struct MarkdownBlock: Identifiable {
    enum Kind: Equatable { case prose(String); case code(language: String?, code: String) }
    /// Stable position-based id so SwiftUI reuses the block views across streaming re-parses — a random
    /// UUID per parse forced a full rebuild every token (FlowDown's "reuse by stable id" fix).
    let id: Int
    let kind: Kind

    /// Split text on ```-fenced code blocks (DESIGN §4 — code cards, prose as markdown). A trailing
    /// unterminated fence (mid-stream) still renders as a code block so it reads correctly while typing.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var language: String?

        func flushProse() {
            let joined = proseLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(MarkdownBlock(id: blocks.count, kind: .prose(joined))) }
            proseLines.removeAll()
        }
        func flushCode() {
            blocks.append(MarkdownBlock(id: blocks.count, kind: .code(language: language,
                                                                      code: codeLines.joined(separator: "\n"))))
            codeLines.removeAll()
            language = nil
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode { flushCode(); inCode = false }
                else {
                    flushProse()
                    let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = lang.isEmpty ? nil : lang
                    inCode = true
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return blocks
    }
}

/// Renders assistant text as markdown prose interleaved with fenced code cards (DESIGN §4).
struct MarkdownMessage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .prose(let s): ProseText(s)
                case let .code(language, code): CodeCard(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Streaming wrapper: coalesces token-by-token growth to ~20 fps so the markdown re-parse can't thrash
/// on a phone (FlowDown's throttle idea). The inline block caret rides at the tail; the final text is
/// always shown when the caller switches to the non-streaming `MarkdownMessage` on completion.
struct StreamingMarkdown: View {
    let text: String
    @State private var shown = ""
    @State private var lastRenderedAt = Date.distantPast

    var body: some View {
        MarkdownMessage(text: shown + "\u{258C}")
            .onChange(of: text) { _, new in
                let now = Date()
                // Render on a ~50 ms gate, or immediately when a big chunk arrives so we never fall far behind.
                if now.timeIntervalSince(lastRenderedAt) >= 0.05 || new.count - shown.count > 24 {
                    shown = new
                    lastRenderedAt = now
                }
            }
            .onAppear { shown = text }
    }
}

/// Inline markdown (bold / italic / inline-code / links), preserving hard line breaks. Full GFM
/// tables + syntax highlighting are TODO(v1.0).
struct ProseText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    var body: some View {
        Text(attributed)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(raw)
    }
}

/// A fenced code block: mono card, language label + Copy, horizontal scroll (never wrap — DESIGN §4).
struct CodeCard: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    withAnimation(Motion.spring) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(copied ? Theme.fitGreen : Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied code" : "Copy code")
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.surface2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(Theme.Space.md)
                    .frame(minWidth: 0, alignment: .leading)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            .strokeBorder(Theme.hairline))
    }
}

#if DEBUG
#Preview("Markdown message") {
    ScrollView {
        MarkdownMessage(text: """
        Here's how to reverse a string in **Swift**:

        ```swift
        let reversed = String("hello".reversed())
        print(reversed) // "olleh"
        ```

        You can also use `.reversed()` directly on a collection.
        """)
        .padding()
    }
    .background(Theme.bg)
}
#endif
