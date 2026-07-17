// SPDX-License-Identifier: MIT

import Foundation

/// Extracts tool-call requests from the model's answer stream — local models emit tool calls as plain text,
/// no server-side tool API needed (FlowDown's `ToolCallProcessor` idea). Normal text passes through as
/// `.text`; a completed block is parsed into a `.call` and its markup suppressed from the visible answer.
/// Like `ThinkSplitter`, it withholds a possible partial tag at a chunk boundary and flushes the tail at
/// stream end.
///
/// Reads EVERY family's dialect, not just the loaded model's — see `ToolCallSyntax`. This used to know only
/// Qwen's `<tool_call>{"name":…}</tool_call>`, which meant a Gemma/Hunyuan/DeepSeek model's call was
/// unreadable and no tool ever ran on 5 of the 9 catalog models.
public struct ToolCallProcessor {

    public enum Event: Equatable, Sendable {
        case text(String)
        case call(ToolCall)
        /// A tool-call block whose body isn't a usable call (bad JSON, no name). Carries the raw body so the
        /// loop can tell the model what was wrong and let it retry. Dropping these silently is what made a
        /// small model's near-miss vanish into an empty, unexplained reply.
        case malformed(String)
    }

    private var buffer = ""
    /// The close marker we're scanning for while inside a call — set when its open marker matched, so a
    /// dialect's call is always closed by ITS OWN terminator.
    private var closingWith: String?

    /// Accept an UNTAGGED `{"name":…,"arguments":…}` as a call, but only as the opening of the answer.
    ///
    /// A concession to DeepSeek-R1 and nothing else. Its chat template has no tool-declaration block at
    /// all (`tools` never appears in it), so there is no native way to tell it about tools — and asked for
    /// Qwen's tags it reproducibly emits perfect JSON with no tags whatsoever, while asked for its own
    /// `<｜tool▁call▁begin｜>` markers it types the words "<tool calls begin>" in prose. The JSON is the
    /// only thing it gets right, so that's what we read.
    ///
    /// Deliberately NOT on for other dialects, and deliberately only at the START of the answer: a model
    /// that merely SHOWS a tool-call JSON ("here's what a call looks like: {…}") must never have it
    /// executed. Narrow concession, narrow blast radius.
    private let acceptsBareJSON: Bool
    private var emittedAnything = false

    public init(acceptsBareJSON: Bool = false) {
        self.acceptsBareJSON = acceptsBareJSON
    }

    public mutating func feed(_ chunk: String) -> [Event] {
        buffer += chunk
        return drain(flush: false)
    }

    public mutating func finish() -> [Event] {
        drain(flush: true)
    }

    private mutating func drain(flush: Bool) -> [Event] {
        var out: [Event] = []
        while true {
            if let close = closingWith {
                guard let r = buffer.range(of: close) else { break }
                let body = String(buffer[buffer.startIndex..<r.lowerBound])
                out.append(event(forBody: body))
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                closingWith = nil
                continue
            }
            if let hit = ToolCallSyntax.firstOpen(in: buffer) {
                let before = String(buffer[buffer.startIndex..<hit.range.lowerBound])
                emitText(before, into: &out)
                buffer.removeSubrange(buffer.startIndex..<hit.range.upperBound)
                closingWith = hit.close
                continue
            }
            break
        }
        // An untagged call at the head of the answer (DeepSeek only — see `acceptsBareJSON`).
        if closingWith == nil, acceptsBareJSON, !emittedAnything, out.isEmpty {
            switch bareJSONHead(flush: flush) {
            case .call(let c):
                buffer.removeAll()
                return [.call(c)]
            case .keepWaiting:
                return out                       // withhold — it may still complete
            case .notACall:
                break                            // fall through and stream it as ordinary text
            }
        }
        // No complete marker: emit the safe text prefix (only when NOT inside a call), withholding a
        // possible partial-tag tail. Inside a call we buffer everything until the close marker.
        if closingWith == nil {
            let keep = flush ? 0 : withheldTail()
            if buffer.count > keep {
                let idx = buffer.index(buffer.startIndex, offsetBy: buffer.count - keep)
                emitText(String(buffer[buffer.startIndex..<idx]), into: &out)
                buffer.removeSubrange(buffer.startIndex..<idx)
            }
        } else if flush, !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Unterminated call at stream end — best-effort parse, else report rather than drop it.
            out.append(event(forBody: buffer))
            buffer.removeAll()
        }
        return out
    }

    private enum BareHead { case call(ToolCall), keepWaiting, notACall }

    /// Longest an untagged JSON candidate may grow before we give up and stream it as text — a bound so a
    /// stray `{` can never swallow a whole answer.
    private static let bareJSONCap = 4096

    /// Is the answer opening with an untagged tool-call JSON? Withholds while the object is still
    /// arriving; gives up (as text) once it can't be one.
    private func bareJSONHead(flush: Bool) -> BareHead {
        let lead = buffer.drop(while: { $0.isWhitespace })
        guard let first = lead.first else { return flush ? .notACall : .keepWaiting }
        guard first == "{" else { return .notACall }
        guard let end = Self.balancedEnd(of: lead) else {
            // Still open. Keep waiting unless the stream ended or it has run away.
            return (flush || buffer.count > Self.bareJSONCap) ? .notACall : .keepWaiting
        }
        guard let call = ToolCallSyntax.parse(String(lead[lead.startIndex..<end])) else { return .notACall }
        return .call(call)
    }

    /// Index just past the `}` that closes the object `s` starts with, honouring strings and escapes —
    /// a brace inside `"…{…"` doesn't nest.
    private static func balancedEnd(of s: some StringProtocol) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return s.index(after: i) }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Emit visible text with the families' wrapper tags removed — Hunyuan is told by its own template to
    /// print `<tool_calls>` … `</tool_calls>` around its calls, and those are not an open marker, so they
    /// used to land in the answer bubble. Nothing is emitted if only the wrapper was there.
    private mutating func emitText(_ raw: String, into out: inout [Event]) {
        let text = ToolCallSyntax.stripNoise(raw)
        if !text.isEmpty { out.append(.text(text)); emittedAnything = true }
    }

    private func event(forBody body: String) -> Event {
        if let call = ToolCallSyntax.parse(body) { return .call(call) }
        return .malformed(body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Longest suffix of `buffer` that is a prefix of SOME open marker (it might complete next chunk).
    private func withheldTail() -> Int {
        var k = min(ToolCallSyntax.longestOpen - 1, buffer.count)
        while k > 0 {
            if ToolCallSyntax.isPartialOpen(buffer.suffix(k)) { return k }
            k -= 1
        }
        return 0
    }

    /// Parse the JSON body of a tool call. Retained for the tests that pin the Qwen shape directly;
    /// `ToolCallSyntax.parse` is the real entry point and reads every dialect.
    static func parse(_ body: String) -> ToolCall? { ToolCallSyntax.parse(body) }
}
