// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Versioned, deterministic checks for explicit human formatting directives. These are extracted
/// before planning, never from a model's working notes or a worker's claimed word count.
public struct WorkflowOutputLimits: Codable, Sendable, Equatable {
    public let version: UInt16
    public var finalWords: Int?
    public var workerWords: Int?
    public var finalCharacters: Int?
    public var workerCharacters: Int?
    public var requiresJSON: Bool

    public init(finalWords: Int? = nil, workerWords: Int? = nil, finalCharacters: Int? = nil,
                workerCharacters: Int? = nil, requiresJSON: Bool = false) {
        version = 1; self.finalWords = finalWords; self.workerWords = workerWords
        self.finalCharacters = finalCharacters; self.workerCharacters = workerCharacters; self.requiresJSON = requiresJSON
    }

    public static func detecting(in goal: String) -> Self { Self().applying(goal) }
    public func applying(_ humanText: String) -> Self {
        var next = self
        // Quoted examples, code and blockquotes are data, not formatting instructions.
        var text = humanText.replacingOccurrences(of: #"(?s)```.*?```|`[^`]*`|\"[^\"]*\"|“[^”]*”|‘[^’]*’|(?<!\w)'[^'\n]*'(?!\w)"#, with: " ", options: .regularExpression)
        text = text.split(separator: "\n", omittingEmptySubsequences: false).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">")
        }.joined(separator: "\n")
        let bound = #"\s+(under|fewer than|less than|at most|no more than|up to|maximum of)\s+([0-9]{1,6})\s+words\b"#
        func limit(_ scope: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: "(?i)" + scope + bound),
                  let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  let operatorRange = Range(match.range(at: 1), in: text), let countRange = Range(match.range(at: 2), in: text),
                  let count = Int(text[countRange]), count > 0, count <= 100_000 else { return nil }
            let exclusive = ["under", "fewer than", "less than"].contains(text[operatorRange].lowercased())
            return exclusive ? count - 1 : count
        }
        if text.range(of: #"(?i)\b(?:remove|drop) (?:the )?(?:final )?word limit\b"#, options: .regularExpression) != nil { next.finalWords = nil }
        if let count = limit(#"\bfinal\s+(?:answer|plan|report|response|output|deliverable)"#) { next.finalWords = count }
        if let count = limit(#"\b(?:each|every)\s+(?:worker|agent)(?:'s\s+(?:output|answer|response))?"#) { next.workerWords = count }
        func characters(_ scope: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: scope + #"\s*(不超过|最多|少于|小于)\s*([0-9]{1,6})\s*(?:个)?字"#),
                  let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  let op = Range(match.range(at: 1), in: text), let digits = Range(match.range(at: 2), in: text),
                  let value = Int(text[digits]), value > 0, value <= 100_000 else { return nil }
            return ["少于", "小于"].contains(String(text[op])) ? value - 1 : value
        }
        if let count = characters(#"最终(?:回答|回复|报告|方案|计划|结果|输出)"#) { next.finalCharacters = count }
        if let count = characters(#"每个(?:代理|子代理|agent|worker)(?:的)?(?:回答|回复|输出)?"#) { next.workerCharacters = count }
        if text.contains("取消最终字数限制") { next.finalCharacters = nil; next.finalWords = nil }
        if text.range(of: #"(?i)(?:^|[.!?]\s+|\n)\s*(?:please\s+)?(?:return|output|respond with)\s+only\s+JSON\b"#, options: .regularExpression) != nil { next.requiresJSON = true }
        if text.range(of: #"(?i)\b(?:return|use)\s+plain text\s+instead of\s+JSON\b"#, options: .regularExpression) != nil { next.requiresJSON = false }
        if text.range(of: #"(?:^|[。！？]\s*|\n)\s*(?:最终)?(?:仅|只)(?:返回|输出)\s*JSON"#, options: .regularExpression) != nil { next.requiresJSON = true }
        return next
    }

    public var json: JSONValue {
        .object(["version": .integer(Int64(version)), "finalWords": finalWords.map { .integer(Int64($0)) } ?? .null,
            "workerWords": workerWords.map { .integer(Int64($0)) } ?? .null,
            "finalCharacters": finalCharacters.map { .integer(Int64($0)) } ?? .null,
            "workerCharacters": workerCharacters.map { .integer(Int64($0)) } ?? .null, "requiresJSON": .bool(requiresJSON)])
    }

    /// Whitespace-separated words containing a Unicode letter/digit. Markdown separator-only tokens
    /// are excluded; headings, table cells, code identifiers and appendices are counted.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { word in word.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }.count
    }

    public func workerRejection(_ text: String) -> String? {
        if let maximum = workerCharacters, text.filter({ !$0.isWhitespace }).count > maximum {
            return "Worker output exceeds the human's limit of \(maximum) non-whitespace characters, including all sections. Condense the entire result."
        }
        guard let maximum = workerWords, Self.wordCount(text) > maximum else { return nil }
        return "Worker output contains \(Self.wordCount(text)) words; the human's limit is \(maximum). Condense the entire result, including headings, tables and appendices. Preserve the required facts."
    }

    public func finalRejection(_ text: String) -> String? {
        if let maximum = finalCharacters, text.filter({ !$0.isWhitespace }).count > maximum {
            return "Final output exceeds the human's limit of \(maximum) non-whitespace characters, including all sections. Condense the entire answer."
        }
        if let maximum = finalWords, Self.wordCount(text) > maximum {
            return "Final output contains \(Self.wordCount(text)) words; the human's limit is \(maximum). Condense the entire answer, including headings, tables and appendices. Do not invent exclusions or claim an unchecked count."
        }
        if requiresJSON, (try? AgentWireDecoder.decode(JSONValue.self, from: Data(text.utf8), limits: .inlineValue)) == nil {
            return "The human requested JSON only. Return one valid JSON value without fences, introductions or appendices."
        }
        return nil
    }
}
