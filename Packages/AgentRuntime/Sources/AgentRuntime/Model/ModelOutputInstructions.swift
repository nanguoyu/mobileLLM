// SPDX-License-Identifier: MIT

import AgentContracts

/// The complete frozen output contract must reach every model, including JSON-mode providers that
/// validate syntax only. The runtime remains responsible for validating the returned value.
enum ModelOutputInstructions {
    static func structured(_ schema: JSONSchemaDocument) throws -> String {
        let json = try CanonicalJSON(schema.root).string
        return """
        Return one JSON value and no surrounding Markdown or commentary. It must validate against this
        complete JSON Schema Draft 2020-12 document:
        \(json)
        """
    }
}
