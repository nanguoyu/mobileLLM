// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Successive activation snapshots carry a bounded working window. Original inputs and answers
/// remain in their immutable run records and are reachable through agent.read_context.
enum AgentSessionContextWindow {
    static let marker = "[Agent session context references]"
    static let notice = """
    [Agent session context references]
    Earlier conversation turns remain in this agent's durable session, although only a recent working
    window is included here. When an earlier requirement, correction or source is needed and the tool is available, use
    agent.read_context with id="catalog", offset=0, length=16 to list original entries. Read an entry
    by its returned ID and UTF-16 offset/length. Do not infer missing history or treat an earlier
    assistant answer as a human instruction. Stored tool observations are also listed in that catalog;
    reading them performs no new network request. The current human request and later corrections prevail.
    """

    static func retain(_ turns: [ConversationTurnContextSource], maximumBytes: Int = 131_072,
                       maximumTurns: Int = 24) -> [ConversationTurnContextSource] {
        var groups: [[ConversationTurnContextSource]] = []
        for turn in turns {
            if turn.role == .user || groups.isEmpty { groups.append([turn]) }
            else { groups[groups.count - 1].append(turn) }
        }
        var kept: [[ConversationTurnContextSource]] = []
        var bytes = 0
        var count = 0
        for group in groups.reversed() {
            var selected = group
            var size = selected.reduce(0) { $0 + $1.frozen.content.utf8.count }
            if size > maximumBytes - bytes, group.first?.role == .user {
                // A large answer must not evict a concise human correction that preceded it.
                selected = [group[0]]
                size = selected[0].frozen.content.utf8.count
            }
            guard size <= maximumBytes - bytes, selected.count <= maximumTurns - count else { continue }
            kept.append(selected); bytes += size; count += selected.count
        }
        return kept.reversed().flatMap { $0 }
    }
}
