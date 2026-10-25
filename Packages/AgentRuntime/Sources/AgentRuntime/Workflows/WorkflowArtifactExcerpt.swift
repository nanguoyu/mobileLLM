// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// One original-text reader shared by coordinator operations and model-facing artifact tools.
enum WorkflowArtifactExcerpt {
    static func read(_ raw: CanonicalJSON, id: String, offset: Int, length: Int) throws -> [String: JSONValue] {
        guard offset >= 0, (1...12_000).contains(length) else { throw WorkflowTaskGraphError.unavailableInput }
        let value = try JSONDecoder().decode(JSONValue.self, from: raw.data)
        let text: String
        if case .string(let content) = value { text = content } else { text = raw.string }
        let units = Array(text.utf16)
        guard offset < units.count else { throw WorkflowTaskGraphError.unavailableInput }
        var end = min(units.count, offset + length)
        func splitsScalar(_ index: Int) -> Bool {
            index > 0 && index < units.count && (0xD800...0xDBFF).contains(units[index - 1])
                && (0xDC00...0xDFFF).contains(units[index])
        }
        guard !splitsScalar(offset) else { throw WorkflowTaskGraphError.unavailableInput }
        if splitsScalar(end) { end -= 1 }
        guard end > offset, let range = Range(NSRange(location: offset, length: end - offset), in: text) else {
            throw WorkflowTaskGraphError.unavailableInput
        }
        return ["id": .string(id), "sourceDigest": .string(raw.fingerprint.rawValue),
            "offset": .integer(Int64(offset)), "nextOffset": .integer(Int64(end)), "totalCharacters": .integer(Int64(units.count)),
            "content": .string(String(text[range])), "truncated": .bool(end < units.count)]
    }
}
