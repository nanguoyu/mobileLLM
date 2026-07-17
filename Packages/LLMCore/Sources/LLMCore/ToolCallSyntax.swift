// SPDX-License-Identifier: MIT

import Foundation

/// Recognising a tool call in a model's answer stream, in ANY family's dialect.
///
/// Deliberately not gated on the active model's `ToolDialect`. Models improvise across conventions — real
/// Gemma 4 E2B, handed our Qwen-style prose block, emitted `<tool_call>remember{"text": "用户叫Tom"}
/// </tool_call>`: Qwen's tags around a body in (as it happens) Hunyuan's shape. Gating the parser on
/// "the loaded model is Gemma" would have rejected that call while a Gemma model made it. So: declare in
/// the model's own dialect (that earns a clean call), but read whatever comes back.
///
/// Every marker pair and body shape below is copied from a family's canonical chat template, not inferred.
enum ToolCallSyntax {

    /// The open/close markers each family wraps a call in. `<|tool_call>` does NOT contain the substring
    /// `<tool_call>` (the character after `<` is `|`), so these never shadow one another — the scanner
    /// takes whichever opens earliest.
    static let markers: [(open: String, close: String)] = [
        ("<|tool_call>", "<tool_call|>"),                       // gemma
        ("<｜tool▁call▁begin｜>", "<｜tool▁call▁end｜>"),          // deepSeek (full-width ｜ U+FF5C, ▁ U+2581)
        ("<tool_call>", "</tool_call>"),                        // qwen + hunyuan (shared tags, different bodies)
    ]

    /// Wrapper tags a family prints AROUND its call block, carrying no information of their own. Hunyuan's
    /// template instructs it to "first print <tool_calls>" and to print "</tool_calls>" at the end — note
    /// the PLURAL, which is not an open marker and so used to stream straight into the visible answer.
    /// Caught by `llama-smoke --tools` against real Hunyuan weights, not by any unit test.
    static let noise = ["<tool_calls>", "</tool_calls>"]

    /// Longest marker, for the streaming processor's partial-tag withholding — includes the noise tags,
    /// since a half-arrived `</tool_c` must be withheld too rather than shown and then completed.
    static let longestOpen = (markers.map(\.open.count) + noise.map(\.count)).max() ?? 0

    /// Strip the wrapper tags from a run of visible text.
    static func stripNoise(_ text: String) -> String {
        var out = text
        for n in noise { out = out.replacingOccurrences(of: n, with: "") }
        return out
    }

    /// The earliest open marker in `text`, if any.
    static func firstOpen(in text: String) -> (range: Range<String.Index>, close: String)? {
        var best: (range: Range<String.Index>, close: String)?
        for m in markers {
            guard let r = text.range(of: m.open) else { continue }
            if best == nil || r.lowerBound < best!.range.lowerBound { best = (r, m.close) }
        }
        return best
    }

    /// Is `suffix` a prefix of any open or wrapper marker (so it might complete on the next chunk)?
    static func isPartialOpen(_ suffix: some StringProtocol) -> Bool {
        markers.contains { $0.open.hasPrefix(suffix) } || noise.contains { $0.hasPrefix(suffix) }
    }

    // MARK: - Bodies

