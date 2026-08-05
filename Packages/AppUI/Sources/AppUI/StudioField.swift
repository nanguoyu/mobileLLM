// SPDX-License-Identifier: MIT

import SwiftUI

/// The app's shared inset-field look (System prompt editor, Online service editor, etc.): recessed
/// `surface2` fill, hairline border, and the standard field radius — so a hand-typed setting never
/// renders as a system-default rounded rectangle that fights the ink-wash theme.
public struct StudioField: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .font(.callout)
            .background(
                Theme.surface2,
                in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
    }
}

public extension View {
    /// Applies the shared studio field style. Pair with `.textFieldStyle(.plain)` on TextFields and
    /// `.textFieldStyle(.plain)`/`.scrollContentBackground(.hidden)` on secure/text editors.
    func studioField() -> some View {
        modifier(StudioField())
    }
}
