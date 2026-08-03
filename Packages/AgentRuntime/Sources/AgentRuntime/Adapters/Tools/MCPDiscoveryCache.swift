// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import LLMCore

/// Explicit MCP discovery results cached for the agent runtime.
///
/// Discovery (`initialize` + `tools/list`) runs ONLY from the user's server setup/refresh UI; prompt
/// compilation and run submission never connect to an MCP server (spec §13). The cache is the single
/// source of truth the agent catalog advertises, keyed by the server's stable random identity.
public final class MCPDiscoveryCache: @unchecked Sendable {
    /// The app-wide discovery cache: the settings UI is the only writer, the agent catalog the reader.
    public static let shared = MCPDiscoveryCache(defaults: .standard)

    private struct Entry: Codable {
        var server: MCPServer
        var specs: [MCPToolSpec]
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let persistenceKey: String
    private var entries: [UUID: Entry] = [:]

    public init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = "mobilellm.mcpDiscovery.v1"
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        if let data = defaults.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            self.entries = decoded.reduce(into: [:]) { result, pair in
                guard let stableID = UUID(uuidString: pair.key) else { return }
                result[stableID] = pair.value
            }
        }
    }

    public func update(server: MCPServer, specs: [MCPToolSpec]) {
        lock.lock(); defer { lock.unlock() }
        entries[server.stableID] = Entry(server: server, specs: specs)
        persistLocked()
    }

    /// Preserve discovered specs when a server's enable/mute settings change without re-probing.
    public func upsert(server: MCPServer) {
        lock.lock(); defer { lock.unlock() }
        let specs = entries[server.stableID]?.specs ?? []
        entries[server.stableID] = Entry(server: server, specs: specs)
        persistLocked()
    }

    public func remove(serverStableID: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries[serverStableID] = nil
        persistLocked()
    }

    public func specs(serverStableID: UUID) -> [MCPToolSpec] {
        lock.lock(); defer { lock.unlock() }
        return entries[serverStableID]?.specs ?? []
    }

    /// The server snapshot at discovery time. The runtime calls the endpoint that was explicitly
    /// discovered; editing the URL requires an explicit re-test, so a changed URL cannot silently
    /// redirect previously approved operations.
    public func server(serverStableID: UUID) -> MCPServer? {
        lock.lock(); defer { lock.unlock() }
        return entries[serverStableID]?.server
    }

    /// The exact Tool V2 descriptors the runtime may advertise for the currently enabled servers.
    public func descriptors(
        for servers: [MCPServer],
        trustRevision: String = "mcp.v1"
    ) -> [AgentToolDescriptor] {
        lock.lock(); defer { lock.unlock() }
        var result: [AgentToolDescriptor] = []
        for server in servers
            where server.isEnabled && !server.url.trimmingCharacters(in: .whitespaces).isEmpty
        {
            guard let specs = entries[server.stableID]?.specs else { continue }
            for spec in specs where !server.disabledTools.contains(spec.name) {
                guard let descriptor = try? MCPToolV2Adapter.descriptor(
                    spec: spec,
                    serverStableID: server.stableID,
                    trustRevision: trustRevision
                ) else { continue }
                result.append(descriptor)
            }
        }
        return result.sorted { $0.id.description < $1.id.description }
    }

    private func persistLocked() {
        let encoded = entries.reduce(into: [String: Entry]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        if let data = try? JSONEncoder().encode(encoded) {
            defaults.set(data, forKey: persistenceKey)
        }
    }
}
