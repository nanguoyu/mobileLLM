// SPDX-License-Identifier: MIT
import AgentContracts

/// Names are conveniences over an already permitted catalog, never a new authority source.
public enum WorkflowToolAliases {
    public static func uniqueAliases(for ids: [AgentToolLogicalID]) -> [String: String] {
        var matches: [String: Set<String>] = [:]
        for id in ids {
            for alias in [id.description, id.providerID + "." + id.name, id.name] {
                matches[alias, default: []].insert(id.description)
            }
        }
        return matches.compactMapValues { $0.count == 1 ? $0.first : nil }
    }
}
