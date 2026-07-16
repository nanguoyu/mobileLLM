// SPDX-License-Identifier: MIT

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
///
/// Defense: a model may emit a bare closing `</think>` without an opening `<think>` ever having been
/// seen (implicit-open behavior we didn't flag). Everything before that bare close is reasoning that
/// just ended, so it — and the tag — are routed to `.reasoning`, not leaked into the answer bubble.
public struct ThinkSplitter {

    public enum Delta: Equatable, Sendable {
        case reasoning(String)
        case answer(String)
    }

    private static let open = "<think>"
    private static let close = "</think>"

    private var inThink = false
    private var sawOpen = false   // has an opening <think> been consumed (or did we start in-think)?
    private var buffer = ""   // unclassified pending characters, including a possible partial-tag tail

    /// `startInThink` handles the "implicit-open" reasoning convention (DeepSeek-R1 distills): the chat
    /// template pre-fills the opening `<think>` in the PROMPT, so the generated stream begins inside the
    /// reasoning block and emits only the closing `</think>`. Starting in-think routes everything up to
    /// that `</think>` to `.reasoning`, matching what the model actually streams.
    public init(startInThink: Bool = false) {
        inThink = startInThink
        sawOpen = startInThink   // an implicit-open prompt counts as having seen the opening tag
    }

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
            // Bare-close defense: before any opening <think> has been seen, a stray </think> means the
            // text before it was reasoning that just ended (a model streaming the implicit-open
            // convention without our having pre-filled the open). Route that prefix to .reasoning and
            // drop the tag, instead of leaking both into the answer bubble. Only when a </think>
            // actually precedes any <think> — a genuine open earlier keeps the normal path below.
            if !inThink, !sawOpen, let rClose = buffer.range(of: Self.close) {
                let rOpen = buffer.range(of: Self.open)
                if rOpen == nil || rClose.lowerBound < rOpen!.lowerBound {
                    let before = String(buffer[buffer.startIndex..<rClose.lowerBound])
                    if !before.isEmpty { out.append(.reasoning(before)) }
                    buffer.removeSubrange(buffer.startIndex..<rClose.upperBound)
                    sawOpen = true   // boundary resolved; a later </think> is now literal answer text
                    continue
                }
            }
            let tag = inThink ? Self.close : Self.open
            if let r = buffer.range(of: tag) {
                // Everything before the tag belongs to the CURRENT region (emit before toggling).
                let before = String(buffer[buffer.startIndex..<r.lowerBound])
                if !before.isEmpty { out.append(emit(before)) }
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)   // drop the tag itself
                if !inThink { sawOpen = true }   // we just consumed an opening <think>
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
    /// the longest suffix of `buffer` that is a prefix of any tag we're currently scanning for. Outside a
    /// think block and before any open has been seen we scan for BOTH the open and a bare close, so a
    /// `</think>` split across chunks isn't emitted as answer before the bare-close defense can fire.
    private func withheldTail() -> Int {
        var tags = [inThink ? Self.close : Self.open]
        if !inThink, !sawOpen { tags.append(Self.close) }
        var best = 0
        for tag in tags {
            var k = min(tag.count - 1, buffer.count)
            while k > best {
                if tag.hasPrefix(buffer.suffix(k)) { best = k; break }
                k -= 1
            }
        }
        return best
    }

    private func emit(_ s: String) -> Delta { inThink ? .reasoning(s) : .answer(s) }
}
