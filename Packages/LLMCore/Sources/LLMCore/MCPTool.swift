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
        catch is CancellationError {
            // `Tool.execute` predates throwing tools, so cancellation cannot be rethrown through the
            // protocol. Return quietly; ToolLoop checks cancellation immediately after execute and never
            // publishes this as a failed tool result.
            return ""
        }
        catch { return "MCP tool \"\(spec.name)\" failed: \(error.localizedDescription)" }
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
    /// Build the live tool set: the standard local tools plus every tool from each **enabled** MCP server
    /// (connect + list once, sharing a client per server), minus the tools the user muted. Servers that
    /// fail to connect are skipped so one bad URL never breaks tools entirely. Cancellation is different:
    /// it aborts the whole assembly so callers can never cache a registry built from only an early subset.
    static func build(mcpServers: [MCPServer], includeStandard: Bool = true,
                      session: URLSession = .shared) async throws -> ToolRegistry {
        try Task.checkCancellation()
        var tools: [Tool] = includeStandard ? [CalculatorTool(), DateTimeTool(), WebSearchTool()] : []
        for server in mcpServers where server.isEnabled && !server.url.isEmpty {
            try Task.checkCancellation()
            let client = MCPClient(server: server, session: session)
            do {
                let specs = try await client.connect()
                try Task.checkCancellation()
                tools.append(contentsOf: specs.filter { !server.disabledTools.contains($0.name) }
                                              .map { MCPTool(client: client, spec: $0) })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A server is an optional provider. Isolate its ordinary protocol/network failure and
                // continue assembling the other servers; only cancellation aborts the whole operation.
                try Task.checkCancellation()
                continue
            }
        }
        try Task.checkCancellation()
        return ToolRegistry(tools)
    }
}
