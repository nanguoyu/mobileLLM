// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import AgentContracts
import AgentRuntime

/// The persistent bottom control bar (spec §20): the conversation's approval mode and reasoning effort
/// are always visible and switchable in place, without opening a menu tree.
struct ConversationModeBar: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let chat: ChatStore

    private var layout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        layout {
            Menu {
                approvalOption("Ask", mode: .ask)
                approvalOption("Safe preset", mode: .safePreset)
                approvalOption("Full access", mode: .fullAccess)
            } label: {
                Label(approvalLabel.replacingOccurrences(of: "Approval: ", with: ""), systemImage: "lock.shield")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(approvalLabel)
            .accessibilityHint("Applies to the next message")

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
                Label(chat.effectiveReasoningEffort.rawValue.capitalized,
                      systemImage: "brain")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Effort: \(chat.effectiveReasoningEffort.rawValue.capitalized)")
            .accessibilityHint("Applies to the next message")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 2)
        .background(Theme.surface2)
        .accessibilityElement(children: .contain)
    }

    private var approvalLabel: String {
        switch chat.effectiveApprovalMode {
        case .ask: "Approval: Ask"
        case .safePreset: "Approval: Safe preset"
        case .fullAccess: "Approval: Full access"
        }
    }

    private func approvalOption(_ title: String, mode: AgentApprovalMode?) -> some View {
        let isSelected = mode.map { chat.effectiveApprovalMode == $0 } ?? false
        return Button {
            chat.conversationApprovalMode = mode
        } label: {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
