// SPDX-License-Identifier: MIT
import AgentContracts
import Foundation

/// A bounded view of the same guest output a successful tool may expose. Raw transport errors and
/// diagnostics from other adapters are never admitted through this path.
enum OpenSandboxDiagnostics {
    static func details(_ output: JSONValue?) -> [String: String] {
        guard case .object(let raw) = output else { return [:] }
        var fields: [String: JSONValue] = [:]
        for (key, limit) in [("error", 384), ("stdout", 768), ("stderr", 1024), ("pageText", 1280),
                             ("url", 192), ("title", 96)] {
            if case .string(let value)? = raw[key] { fields[key] = .string(text(value, limit: limit)) }
        }
        if case .array(let controls)? = raw["controls"] {
            var kept: [JSONValue] = []
            for control in controls.prefix(20) {
                guard case .object(let object) = control else { continue }
                var value: [String: JSONValue] = [:]
                for key in ["tag", "type", "id", "name", "label"] {
                    if case .string(let string)? = object[key] { value[key] = .string(text(string, limit: 96)) }
                }
                for key in ["visible", "disabled"] { if case .bool(let flag)? = object[key] { value[key] = .bool(flag) } }
                let next = kept + [.object(value)]
                guard let bytes = try? CanonicalJSON(.array(next)).data.count, bytes <= 2560 else { break }
                kept = next
            }
            fields["controls"] = .array(kept)
        }
        if case .array(let errors)? = raw["browserErrors"] {
            fields["browserErrors"] = .array(errors.prefix(2).compactMap {
                if case .string(let value) = $0 { return .string(text(value, limit: 256)) }; return nil
            })
        }
        guard !fields.isEmpty else { return [:] }
        fields["bounded"] = .bool(true)
        for _ in 0..<4 {
            if let json = try? CanonicalJSON(.object(fields)), json.data.count <= 8192 {
                var result: [String: String] = [:], chunk = "", bytes = 0, index = 0
                for scalar in json.string.unicodeScalars {
                    let size = String(scalar).utf8.count
                    if bytes + size > 1800 {
                        result["sandbox.diagnostic.\(index)"] = chunk; index += 1; chunk = ""; bytes = 0
                    }
                    chunk.unicodeScalars.append(scalar); bytes += size
                }
                if !chunk.isEmpty { result["sandbox.diagnostic.\(index)"] = chunk }
                return result
            }
            for (key, value) in fields {
                if case .string(let string) = value { fields[key] = .string(text(string, limit: max(32, string.utf8.count / 2))) }
            }
        }
        return [:]
    }

    static func read(_ failure: AgentFailure, prepared: PreparedExternalOperationRequest?) -> JSONValue? {
        guard let prepared, WorkflowSandboxEvidence.read(.failed(failure), prepared: prepared) != nil else { return nil }
        let chunks = (0..<8).compactMap { failure.details["sandbox.diagnostic.\($0)"] }
        let data = Data(chunks.joined().utf8)
        guard !data.isEmpty, data.count <= 8192 else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func text(_ value: String, limit: Int) -> String {
        let safe = String(String.UnicodeScalarView(value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(32)! : $0
        }))
        if safe.utf8.count <= limit { return safe }
        return String(decoding: safe.utf8.prefix(max(0, limit - 16)), as: UTF8.self) + " [truncated]"
    }
}
