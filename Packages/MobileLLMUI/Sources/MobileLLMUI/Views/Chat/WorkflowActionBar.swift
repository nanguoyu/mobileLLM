// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

struct WorkflowActionBar: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let store: WorkflowStore?
    let workflowID: UUID
    let state: DynamicWorkflowPresentationState
    let attached: Bool

    private var controlsLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        dynamicActions(state, workflowID: workflowID, attached: attached)
            .buttonStyle(.bordered).controlSize(.large)
    }

    @ViewBuilder
    private func dynamicActions(
        _ state: DynamicWorkflowPresentationState,
        workflowID: UUID,
        attached: Bool
    ) -> some View {
        let busy = store?.actioningWorkflowIDs.contains(workflowID) == true
        switch state {
        case .waitingForLaunchApproval:
            controlsLayout {
                Button("Run workflow", systemImage: "play.fill") {
                    Task { await store?.runDynamic(workflowID: workflowID) }
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel", role: .destructive) {
                    Task { await store?.denyDynamic(workflowID: workflowID) }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("workflow.run")
        case .queued:
            Button("Start", systemImage: "play.fill") {
                Task { await store?.startDynamic(workflowID: workflowID) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .accessibilityIdentifier("workflow.start")
        case .running where !attached:
            controlsLayout {
                Button("Resume", systemImage: "play.fill") {
                    Task { await store?.resumeDynamic(workflowID: workflowID) }
                }
                .buttonStyle(.borderedProminent)
                Button("Stop", role: .destructive) {
                    Task { await store?.stopDynamic(workflowID: workflowID) }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("workflow.interrupted")
        case .running, .pausing:
            controlsLayout {
                Button("Pause", systemImage: "pause.fill") {
                    Task { await store?.pauseDynamic(workflowID: workflowID) }
                }
                Button("Stop", role: .destructive) {
                    Task { await store?.stopDynamic(workflowID: workflowID) }
                }
            }.disabled(busy || state == .pausing)
        case .paused, .waitingForForeground:
            controlsLayout {
                Button("Resume", systemImage: "play.fill") {
                    Task { await store?.resumeDynamic(workflowID: workflowID) }
                }
                Button("Stop", role: .destructive) {
                    Task { await store?.stopDynamic(workflowID: workflowID) }
                }
            }.disabled(busy)
        case .waitingForReconciliation:
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Confirm what happened to the uncertain external action before continuing.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                controlsLayout {
                    Button("Succeeded") {
                        Task {
                            await store?.reconcileDynamic(
                                workflowID: workflowID,
                                decision: .succeeded
                            )
                        }
                    }
                    Button("Did not happen") {
                        Task {
                            await store?.reconcileDynamic(
                                workflowID: workflowID,
                                decision: .failed
                            )
                        }
                    }
                    Button("Abandon", role: .destructive) {
                        Task {
                            await store?.reconcileDynamic(
                                workflowID: workflowID,
                                decision: .abandoned
                            )
                        }
                    }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("workflow.reconciliation")
        default:
            EmptyView()
        }
    }

}
