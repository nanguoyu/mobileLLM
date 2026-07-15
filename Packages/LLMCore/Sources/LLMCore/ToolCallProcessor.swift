// SPDX-License-Identifier: MIT

import Foundation

/// Extracts `<tool_call>{…}</tool_call>` requests from the model's answer stream (the Qwen / ChatML tool
/// convention) — local models emit tool calls as plain text, no server-side tool API needed (FlowDown's
/// `ToolCallProcessor` idea). Normal text passes through as `.text`; a completed block is parsed into a
/// `.call` and its markup suppressed from the visible answer. Like `ThinkSplitter`, it withholds a
/// possible partial tag at a chunk boundary and flushes the tail at stream end.
public struct ToolCallProcessor {

    public enum Event: Equatable, Sendable {
        case text(String)
        case call(ToolCall)
    }

    private static let open = "<tool_call>"
    private static let close = "</tool_call>"

    private var buffer = ""
    private var inCall = false

    public init() {}

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
            let tag = inCall ? Self.close : Self.open
            if let r = buffer.range(of: tag) {
                let before = String(buffer[buffer.startIndex..<r.lowerBound])
                if inCall {
                    // `before` is the tool-call JSON body — parse + emit a call, drop the markup.
                    if let call = Self.parse(before) { out.append(.call(call)) }
                } else if !before.isEmpty {
                    out.append(.text(before))       // plain text preceding the call
                }
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                inCall.toggle()
                continue
            }
            // No complete tag: emit the safe text prefix (only when NOT inside a call), withholding a
            // possible partial-tag tail. Inside a call we buffer everything until the close tag.
            let keep = flush ? 0 : withheldTail()
            if !inCall, buffer.count > keep {
                let idx = buffer.index(buffer.startIndex, offsetBy: buffer.count - keep)
                let text = String(buffer[buffer.startIndex..<idx])
                if !text.isEmpty { out.append(.text(text)) }
                buffer.removeSubrange(buffer.startIndex..<idx)
            } else if flush, inCall, let call = Self.parse(buffer) {
                out.append(.call(call))             // unterminated call at stream end — best-effort parse
                buffer.removeAll()
            }
            break
        }
        return out
    }

    /// Longest suffix of `buffer` that is a prefix of the tag we're scanning for (might complete next).
    private func withheldTail() -> Int {
        let tag = inCall ? Self.close : Self.open
        var k = min(tag.count - 1, buffer.count)
        while k > 0 {
            if tag.hasPrefix(buffer.suffix(k)) { return k }
            k -= 1
        }
        return 0
    }

    /// Parse the JSON body of a tool call: `{"name": "...", "arguments": {…}}`.
    static func parse(_ body: String) -> ToolCall? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else { return nil }
        var argsJSON = "{}"
        if let args = obj["arguments"],
           let d = try? JSONSerialization.data(withJSONObject: args),
           let s = String(data: d, encoding: .utf8) {
            argsJSON = s
        }
        return ToolCall(name: name, argumentsJSON: argsJSON)
    }
}
