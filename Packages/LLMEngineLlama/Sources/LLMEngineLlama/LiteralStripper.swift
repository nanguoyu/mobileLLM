// SPDX-License-Identifier: MIT

import Foundation

/// Removes a fixed set of literal tags from a streamed string, withholding a trailing tail that could be
/// the start of one (so a tag split across chunks — "…<ans" | "wer>…" — is still stripped). Hunyuan wraps
/// its final answer in `<answer>…</answer>`; those markers must not leak into the displayed text.
///
/// Like `ThinkSplitter`, call `flush()` at stream end to release any withheld tail that turned out not to
/// be a partial tag.
struct LiteralStripper {
    private let tags: [String]
    private let maxTagLen: Int
    private var buffer = ""

    init(tags: [String]) {
        self.tags = tags
        self.maxTagLen = tags.map(\.count).max() ?? 0
    }

    /// True when there are no tags to strip (the caller can skip this stage entirely).
    var isNoop: Bool { tags.isEmpty }

    mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        return drain(flush: false)
    }

    mutating func flush() -> String {
        return drain(flush: true)
    }

    private mutating func drain(flush: Bool) -> String {
        // Remove every complete tag occurrence currently in the buffer.
        var changed = true
        while changed {
            changed = false
            for tag in tags {
                if let r = buffer.range(of: tag) {
                    buffer.removeSubrange(r)
                    changed = true
                }
            }
        }
        // Emit the safe prefix, withholding a tail that could still become a tag (unless flushing).
        let keep = flush ? 0 : withheldTail()
        guard buffer.count > keep else { return "" }
        let idx = buffer.index(buffer.startIndex, offsetBy: buffer.count - keep)
        let out = String(buffer[buffer.startIndex..<idx])
        buffer.removeSubrange(buffer.startIndex..<idx)
        return out
    }

    /// The longest suffix of the buffer that is a strict prefix of some tag (so it might complete next).
    private func withheldTail() -> Int {
        var k = min(maxTagLen - 1, buffer.count)
        while k > 0 {
            let suffix = buffer.suffix(k)
            if tags.contains(where: { $0.hasPrefix(suffix) }) { return k }
            k -= 1
        }
        return 0
    }
}
