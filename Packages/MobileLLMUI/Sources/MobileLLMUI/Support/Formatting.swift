// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import LLMCore

/// Small display formatters shared across the chat + models surfaces.
enum Format {

    /// Recency bucket for the conversation list (DESIGN §4 — Pinned / Today / Yesterday / …).
    enum RecencyGroup: String, CaseIterable {
        case pinned = "Pinned"
        case today = "Today"
        case yesterday = "Yesterday"
        case thisWeek = "Previous 7 Days"
        case thisMonth = "Previous 30 Days"
        case older = "Older"
    }

    static func group(for entry: ConversationIndexEntry, now: Date = Date(),
                      calendar: Calendar = .current) -> RecencyGroup {
        if entry.pinned { return .pinned }
        return group(for: entry.updatedAt, now: now, calendar: calendar)
    }

    static func group(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> RecencyGroup {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        guard let days = calendar.dateComponents([.day], from: date, to: now).day else { return .older }
        if days < 7 { return .thisWeek }
        if days < 30 { return .thisMonth }
        return .older
    }

    /// A relative timestamp for a list row ("2h", "Mon", "3 Jul").
    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        let f = DateFormatter()
        f.dateFormat = days < 7 ? "EEE" : "d MMM"
        return f.string(from: date)
    }

    /// The quiet per-message stats footer (DESIGN §4): "Bonsai 8B · 41 tok · 23 tok/s · stop: eos".
    static func statsFooter(_ stats: Stats, modelName: String) -> String {
        var parts = [modelName, "\(stats.genTokens) tok"]
        if stats.tokensPerSecond > 0 {
            parts.append(String(format: "%.0f tok/s", stats.tokensPerSecond))
        }
        parts.append("stop: \(stats.stopReason.rawValue)")
        return parts.joined(separator: " · ")
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Compact context count ("1,240 / 8K").
    static func context(_ used: Int, _ cap: Int) -> String {
        "\(used.formatted()) / \(shortCount(cap))"
    }

    static func shortCount(_ n: Int) -> String {
        if n >= 1000 { return "\(n / 1000)K" }
        return "\(n)"
    }
}
