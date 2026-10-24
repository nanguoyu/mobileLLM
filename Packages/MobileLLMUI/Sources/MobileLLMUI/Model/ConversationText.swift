// SPDX-License-Identifier: MIT

import Foundation

/// Short, local display text. It never changes the stored message or asks a model to rewrite it.
public enum ConversationText {
    public static func preview(_ source: String) -> String {
        let bounded = String(source.prefix(2_048)).replacingOccurrences(
            of: #"(?m)^[ \t]*(?:#{1,6}[ \t]+|>[ \t]*|[-*+][ \t]+|[0-9]+\.[ \t]+)"#,
            with: "", options: .regularExpression
        )
        let text = (try? AttributedString(markdown: bounded,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? bounded
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func title(_ source: String, limit: Int = 72) -> String {
        var text = preview(source)
        if let stop = text.range(of: #"[.!?。！？](?:\s|$)"#, options: .regularExpression),
           text.distance(from: text.startIndex, to: stop.lowerBound) >= 16 {
            text = String(text[..<stop.lowerBound])
        }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
