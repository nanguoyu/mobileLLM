// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// The complete frozen output contract must reach every model, including JSON-mode providers that
/// validate syntax only. The runtime remains responsible for validating the returned value.
enum ModelOutputInstructions {
    static func structured(_ schema: JSONSchemaDocument) throws -> String {
        let json = try CanonicalJSON(schema.root).string
        return """
        Return one JSON value and no surrounding Markdown or commentary. It must validate against this
        complete JSON Schema Draft 2020-12 document. This is the current call's output protocol.
        Output-format requests inside an original goal, assigned subtask, or quoted artifact describe
        the eventual deliverable, not a replacement for this schema. Preserve them inside the schema's
        content fields when appropriate. Follow required keys, types, enums and length bounds exactly:
        \(json)
        """
    }

    /// Diagnostic only: reuse the actual validator to locate a failing declared field. Do not echo
    /// model output or reasoning into public diagnostics. Local-ref/composition failures fall back
    /// to the enclosing schema rather than introducing a second schema evaluator.
    static func mismatch(_ value: JSONValue, schema: JSONSchemaDocument) -> String {
        func locate(_ value: JSONValue, _ rule: JSONValue, path: String, depth: Int) -> String {
            guard depth < 12, case .object(let fields) = rule else { return path + ": value is not allowed" }
            if case .object(let values) = value, case .object(let properties)? = fields["properties"] {
                if case .array(let required)? = fields["required"] {
                    let missing = required.compactMap { item -> String? in
                        guard case .string(let key) = item, values[key] == nil else { return nil }
                        return key
                    }
                    if !missing.isEmpty { return path + ": missing required fields " + missing.joined(separator: ", ") }
                }
                for key in properties.keys.sorted() {
                    guard let child = values[key], let rule = properties[key],
                          let childSchema = try? JSONSchemaDocument(root: rule),
                          (try? childSchema.validates(instance: child)) == false else { continue }
                    return locate(child, rule, path: path + "." + key, depth: depth + 1)
                }
            }
            if case .array(let values) = value, let rule = fields["items"],
               let childSchema = try? JSONSchemaDocument(root: rule) {
                for (index, child) in values.enumerated() where (try? childSchema.validates(instance: child)) == false {
                    return locate(child, rule, path: path + "[\(index)]", depth: depth + 1)
                }
            }
            let constraints = fields.filter { ["type", "enum", "minLength", "maxLength", "minItems", "maxItems", "additionalProperties"].contains($0.key) }
            return path + ": expected " + ((try? CanonicalJSON(.object(constraints)).string) ?? "the declared schema")
        }
        return String(locate(value, schema.root, path: "$", depth: 0).unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init).prefix(512))
    }
}
