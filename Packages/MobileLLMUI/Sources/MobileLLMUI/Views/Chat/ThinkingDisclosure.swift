// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppUI

/// The signature thinking disclosure (DESIGN §4): auto-expanded while `<think>` streams; auto-collapses
/// to "Thought for Ns" when the first answer token arrives; tap to re-read. Honors the Settings
/// display mode (auto-collapse / always-expand / hidden) and Reduce Motion.
struct ThinkingDisclosure: View {
    /// The live/streaming reasoning phase, or a completed turn's frozen duration.
    enum Phase: Equatable {
        case thinking                       // reasoning actively streaming
        case answered(seconds: Double?)     // answer has begun (live) / a finished message (nil = unknown)
    }

    let reasoning: String
    let phase: Phase
    let displayMode: ThinkingDisplayMode

    @State private var timeline = ThinkingTimeline()

    var body: some View {
        if displayMode == .hidden || reasoning.isEmpty {
            EmptyView()
        } else {
            content
                .onAppear { advance() }
                .onChange(of: reasoning) { _, _ in advance() }
                .onChange(of: phase) { _, _ in advance() }
        }
    }

    private var isExpanded: Bool {
        displayMode == .alwaysExpand ? true : timeline.isExpanded
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            header
            if isExpanded {
                Text(reasoning)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.Space.md)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accentSoft).frame(width: 2)
                    }
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.surface2.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .animation(Motion.spring, value: isExpanded)
    }

    private var header: some View {
        Button {
            withAnimation(Motion.spring) { timeline.toggle() }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, isActive: phase == .thinking)
                Text(timeline.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                if displayMode != .alwaysExpand {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(displayMode == .alwaysExpand)
        .accessibilityLabel(timeline.label)
        .accessibilityHint(isExpanded ? "Collapse reasoning" : "Expand reasoning")
    }

    /// Drive the tested `ThinkingTimeline` from the current inputs.
    private func advance() {
        guard !reasoning.isEmpty else { return }
        switch phase {
        case .thinking:
            timeline.onReasoning()
        case let .answered(seconds):
            if timeline.hasReasoning {
                timeline.onAnswerStart()          // live thinking → answer: animate the collapse
            } else {
                // A completed message opened directly (never observed the streaming thinking phase).
                timeline.onReasoning()
                if let seconds { timeline.restoreCompleted(seconds: seconds) }
                else { timeline.onAnswerStart() }
            }
        }
    }

    private var reduceMotion: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #elseif os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
    }
}

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if DEBUG
#Preview("Thinking — collapsed") {
    ThinkingDisclosure(reasoning: "The user wants a haiku. I should count syllables: 5-7-5.",
                       phase: .answered(seconds: 4.2), displayMode: .autoCollapse)
    .padding()
    .background(Theme.bg)
}
#endif
