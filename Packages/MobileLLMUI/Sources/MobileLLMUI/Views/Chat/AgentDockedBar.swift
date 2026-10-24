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
        AgentApprovalDecisionBar(approval: approval) { approved in
            await store.decideApproval(
                conversationID: conversationID,
                approvalID: approval.approvalID,
                approved: approved
            )
        }
    }
}

/// The production approval surface, isolated so deterministic UI tests exercise the exact same view
/// that a durable run presents. The synchronous latch closes before either async command starts, so
/// two taps cannot enqueue two decisions from one projection.
struct AgentApprovalDecisionBar: View {
    let approval: AgentApprovalCard
    let decide: @MainActor @Sendable (Bool) async -> Void
    @State private var decisionPending = false

    var body: some View {
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
                    .accessibilityIdentifier("approval.title")
                    .accessibilitySortPriority(7)
                Spacer(minLength: 0)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if !approval.preview.isEmpty {
                        approvalDetail(
                            label: "Action",
                            value: approval.preview,
                            identifier: "approval.preview",
                            priority: 6
                        )
                    }
                    if let destination = approval.destination {
                        approvalDetail(
                            label: "Destination",
                            value: destination,
                            identifier: "approval.destination",
                            priority: 5
                        )
                    }
                    if !approval.dataCategories.isEmpty {
                        approvalDetail(
                            label: "Data",
                            value: approval.dataCategories.joined(separator: ", "),
                            identifier: "approval.data",
                            priority: 4
                        )
                    }
                    if !approval.effects.isEmpty {
                        approvalDetail(
                            label: "Effects",
                            value: approval.effects.joined(separator: ", "),
                            identifier: "approval.effects",
                            priority: 3
                        )
                    }
                    if approval.isExternalWrite {
                        Text("This may change data outside mobileLLM.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("approval.warning")
                            .accessibilitySortPriority(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.sm) {
                    decisionButton(approved: false)
                    decisionButton(approved: true)
                }
                VStack(spacing: Theme.Space.xs) {
                    decisionButton(approved: false)
                    decisionButton(approved: true)
                }
            }
            Text(approval.isConversationScoped
                 ? "Authorizes this model for the rest of this conversation."
                 : "Authorizes only this exact prepared operation.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("approval.scope")
                .accessibilitySortPriority(1)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.surface2)
        .overlay(alignment: .top) { Divider().background(Theme.hairline) }
    }

    private func approvalDetail(
        label: String,
        value: String,
        identifier: String,
        priority: Double
    ) -> some View {
        Text("\(label): \(value)")
            .font(.caption)
            .foregroundStyle(label == "Action" ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
            .accessibilitySortPriority(priority)
    }

    private func decisionButton(approved: Bool) -> some View {
        Button {
            guard !decisionPending else { return }
            decisionPending = true
            Task { @MainActor in
                await decide(approved)
                decisionPending = false
            }
        } label: {
            Text(buttonTitle(approved: approved))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioButtonStyle(approved ? .primary : .secondary))
        .disabled(decisionPending)
        .accessibilityLabel("\(approved ? "Approve" : "Deny") \(approval.toolName)")
        .accessibilityHint(decisionPending ? "Decision in progress" : "Submits one decision")
        .accessibilityIdentifier(approved ? "approval.approve" : "approval.deny")
        .accessibilitySortPriority(approved ? 0.8 : 0.9)
    }

    private func buttonTitle(approved: Bool) -> String {
        guard approved else { return "Deny" }
        if approval.isConversationScoped { return "Allow model" }
        return approval.isExternalWrite ? "Approve once" : "Approve"
    }
}

// MARK: Question

extension AgentDockedBar {
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

#if DEBUG && !os(macOS)
/// Model-free simulator fixture for AHT-UI-002. It renders the production approval component with
/// deliberately long authority text and exposes only a decision count, never an alternate approval path.
struct ApprovalAccessibilityFixtureView: View {
    @State private var decisionCount = 0

    private let card = AgentApprovalCard(
        approvalID: ApprovalID(rawValue: UUID(uuidString: "A11E0000-0000-4000-8000-000000000002")!),
        toolName: "Calendar writer",
        destination: "calendar://Personal/Events/Quarterly planning with the complete invited-attendee list",
        preview: "Create an event titled Quarterly planning tomorrow at 09:30 and invite the selected attendees without changing any other event.",
        dataCategories: ["calendar title", "start time", "attendee addresses"],
        effects: ["creates one calendar event", "sends invitations"],
        isExternalWrite: true,
        isConversationScoped: false
    )

    var body: some View {
        ScrollView {
            AgentApprovalDecisionBar(approval: card) { _ in
                decisionCount += 1
                // Keep the command in flight long enough for XCUITest to prove that a second
                // accessibility activation cannot enqueue another decision.
                try? await Task.sleep(for: .seconds(3))
            }
            Text("\(decisionCount)")
                .accessibilityLabel("Approval decision count")
                .accessibilityValue("\(decisionCount)")
                .accessibilityIdentifier("approval.fixture.decision-count")
        }
        .background(Theme.bg)
        .dynamicTypeSize(.accessibility5)
    }
}
#endif
