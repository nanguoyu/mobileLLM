// SPDX-License-Identifier: MIT

import Foundation

/// The signature thinking-disclosure phase logic (DESIGN §4), factored into a pure value type so it
/// is unit-testable without a view: while `<think>` streams the disclosure is auto-expanded; when the
/// first answer token arrives it auto-collapses to "Thought for Ns"; a manual tap re-expands (and,
/// once the user has taken control, we stop auto-collapsing).
public struct ThinkingTimeline: Equatable {
    public enum Presentation: Equatable {
        case idle                        // no reasoning yet
        case thinking                    // reasoning streaming, expanded
        case collapsed(seconds: Double)  // answer started, reasoning tucked away
        case expanded(seconds: Double)   // user re-opened a finished reasoning block
    }

    private var startedAt: Date?
    private var duration: Double?
    private var answerStarted = false
    /// True once the user has manually toggled — suppresses the automatic collapse-on-answer.
    private var userControlled = false
    private var userExpanded = false

    public init() {}

    /// A reasoning delta arrived at `now`.
    public mutating func onReasoning(at now: Date = Date()) {
        if startedAt == nil { startedAt = now }
    }

    /// The first answer delta arrived at `now` — freeze the duration and auto-collapse.
    public mutating func onAnswerStart(at now: Date = Date()) {
        guard !answerStarted else { return }
        answerStarted = true
        if let startedAt { duration = max(0, now.timeIntervalSince(startedAt)) }
    }

    /// The user tapped the disclosure — toggle expansion and take manual control.
    public mutating func toggle() {
        userControlled = true
        userExpanded.toggle()
    }

    /// Restore a completed turn (persisted reasoning) into a collapsed, tappable state.
    public mutating func restoreCompleted(seconds: Double) {
        startedAt = Date()
        duration = seconds
        answerStarted = true
    }

    public var hasReasoning: Bool { startedAt != nil }

    public var presentation: Presentation {
        guard startedAt != nil else { return .idle }
        let seconds = duration ?? 0
        if !answerStarted {
            // Still reasoning: expanded unless the user explicitly collapsed it.
            return (userControlled && !userExpanded) ? .collapsed(seconds: seconds) : .thinking
        }
        // Answer has started: collapsed by default, expanded only if the user re-opened it.
        return (userControlled && userExpanded) ? .expanded(seconds: seconds) : .collapsed(seconds: seconds)
    }

    public var isExpanded: Bool {
        switch presentation {
        case .thinking, .expanded: return true
        case .idle, .collapsed: return false
        }
    }

    /// The disclosure header label ("Thinking…" / "Thought for 4.2s").
    public var label: String {
        switch presentation {
        case .idle: return "Reasoning"
        case .thinking: return "Thinking…"
        case let .collapsed(seconds), let .expanded(seconds):
            return "Thought for \(Self.format(seconds))"
        }
    }

    static func format(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.1fs", max(0, seconds)) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}
