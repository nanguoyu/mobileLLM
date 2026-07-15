// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A value-type state machine that splits a streamed token string into `.reasoning` / `.answer`
/// deltas on `<think>…</think>` boundaries (DESIGN §4 — the thinking-disclosure interaction).
///
/// Text outside a `<think>` block is `.answer`; text inside is `.reasoning`. Because a chunk boundary
/// can fall in the middle of a tag ("…</thin" | "k>…"), the splitter withholds up to `tag.count − 1`
/// trailing characters that could be the start of the next tag, and emits them only once it can prove
/// they are (or aren't) a tag.
///
/// CRITICAL (DESIGN critique F1): call `finish()` at stream end. It flushes that withheld tail — a
/// residual buffer that turned out NOT to be a partial tag — as text. Without it, the last up-to-7
/// characters of a response are silently lost.
public struct ThinkSplitter {

    public enum Delta: Equatable, Sendable {
        case reasoning(String)
        case answer(String)
    }

    private static let open = "<think>"
    private static let close = "</think>"

    private var inThink = false
    private var buffer = ""   // unclassified pending characters, including a possible partial-tag tail

    public init() {}

    /// Feed a streamed chunk; returns any deltas it completes (withholding a possible partial tag).
    public mutating func feed(_ chunk: String) -> [Delta] {
        buffer += chunk
        return drain(flush: false)
    }

    /// Flush at stream end: emit everything still buffered (the withheld tail is not a partial tag).
    public mutating func finish() -> [Delta] {
        return drain(flush: true)
    }

    private mutating func drain(flush: Bool) -> [Delta] {
        var out: [Delta] = []
        while true {
            let tag = inThink ? Self.close : Self.open
            if let r = buffer.range(of: tag) {
                // Everything before the tag belongs to the CURRENT region (emit before toggling).
                let before = String(buffer[buffer.startIndex..<r.lowerBound])
                if !before.isEmpty { out.append(emit(before)) }
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)   // drop the tag itself
                inThink.toggle()
                continue
            }
            // No complete tag: emit the safe prefix, withholding a possible partial-tag tail unless
            // we're flushing.
            let keep = flush ? 0 : withheldTail()
            if buffer.count > keep {
                let emitCount = buffer.count - keep
                let idx = buffer.index(buffer.startIndex, offsetBy: emitCount)
                let text = String(buffer[buffer.startIndex..<idx])
                if !text.isEmpty { out.append(emit(text)) }
                buffer.removeSubrange(buffer.startIndex..<idx)
            }
            break
        }
        return out
    }

    /// The number of trailing characters to withhold because they might be the start of the next tag:
    /// the longest suffix of `buffer` that is a prefix of the tag we're currently scanning for.
    private func withheldTail() -> Int {
        let tag = inThink ? Self.close : Self.open
        var k = min(tag.count - 1, buffer.count)
        while k > 0 {
            if tag.hasPrefix(buffer.suffix(k)) { return k }
            k -= 1
        }
        return 0
    }

    private func emit(_ s: String) -> Delta { inThink ? .reasoning(s) : .answer(s) }
}
