// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

/// Native acceptance metadata and the original report, read by the existing task detail loader.
struct WorkflowReviewView: View {
    let result: WorkflowGoalResultLink
    let report: WorkflowReviewReport?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Label("Acceptance review", systemImage: "checklist").font(.headline)
            Text("Agent assessment of the linked input results")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if let review = result.review {
                ForEach(review.criteria, id: \.id) { criterion in
                    let check = report?.checks.first { $0.id == criterion.id }
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(criterion.requirement).font(.callout.weight(.medium))
                        if let check {
                            Label(label(check.status), systemImage: symbol(check.status))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(check.status == .pass ? Theme.accent : Theme.fitAmber)
                            Text(check.detail).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
            if let missing = result.reviewMissingTools, !missing.isEmpty {
                Label("Required tools were not run: " + missing.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.fitAmber)
            }
            if let tools = result.reviewToolEvidence, !tools.isEmpty {
                DisclosureGroup("Recorded tool executions (\(tools.count))") {
                    ForEach(tools, id: \.invocationID) { tool in
                        Text(tool.toolID).font(.caption).textSelection(.enabled)
                    }
                }.font(.callout)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).studioCard()
            .accessibilityIdentifier("workflow.task.review")
    }

    private func label(_ status: WorkflowReviewStatus) -> String {
        switch status { case .pass: "Meets criterion"; case .revise: "Changes requested"; case .blocked: "Cannot verify" }
    }
    private func symbol(_ status: WorkflowReviewStatus) -> String {
        switch status { case .pass: "checkmark.circle"; case .revise: "arrow.triangle.2.circlepath"; case .blocked: "exclamationmark.circle" }
    }
}
