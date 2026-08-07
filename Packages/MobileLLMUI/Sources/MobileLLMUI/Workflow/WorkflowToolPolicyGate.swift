// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import LLMCore

/// The workflow tool-policy gate (spec §2 decision 3, §14, §33 gap 1).
///
/// Staged workflows may only inherit tools the initiating conversation already allows, and children
/// may only narrow that set (enforced by `SubagentSpawner`'s strict ceiling attenuation). When a
/// required research tool is disabled, the launcher refuses to start and the app asks the user to
/// explicitly enable it. An approval mode decides whether a concrete operation prompts — it never
/// substitutes for tool selection.
public enum WorkflowToolPolicyGate {
    /// The research toolset staged workflows rely on: web search + page reading. Wikipedia, memory,
    /// MCP, and privacy tools remain optional — a workflow advertises only what the conversation
    /// already allows.
    public static let requiredToolIDs: Set<ToolID> = [.webSearch, .fetchWebpage]

    /// Stable logical identity for one built-in tool, using the same mapping `ToolRegistry` uses.
    public static func logicalID(for toolID: ToolID) -> AgentToolLogicalID {
        // Valid constant names; safe by construction.
        try! AgentToolLogicalID(providerID: "builtin", name: toolID.rawValue)
    }

    /// Required tools the conversation cannot currently provide, in stable order.
    ///
    /// - `policy` is the conversation's materialized tool policy (nil for legacy conversations that
    ///   have not materialized one yet — the global toggle set is then the effective policy).
    /// - `catalogToolNames` is the assembled catalog (`settings`-derived), because a conversation
    ///   policy can never widen the catalog.
    public static func missingTools(
        policy: ConversationToolPolicy?,
        catalogToolNames: [String],
        toolsEnabled: Bool
    ) -> [ToolID] {
        let catalog = Set(catalogToolNames)
        let catalogLogicalIDs = Set(catalog.map { logicalID(named: $0) })
        func missing(under masterEnabled: Bool, allowed: Set<AgentToolLogicalID>) -> [ToolID] {
            guard masterEnabled else {
                return requiredToolIDs.sorted(by: stableOrder)
            }
            return requiredToolIDs.filter {
                !allowed.contains(logicalID(for: $0)) || !catalog.contains($0.rawValue)
            }.sorted(by: stableOrder)
        }
        guard let policy else {
            return missing(under: toolsEnabled, allowed: catalogLogicalIDs)
        }
        return missing(under: policy.masterEnabled, allowed: Set(policy.allowedToolIDs))
    }

    /// User-visible name for a gate-listed tool ("web_search" → "Web search").
    public static func displayName(for toolID: ToolID) -> String {
        switch toolID {
        case .webSearch: return "Web search"
        case .fetchWebpage: return "Webpage reader"
        case .wikipedia: return "Wikipedia"
        default:
            let spaced = toolID.rawValue.replacingOccurrences(of: "_", with: " ")
            guard let first = spaced.first else { return spaced }
            return String(first).uppercased() + spaced.dropFirst()
        }
    }

    private static func logicalID(named name: String) -> AgentToolLogicalID {
        // Valid constant names; safe by construction.
        try! AgentToolLogicalID(providerID: "builtin", name: name)
    }

    /// Stable display order (ToolID.allCases): "Web search" before "Webpage reader".
    private static func stableOrder(_ lhs: ToolID, _ rhs: ToolID) -> Bool {
        guard let li = ToolID.allCases.firstIndex(of: lhs),
              let ri = ToolID.allCases.firstIndex(of: rhs)
        else { return lhs.rawValue < rhs.rawValue }
        return li < ri
    }
}

/// Typed failure the workflow launcher reports when the conversation has not explicitly enabled a
/// required research tool. The UI maps this to the user-input/enable gate; approval mode is never
/// consulted for tool selection.
public enum WorkflowToolPolicyGateError: LocalizedError, Equatable, Sendable {
    case toolsRequired([ToolID])

    public var errorDescription: String? {
        switch self {
        case .toolsRequired(let tools):
            let names = tools.map(WorkflowToolPolicyGate.displayName).joined(separator: ", ")
            return "Workflow needs tools that are off: \(names)."
        }
    }
}
