// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts

/// Approval, question, and reconciliation surfaces docked ABOVE the composer, visible only while the
/// run needs a human decision (Codex/Claude Code pattern: the prompt appears next to the input, never
/// buried inside the thread). Hidden entirely when the run has nothing to ask.
struct AgentDockedBar: View {
    let store: AgentRunStore
    let conversationID: UUID
    @State private var userResponse = ""

    private var run: AgentRunPresentation? { store.presentation(for: conversationID) }

    private var hasContent: Bool {
        guard let run else { return false }
        return run.pendingApproval != nil
            || run.pendingUserInput != nil
            || run.state == .waitingForReconciliation
    }

    var body: some View {
        Group {
            if let run {
                if let approval = run.pendingApproval {
                    approvalBar(approval)
                } else if let request = run.pendingUserInput {
                    userInputBar(request)
                } else if run.state == .waitingForReconciliation,
                          case .reconciliation(let invocationID)? = run.blockingReason
                {
                    reconciliationBar(invocationID)
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(Motion.spring, value: hasContent)
    }

    // MARK: Approval

    private func approvalBar(_ approval: AgentApprovalCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: approval.isExternalWrite
                      ? "externaldrive.fill.badge.exclamationmark"
                      : "eye.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.caption)
                Text("Approve \(approval.toolName)?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            if !approval.preview.isEmpty {
                Text(approval.preview)
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let destination = approval.destination {
                Text(destination)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack(spacing: Theme.Space.sm) {
                Button {
                    Task { await store.decideApproval(
                        conversationID: conversationID,
                        approvalID: approval.approvalID,
                        approved: false
                    ) }
                } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioButtonStyle(.secondary))
                .accessibilityLabel("Deny \(approval.toolName)")

                Button {
                    Task { await store.decideApproval(
                        conversationID: conversationID,
                        approvalID: approval.approvalID,
                        approved: true
                    ) }
                } label: {
                    Text(approval.isExternalWrite || approval.isConversationScoped
                         ? "Approve once" : "Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioButtonStyle(.primary))
                .accessibilityLabel("Approve \(approval.toolName)")
            }
            Text(approval.isConversationScoped
                 ? "Authorizes this model for the rest of this conversation."
                 : "Authorizes only this exact prepared operation.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.surface2)
        .overlay(alignment: .top) { Divider().background(Theme.hairline) }
    }

    // MARK: Question

    private func userInputBar(_ request: UserInputRequest) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.caption)
                Text("The agent needs an answer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            Text(request.prompt)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            HStack(spacing: Theme.Space.sm) {
                TextField("Your answer…", text: $userResponse, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .lineLimit(1 ... 3)
                    .padding(Theme.Space.sm)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .onSubmit { sendResponse() }
                Button(action: sendResponse) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(userResponse.isEmpty ? Theme.textTertiary : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(userResponse.isEmpty)
                .accessibilityLabel("Send answer to agent")
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.surface2)
        .overlay(alignment: .top) { Divider().background(Theme.hairline) }
    }

    private func sendResponse() {
        let text = userResponse
        userResponse = ""
        Task { await store.respond(conversationID: conversationID, text: text) }
    }

    // MARK: Reconciliation

    private func reconciliationBar(_ invocationID: ToolInvocationID) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Label("Did the external action happen?", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("The tool stopped before its outcome could be proven. Tell the agent what actually happened.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.Space.sm) {
                Button("It succeeded") {
                    Task { await store.reconcile(
                        conversationID: conversationID,
                        invocationID: invocationID,
                        decision: .succeeded
                    ) }
                }
                .buttonStyle(StudioButtonStyle(.primary))
                Button("It failed") {
                    Task { await store.reconcile(
                        conversationID: conversationID,
                        invocationID: invocationID,
                        decision: .failed
                    ) }
                }
                .buttonStyle(StudioButtonStyle(.secondary))
                Button("Abandon", role: .destructive) {
                    Task { await store.reconcile(
                        conversationID: conversationID,
                        invocationID: invocationID,
                        decision: .abandoned
                    ) }
                }
                .buttonStyle(StudioButtonStyle(.secondary))
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.surface2)
        .overlay(alignment: .top) { Divider().background(Theme.hairline) }
    }
}
