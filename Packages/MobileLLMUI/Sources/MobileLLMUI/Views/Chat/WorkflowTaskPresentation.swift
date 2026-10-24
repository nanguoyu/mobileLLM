// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts

/// A logical task may have several continuations and retry attempts. Coordination calls are separate.
struct WorkflowTaskGroup: Identifiable {
    let id: String
    let calls: [DynamicWorkflowChildPresentation]
    var latest: DynamicWorkflowChildPresentation { calls[calls.count - 1] }
    var title: String { WorkflowDisplay.name(latest.task?.taskID ?? latest.label ?? "Task \(latest.ordinal)") }
}

enum WorkflowDisplay {
    static func planningStatus(_ state: AgentRunState) -> String {
        switch state {
        case .created, .preparing: "Preparing plan"
        case .waitingForModel: "Waiting for model"
        case .generating, .synthesizing: "Planning"
        case .validatingAction, .executingTools: "Checking plan"
        case .waitingForApproval: "Needs approval"
        case .waitingForUser: "Needs your input"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .waitingForForeground: "Waiting for foreground"
        case .waitingForReconciliation: "Needs your review"
        case .completed: "Preparing tasks"
        case .failed: "Planning failed"
        case .cancelled: "Planning stopped"
        }
    }

    static func needsAttention(_ call: DynamicWorkflowChildPresentation) -> Bool {
        call.status == .uncertain || (call.status == .submitted &&
            [.waitingForApproval, .waitingForUser, .waitingForReconciliation].contains(call.executionState))
    }

    static func summary(_ calls: [DynamicWorkflowChildPresentation]) -> String {
        let groups = tasks(calls)
        let completed = groups.filter { $0.latest.status == .completed }.count
        let failed = groups.filter { [.failed, .unavailable].contains($0.latest.status) }.count
        return "\(groups.count) tasks · \(completed) completed" + (failed > 0 ? " · \(failed) failed" : "")
    }

    static func name(_ value: String) -> String {
        let text = value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func tasks(_ calls: [DynamicWorkflowChildPresentation]) -> [WorkflowTaskGroup] {
        let workers = calls.filter { !$0.isCoordinator }.sorted {
            $0.ordinal == $1.ordinal ? $0.attempt < $1.attempt : $0.ordinal < $1.ordinal
        }
        var order: [String] = []
        var groups: [String: [DynamicWorkflowChildPresentation]] = [:]
        for call in workers {
            let id = call.task?.taskID ?? "call-\(call.ordinal)"
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(call)
        }
        return order.map { WorkflowTaskGroup(id: $0, calls: groups[$0]!) }
    }

    static func inputs(for call: DynamicWorkflowChildPresentation,
                       in calls: [DynamicWorkflowChildPresentation]) -> [DynamicWorkflowChildPresentation] {
        (call.task?.inputArtifactIDs ?? []).compactMap { id in
            let sources = calls.filter { source in
                guard source.task?.outputArtifactID == id else { return false }
                if let prepared = call.preparedSequence, let settled = source.settledSequence {
                    return settled < prepared
                }
                return true
            }
            // A later retry can reuse the same logical artifact name. Resolve as of the consumer's
            // preparation, never replace the result it actually consumed with a newer attempt.
            if call.preparedSequence != nil {
                return sources.filter { $0.settledSequence != nil }.max {
                    ($0.settledSequence ?? 0) < ($1.settledSequence ?? 0)
                }
            }
            return sources.count == 1 ? sources.first : nil
        }
    }
}

extension DynamicWorkflowChildPresentation {
    var isCoordinator: Bool { agentType == "workflow-supervisor" }
    var taskTitle: String { WorkflowDisplay.name(task?.taskID ?? label ?? "Task \(ordinal)") }

    func statusText(workflowState: DynamicWorkflowPresentationState, attached: Bool) -> String {
        guard status == .prepared || status == .submitted else { return status.label }
        if workflowState == .paused { return "Paused" }
        if workflowState == .waitingForForeground { return "Waiting for foreground" }
        if workflowState == .running && !attached { return "Needs resume" }
        guard let executionState else { return status == .prepared ? "Queued" : "Submitted" }
        switch executionState {
        case .created, .preparing: return "Preparing"
        case .waitingForModel: return "Waiting for model"
        case .generating: return "Working"
        case .validatingAction: return "Checking action"
        case .executingTools: return "Using tools"
        case .waitingForApproval: return "Needs approval"
        case .waitingForUser: return "Needs your input"
        case .synthesizing: return "Writing result"
        case .pausing: return "Pausing"
        case .paused: return "Paused"
        case .waitingForForeground: return "Waiting for foreground"
        case .waitingForReconciliation: return "Needs review"
        case .completed, .failed, .cancelled: return "Saving outcome"
        }
    }
}
