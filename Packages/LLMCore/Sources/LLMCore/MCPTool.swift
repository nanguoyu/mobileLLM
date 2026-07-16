// SPDX-License-Identifier: MIT

import Foundation

/// Bridges one MCP-server tool into our local `Tool` protocol, so a remote tool advertises + executes
/// exactly like a built-in one and drops straight into `ToolLoop`. Its schema is derived from the MCP
/// tool's JSON Schema; `execute` forwards to the shared `MCPClient`.
public struct MCPTool: Tool {
    private let client: MCPClient
    private let spec: MCPToolSpec
    public init(client: MCPClient, spec: MCPToolSpec) { self.client = client; self.spec = spec }

    public var schema: ToolSchema {
        ToolSchema(name: spec.name,
                   description: spec.description.isEmpty ? "MCP tool \(spec.name)." : spec.description,
                   parameters: Self.params(fromInputSchema: spec.inputSchemaJSON))
    }

    public func execute(argumentsJSON: String) async -> String {
        do { return try await client.call(name: spec.name, argumentsJSON: argumentsJSON) }
        catch { return "MCP tool \"\(spec.name)\" failed: \(error)" }
    }

    /// Flatten a JSON-Schema `{type:object, properties:{…}, required:[…]}` into our simple param list.
    static func params(fromInputSchema json: String) -> [ToolParam] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let props = obj["properties"] as? [String: Any] else { return [] }
        let required = Set(obj["required"] as? [String] ?? [])
        return props.compactMap { key, value -> ToolParam? in
            let v = value as? [String: Any] ?? [:]
            let kind: ToolParam.Kind
            switch (v["type"] as? String)?.lowercased() {
            case "number", "integer": kind = .number
            case "boolean": kind = .boolean
            default: kind = .string
            }
            return ToolParam(name: key, kind: kind, description: v["description"] as? String ?? "",
                             required: required.contains(key))
        }.sorted { $0.name < $1.name }
    }
}

public extension ToolRegistry {
    /// Build the live tool set: the standard local tools plus every tool from each configured MCP server
    /// (connect + list once, sharing a client per server). Servers that fail to connect are skipped so one
    /// bad URL never breaks tools entirely.
    static func build(mcpServers: [MCPServer], includeStandard: Bool = true,
                      session: URLSession = .shared) async -> ToolRegistry {
        var tools: [Tool] = includeStandard ? [CalculatorTool(), DateTimeTool(), WebSearchTool()] : []
        for server in mcpServers where !server.url.isEmpty {
            let client = MCPClient(server: server, session: session)
            if let specs = try? await client.connect() {
                tools.append(contentsOf: specs.map { MCPTool(client: client, spec: $0) })
            }
        }
        return ToolRegistry(tools)
    }
}
