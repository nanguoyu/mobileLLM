// SPDX-License-Identifier: MIT

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Manual keyboard tracking — the FlowDown lesson. SwiftUI's automatic keyboard avoidance silently
/// no-ops in this app's TabView → NavigationStack → pushed-detail tree (every layout variant left the
/// composer's input row buried under the keyboard by the same amount), so we do what UIKit apps do with
/// `keyboardLayoutGuide`: observe the keyboard frame ourselves and pad the composer by the overlap,
/// with `.ignoresSafeArea(.keyboard)` switching the broken automatic path fully off.
@MainActor
@Observable
public final class KeyboardHeight {
    /// How much of the screen the keyboard currently covers, in points (0 when hidden). Includes the
    /// home-indicator region — subtract the container's bottom safe-area inset when padding content
    /// that already respects it.
    public private(set) var overlap: CGFloat = 0

    #if os(iOS)
    /// nonisolated(unsafe): deinit runs off the main actor and only hands the tokens to the (thread-safe)
    /// NotificationCenter.removeObserver — the array is never mutated after init.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    public init() {
        let nc = NotificationCenter.default
        let apply: @Sendable (Notification) -> Void = { note in
            guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            else { return }
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A hidden keyboard reports a frame at/below the screen bottom → overlap 0.
                let overlap = max(0, UIScreen.main.bounds.maxY - end.minY)
                withAnimation(.easeOut(duration: max(0.1, duration))) { self.overlap = overlap }
            }
        }
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                     object: nil, queue: .main, using: apply))
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                     object: nil, queue: .main, using: apply))
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
    #else
    public init() {}   // macOS: no software keyboard — overlap stays 0
    #endif
}
