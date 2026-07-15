// SPDX-License-Identifier: MIT

import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// "On-device intelligence" design tokens: layered flat surfaces, a single teal accent, hairline
/// borders. Adaptive to system light/dark (no asset catalog — colors resolve per scheme at draw
/// time). mobileLLM's studio design system; the accent is its own teal ramp.
public enum Theme {

    // MARK: Dynamic-color shim

    /// Solid dynamic color. `hex` resolves per scheme (`0xRRGGBB`).
    public static func dynamic(dark: UInt32, light: UInt32) -> Color {
        #if os(iOS)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #elseif os(macOS)
        Color(NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        Color(red: Double((dark >> 16) & 0xFF) / 255, green: Double((dark >> 8) & 0xFF) / 255, blue: Double(dark & 0xFF) / 255)
        #endif
    }

    /// Dynamic color with per-scheme opacity (e.g. `accentSoft`).
    public static func dynamic(dark: UInt32, darkA: Double, light: UInt32, lightA: Double) -> Color {
        #if os(iOS)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkA) : UIColor(hex: light, alpha: lightA) })
        #elseif os(macOS)
        Color(NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark, alpha: darkA) : NSColor(hex: light, alpha: lightA)
        })
        #else
        Color(red: Double((dark >> 16) & 0xFF) / 255, green: Double((dark >> 8) & 0xFF) / 255, blue: Double(dark & 0xFF) / 255).opacity(darkA)
        #endif
    }

    /// Overload for white/black-based opacity tokens (hairline dark uses pure white).
    public static func dynamic(dark: Color, darkA: Double, light: UInt32, lightA: Double) -> Color {
        #if os(iOS)
        let darkUI = UIColor(dark)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? darkUI.withAlphaComponent(darkA) : UIColor(hex: light, alpha: lightA) })
        #elseif os(macOS)
        let darkNS = NSColor(dark)
        return Color(NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkNS.withAlphaComponent(darkA) : NSColor(hex: light, alpha: lightA)
        })
        #else
        return dark.opacity(darkA)
        #endif
    }

    // MARK: Color tokens (light + dark)

    /// App background.
    public static let bg          = dynamic(dark: 0x0E0E10, light: 0xF6F6F8)
    /// Card / panel / modelBar / selected segment tile.
    public static let surface     = dynamic(dark: 0x1A1A1D, light: 0xFFFFFF)
    /// Inset fields, segmented track, chip fill.
    public static let surface2    = dynamic(dark: 0x222227, light: 0xECECF0)
    /// All 1px borders.
    public static let hairline    = dynamic(dark: .white, darkA: 0.08, light: 0x11111A, lightA: 0.10)

    /// Titles, prompt text, values.
    public static let textPrimary   = dynamic(dark: 0xF2F2F5, light: 0x16161A)
    /// Body, captions, labels, keys.
    public static let textSecondary = dynamic(dark: 0xA8A8B2, light: 0x5A5A66)
    /// Section headers, chevrons, hints.
    public static let textTertiary  = dynamic(dark: 0x6E6E78, light: 0x9A9AA6)

    /// Teal "on-device intelligence" accent (mobileLLM's own identity).
    public static let accent     = dynamic(dark: 0x2DD4BF, light: 0x0D9488)
    /// Filled-chip / glow wash — low-opacity accent.
    public static let accentSoft = dynamic(dark: 0x2DD4BF, darkA: 0.15, light: 0x0D9488, lightA: 0.15)
    /// Text / icon on a filled accent surface.
    public static let onAccent   = Color.white

    /// Fit badge — comfortable / runs resident.
    public static let fitGreen = dynamic(dark: 0x3DD68C, light: 0x1FA968)
    /// Fit badge — tight / experimental.
    public static let fitAmber = dynamic(dark: 0xF0A33D, light: 0xC9791A)
    /// Fit badge — needs more memory / unsupported.
    public static let fitGray  = dynamic(dark: 0x6E6E78, light: 0x9A9AA6)

    /// Failed-state text.
    public static let danger = dynamic(dark: 0xFF5C5C, light: 0xD92D2D)

    // MARK: Scale tokens

    public enum Radius {
        public static let card: CGFloat = 16     // studioCard, model cards, tables (== Theme.corner)
        public static let canvas: CGFloat = 20   // hero surfaces
        public static let field: CGFloat = 12    // text fields, thumbnails
        public static let control: CGFloat = 10  // segmented control, StudioButton
    }

    public enum Space {
        public static let xs: CGFloat = 6
        public static let sm: CGFloat = 10
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 28
    }

    /// KEPT for source compat (studioCard, card overlay strokes). Equals `Radius.card`.
    public static let corner: CGFloat = 16
}

