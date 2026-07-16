// SPDX-License-Identifier: MIT

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// The FlowDown primitive, verbatim in spirit: its SafeInputView pins the input bar's bottom to
// `keyboardLayoutGuide.top` and never touches keyboard notifications. Notifications proved exactly as
// unreliable here as their reputation — the photo sheet's present/dismiss storm left the observed height
// stuck high with no keyboard and reset it to zero with the keyboard up. The layout guide has no such
// races: UIKit itself keeps a tracking view pinned between the guide's top and the window bottom, and
// its measured height IS the ground truth (bottom safe-area inset when hidden, keyboard height when up),
// updated frame-by-frame through the keyboard animation and interactive dismissal.

#if os(iOS)
/// SwiftUI leaf that reports the EXTRA bottom lift the keyboard demands (0 when hidden, keyboard height
/// minus the home-indicator inset when up) into a binding. The subtraction happens UIKit-side against
/// `window.safeAreaInsets.bottom` on purpose: SwiftUI's own `safeAreaInsets` swallows the keyboard into
/// its bottom value even while its avoidance does nothing, so subtracting THAT zeroed the lift — the
/// final trap in this hunt. UIKit's window insets never include the keyboard.
struct KeyboardGuideReader: UIViewRepresentable {
    @Binding var overlap: CGFloat

    func makeUIView(context: Context) -> AnchorView {
        AnchorView { lift in
            Task { @MainActor in
                if abs(overlap - lift) > 0.5 { overlap = lift }
            }
        }
    }

    func updateUIView(_ view: AnchorView, context: Context) {}

    /// Invisible view whose only job is to reach the window and install the tracker.
    final class AnchorView: UIView {
        private let onHeight: (CGFloat) -> Void
        private var tracker: TrackerView?

        init(onHeight: @escaping (CGFloat) -> Void) {
            self.onHeight = onHeight
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tracker?.removeFromSuperview()
            tracker = nil
            guard let window else { return }
            let t = TrackerView(onHeight: onHeight)
            t.isUserInteractionEnabled = false
            t.isHidden = true
            t.translatesAutoresizingMaskIntoConstraints = false
            // The tracker hangs between THIS view's keyboardLayoutGuide (the FlowDown anchor — the
            // view-level guide is the one UIKit actually drives; a bare window-level guide sat inert)
            // and the window bottom, so its laid-out height IS the keyboard overlap in screen terms.
            addSubview(t)
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                t.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                t.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                t.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            ])
            tracker = t
        }
    }

    /// Pinned guide-top → window-bottom; its laid-out height is the keyboard overlap.
    final class TrackerView: UIView {
        private let onHeight: (CGFloat) -> Void
        init(onHeight: @escaping (CGFloat) -> Void) {
            self.onHeight = onHeight
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            // Height spans keyboard-guide top → window bottom: the bottom safe inset at rest, the
            // keyboard height when up. Subtract the UIKit inset (keyboard-free by definition) so the
            // reported value is the net lift the composer needs.
            let restingInset = window?.safeAreaInsets.bottom ?? 0
            onHeight(max(0, bounds.height - restingInset))
        }
    }
}
#endif
