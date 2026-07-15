// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// A bottom banner that surfaces `ChatStore.banner` on whichever screen the user is on (DESIGN §2.5 /
/// §4). Carries an optional forward action (Undo / Switch to 8B) so errors + destructive actions
/// never dead-end.
struct BannerHost: ViewModifier {
    @Bindable var chat: ChatStore

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = chat.banner {
                banner(toast)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.bottom, Theme.Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.canvas, value: chat.banner)
    }

    private func banner(_ toast: Toast) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon(toast.kind))
                .foregroundStyle(tint(toast.kind))
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.sm)
            if let title = toast.actionTitle {
                Button(title) { chat.runBannerAction() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            } else {
                Button { chat.dismissBanner() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
    }

    private func icon(_ kind: Toast.Kind) -> String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "thermometer.medium"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ kind: Toast.Kind) -> Color {
        switch kind {
        case .info: Theme.accent
        case .success: Theme.fitGreen
        case .warning: Theme.fitAmber
        case .error: Theme.danger
        }
    }
}

extension View {
    /// Attach the shared chat banner host.
    func bannerHost(_ chat: ChatStore) -> some View { modifier(BannerHost(chat: chat)) }
}
