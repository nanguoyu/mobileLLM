// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts
import AgentRuntime

/// The persistent bottom control bar (spec §20): the conversation's approval mode and reasoning effort
/// are always visible and switchable in place, without opening a menu tree.
struct ConversationModeBar: View {
    let chat: ChatStore

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Menu {
                approvalOption("Ask", mode: nil)
                approvalOption("Safe preset", mode: .safePreset)
                approvalOption("Full access", mode: .fullAccess)
            } label: {
                Label(approvalLabel, systemImage: "lock.shield")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Menu {
                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                    Button {
                        chat.conversationReasoningEffort = effort
                    } label: {
                        if chat.effectiveReasoningEffort == effort {
                            Label(effort.rawValue.capitalized, systemImage: "checkmark")
                        } else {
                            Text(effort.rawValue.capitalized)
                        }
                    }
                }
            } label: {
                Label("Effort: \(chat.effectiveReasoningEffort.rawValue.capitalized)",
                      systemImage: "brain")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.surface2)
        .accessibilityElement(children: .contain)
    }

    private var approvalLabel: String {
        switch chat.conversationApprovalMode ?? .ask {
        case .ask: "Approval: Ask"
        case .safePreset: "Approval: Safe preset"
        case .fullAccess: "Approval: Full access"
        }
    }

    @ViewBuilder
    private func approvalOption(_ title: String, mode: AgentApprovalMode?) -> some View {
        Button {
            chat.conversationApprovalMode = mode
        } label: {
            if (chat.conversationApprovalMode ?? .ask) == (mode ?? .ask) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