    /// Parse a call body in any known shape. Ordered most- to least-specific; each returns nil rather than
    /// guessing, so an unrecognised body still becomes `.malformed` and earns a corrective retry.
    static func parse(_ body: String) -> ToolCall? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return qwenJSON(t) ?? gemmaCall(t) ?? deepSeekCall(t) ?? nameThenArgs(t)
    }

    /// Qwen: `{"name": "x", "arguments": {…}}` — the whole body is one JSON object naming the tool.
    private static func qwenJSON(_ body: String) -> ToolCall? {
        guard body.hasPrefix("{"), let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else { return nil }
        var argsJSON = "{}"
        if let args = obj["arguments"],
           let d = try? JSONSerialization.data(withJSONObject: args),
           let s = String(data: d, encoding: .utf8) { argsJSON = s }
        return ToolCall(name: name, argumentsJSON: argsJSON)
    }

    /// Gemma 4: `call:NAME{key:<|"|>value<|"|>,key2:123}` — its own `format_argument` quoting.
    private static func gemmaCall(_ body: String) -> ToolCall? {
        guard body.hasPrefix("call:") else { return nil }
        let rest = String(body.dropFirst("call:".count))
        guard let brace = rest.firstIndex(of: "{"), rest.hasSuffix("}") else { return nil }
        let name = String(rest[rest.startIndex..<brace]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let inner = String(rest[rest.index(after: brace)..<rest.index(before: rest.endIndex)])
        return ToolCall(name: name, argumentsJSON: gemmaArgsToJSON(inner))
    }

    /// `k:<|"|>v<|"|>,k2:12` → `{"k":"v","k2":12}`. Splits on top-level commas only: a comma inside a
    /// quoted value is part of the value ("用户住在南京, 江苏" must not become two arguments).
    static func gemmaArgsToJSON(_ inner: String) -> String {
        var out: [String: Any] = [:]
        for field in splitTopLevel(inner) {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = String(field[field.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(field[field.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.hasPrefix("<|\"|>"), value.hasSuffix("<|\"|>"), value.count >= 10 {
                value = String(value.dropFirst(5).dropLast(5))
                out[key] = value
            } else if let n = Double(value) {
                out[key] = n
            } else if value == "true" || value == "false" {
                out[key] = value == "true"
            } else {
                out[key] = value
            }
        }
        guard !out.isEmpty, let d = try? JSONSerialization.data(withJSONObject: out),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Split on commas that are outside `<|"|>` quotes and outside nested braces/brackets.
    private static func splitTopLevel(_ s: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("<|\"|>") {
                inQuote.toggle()
                current += "<|\"|>"
                i = s.index(i, offsetBy: 5)
                continue
            }
            let c = s[i]
            if !inQuote {
                if c == "{" || c == "[" { depth += 1 }
                if c == "}" || c == "]" { depth -= 1 }
                if c == ",", depth == 0 {
                    fields.append(current); current = ""; i = s.index(after: i); continue
                }
            }
            current.append(c)
            i = s.index(after: i)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { fields.append(current) }
        return fields
    }

    /// DeepSeek: `function<｜tool▁sep｜>NAME\n```json\n{…}\n``` ` (the type precedes the separator).
    private static func deepSeekCall(_ body: String) -> ToolCall? {
        let sep = "<｜tool▁sep｜>"
        guard let r = body.range(of: sep) else { return nil }
        return nameThenArgs(String(body[r.upperBound...]))
    }

    /// The "name outside the JSON" family: `NAME{…json…}` (what Gemma emits when handed a prose block) and
    /// Hunyuan's native ``NAME\n```\n{…}\n``` ``. One shape: a bare name, then its arguments.
    private static func nameThenArgs(_ body: String) -> ToolCall? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Everything up to the first `{` or fence is the name.
        let stop = t.firstIndex { $0 == "{" || $0 == "`" || $0 == "\n" }
        guard let stop else { return nil }
        let name = String(t[t.startIndex..<stop])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"'"))
        guard !name.isEmpty, name.count < 64,
              !name.contains(" "), !name.contains("{") else { return nil }
        var rest = String(t[stop...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a ``` / ```json fence if present (Hunyuan, DeepSeek).
        if rest.hasPrefix("```") {
            rest = String(rest.dropFirst(3))
            if rest.hasPrefix("json") { rest = String(rest.dropFirst(4)) }
            if let end = rest.range(of: "```", options: .backwards) { rest = String(rest[rest.startIndex..<end.lowerBound]) }
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard rest.hasPrefix("{") else { return nil }
        // Validate the arguments really are JSON — otherwise this is a malformed call, not a call.
        guard let d = rest.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] != nil else { return nil }
        return ToolCall(name: name, argumentsJSON: rest)
    }
}
