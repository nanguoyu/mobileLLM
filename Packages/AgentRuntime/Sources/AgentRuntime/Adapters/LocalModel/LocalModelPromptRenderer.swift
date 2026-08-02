// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import LLMCore

struct LocalModelToolBinding: Sendable {
    let wireName: String
    let descriptor: AgentToolDescriptor
}

enum LocalModelPromptRenderer {
    static func bindings(
        for descriptors: [AgentToolDescriptor]
    ) -> [LocalModelToolBinding] {
        let nameCounts = Dictionary(grouping: descriptors, by: { $0.id.logicalID.name })
            .mapValues(\.count)
        return descriptors.enumerated().map { index, descriptor in
            let name = descriptor.id.logicalID.name
            if nameCounts[name] == 1, isSafeWireName(name) {
                return LocalModelToolBinding(wireName: name, descriptor: descriptor)
            }
            let digest = StableDigest.fingerprint(
                domain: "local-model-tool-alias.v1",
                components: [Data(descriptor.id.logicalID.description.utf8)]
            ).rawValue.prefix(10)
            let stem = sanitizedStem(name)
            return LocalModelToolBinding(
                wireName: "tool_\(index + 1)_\(stem)_\(digest)",
                descriptor: descriptor
            )
        }
    }

    static func toolBlock(
        bindings: [LocalModelToolBinding],
        dialect: ToolDialect
    ) throws -> String {
        guard !bindings.isEmpty else { return "" }
        switch dialect {
        case .qwen:
            return try jsonDeclarations(
                bindings,
                preamble: "You may call one or more tools. Available function schemas:",
                callShape: #"<tool_call>{"name":"<tool>","arguments":{<args>}}</tool_call>"#
            )
        case .deepSeek:
            return try jsonDeclarations(
                bindings,
                preamble: "You may call one or more tools. Available function schemas:",
                callShape: """
                <｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜><tool>
                ```json
                {<args>}
                ```<｜tool▁call▁end｜><｜tool▁calls▁end｜>
                """
            )
        case .hunyuan:
            let declarations = try bindings.map(functionDeclarationJSON).joined(separator: "\n")
            return """
            # Tools

            You may call one or more functions to assist with the user query.
            The complete Draft 2020-12 function schemas are inside <tools></tools>:
            <tools>
            \(declarations)
            </tools>

            For calls, first print <tool_calls>. For each call print:
            <tool_call>function_name
            ```json
            {<args>}
            ```</tool_call>
            Then print </tool_calls> and stop. If no tool is needed, answer normally.
            """
        case .gemma:
            return try bindings.map { binding in
                "<|tool>\(binding.wireName){description:\(try gemmaValue(.string(binding.descriptor.summary))),parameters:\(try gemmaValue(binding.descriptor.inputSchema.root))}<tool|>"
            }.joined()
        }
    }

    static func structuredOutputBlock(_ schema: JSONSchemaDocument) throws -> String {
        let json = try CanonicalJSON(schema.root).string
        return """
        Return one JSON value and no surrounding Markdown or commentary. It must validate against this
        complete JSON Schema Draft 2020-12 document:
        \(json)
        """
    }

    static func frameUntrusted(_ content: String, dialect: ToolDialect) -> String {
        dialect.frameResult(content, name: "external_data")
    }

    private static func jsonDeclarations(
        _ bindings: [LocalModelToolBinding],
        preamble: String,
        callShape: String
    ) throws -> String {
        let declarations = try bindings.map(functionDeclarationJSON).joined(separator: "\n")
        return """
        \(preamble)
        <tools>
        \(declarations)
        </tools>

        To call tools, emit one call block per function in execution order, then stop. Emit no
        acknowledgement or result yourself. Use this exact family-specific shape:
        \(callShape)
        If no tool fits, answer the user normally.
        """
    }

    private static func functionDeclarationJSON(
        _ binding: LocalModelToolBinding
    ) throws -> String {
        try CanonicalJSON(.object([
            "function": .object([
                "description": .string(binding.descriptor.summary),
                "name": .string(binding.wireName),
                "parameters": binding.descriptor.inputSchema.root,
            ]),
            "type": .string("function"),
        ])).string
    }

    /// Gemma's template uses `<|"|>` strings and recursively formats schema dictionaries. This keeps
    /// every nested Draft-2020-12 keyword/value rather than flattening parameters to three primitive kinds.
    private static func gemmaValue(_ value: JSONValue) throws -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .integer(let value):
            return String(value)
        case .unsignedInteger(let value):
            return String(value)
        case .number:
            return try CanonicalJSON(value).string
        case .string(let value):
            let quoted = try CanonicalJSON(.string(value)).string
            let escaped = String(quoted.dropFirst().dropLast())
                .replacingOccurrences(of: "<|\"|>", with: "\\u003c|\\\"|\\u003e")
            return "<|\"|>\(escaped)<|\"|>"
        case .array(let values):
            return "[" + (try values.map(gemmaValue).joined(separator: ",")) + "]"
        case .object(let object):
            let keys = object.keys.sorted { lhs, rhs in
                lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
            }
            let members = try keys.map { key in
                let renderedKey = isSafeGemmaKey(key)
                    ? key
                    : try gemmaValue(.string(key))
                return "\(renderedKey):\(try gemmaValue(object[key]!))"
            }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    private static func isSafeWireName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64,
              let first = name.unicodeScalars.first,
              isASCIIAlpha(first) || first == "_"
        else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy {
            isASCIIAlpha($0) || (0x30 ... 0x39).contains($0.value)
                || $0 == "_" || $0 == "-" || $0 == "."
        }
    }

    private static func isSafeGemmaKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy {
            isASCIIAlpha($0) || (0x30 ... 0x39).contains($0.value)
                || $0 == "_" || $0 == "$" || $0 == "-"
        }
    }

    private static func sanitizedStem(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if isASCIIAlpha(scalar) || (0x30 ... 0x39).contains(scalar.value) || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else if result.last != "_" {
                result.append("_")
            }
            if result.utf8.count >= 24 { break }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "call" : trimmed
    }

    private static func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
        (0x41 ... 0x5A).contains(scalar.value) || (0x61 ... 0x7A).contains(scalar.value)
    }
}