// MARK: - Hex helpers

#if os(iOS)
private extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:  CGFloat(hex & 0xFF) / 255,
                  alpha: CGFloat(alpha))
    }
}
#elseif os(macOS)
private extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green:   CGFloat((hex >> 8) & 0xFF) / 255,
                  blue:    CGFloat(hex & 0xFF) / 255,
                  alpha:   CGFloat(alpha))
    }
}
#endif

// MARK: - Card modifier

extension View {
    /// A surface card with hairline border.
    public func studioCard(_ padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Motion

/// Animation tokens. All `withAnimation` in the app routes through these so Reduce Motion
/// collapses every spring to a short ease.
public enum Motion {
    /// System Reduce-Motion flag (for animation selection).
    @MainActor public static var reduce: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #elseif os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
    }
    @MainActor public static var spring: Animation { reduce ? .easeInOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.82) }
    @MainActor public static var select: Animation { reduce ? .easeInOut(duration: 0.10) : .spring(response: 0.28, dampingFraction: 0.85) }
    @MainActor public static var canvas: Animation { reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.40, dampingFraction: 0.90) }
    public static var press: Animation { .easeOut(duration: 0.12) }
}

// MARK: - Chip

/// A small pill (tag, quant chip).
public struct Chip: View {
    let text: String
    var filled = false
    public init(text: String, filled: Bool = false) {
        self.text = text; self.filled = filled
    }
    public var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1).fixedSize()   // a chip is a tag — keep it one line at its intrinsic width
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(filled ? Theme.accentSoft : Theme.surface2, in: Capsule())
            .foregroundStyle(filled ? Theme.accent : Theme.textSecondary)
    }
}

// MARK: - DotLabelStyle

/// Renders the label icon as a small colored dot before the text. Used by fit badges and any
/// dot-prefixed status label (the model's own `LLMFitBadge` is built on this in the app layer).
public struct DotLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            // Keep the badge to one line at its intrinsic width so it never wraps or steals width from a
            // sibling title in a tight row (the model name beside it shrinks instead).
            configuration.title.lineLimit(1).fixedSize()
        }
    }
}

// MARK: - Segmented control

/// A studio-styled segmented control (replaces system `Picker` menus). The selected option is a
/// raised surface tile that slides between segments via `matchedGeometryEffect`.
public struct Segmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    @Namespace private var ns

    public init(selection: Binding<T>, options: [T], label: @escaping (T) -> String) {
        self._selection = selection
        self.options = options
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { opt in
                let isSelected = opt == selection
                Text(label(opt))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                                .fill(Theme.surface)
                                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Motion.spring) { selection = opt } }
            }
        }
        .padding(3)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

// MARK: - StudioButtonStyle

/// Rectangular studio buttons.
public struct StudioButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary }
    let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(kind == .primary ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                ZStack {
                    shape.fill(kind == .primary ? Theme.accent : Theme.surface)
                    if kind == .secondary { shape.strokeBorder(Theme.hairline) }
                }
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Toast banner

extension View {
    /// Bottom confirmation toast (e.g. "Copied", "Deleted"), shared by every screen so the user sees
    /// feedback on whichever surface they're on.
    public func toastBanner(_ toast: String?) -> some View {
        overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.md)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.bottom, Theme.Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.canvas, value: toast)
    }
}
