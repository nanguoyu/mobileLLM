// SPDX-License-Identifier: MIT

import Foundation

/// The signature thinking-disclosure phase logic (DESIGN §4), factored into a pure value type so it
/// is unit-testable without a view: while `<think>` streams the disclosure is auto-expanded; when the
/// first answer token arrives it auto-collapses to "Thought for Ns"; a manual tap re-expands (and,
/// once the user has taken control, we stop auto-collapsing).
public struct ThinkingTimeline: Equatable {
    public enum Presentation: Equatable {
        case idle                         // no reasoning yet
        case thinking                     // reasoning streaming, expanded
        case thinkingCollapsed            // reasoning still streaming, manually tucked away
        case collapsed(seconds: Double)   // answer started, reasoning tucked away
        case expanded(seconds: Double)    // user re-opened a finished reasoning block
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
        // A tool loop may emit a little prose, call a tool, then begin a fresh reasoning pass. That
        // prose is not the turn's final answer: once reasoning resumes, return to the LIVE presentation
        // and let the eventual answer freeze the full turn's duration. Deliberately keep the user's
        // expansion choice — collapsing a long tool round must stay collapsed across later passes.
        answerStarted = false
        duration = nil
    }

    /// The first answer delta arrived — freeze and auto-collapse. A live store can supply its accumulated
    /// reasoning-only duration (across multiple tool passes); the clock fallback preserves older callers.
    public mutating func onAnswerStart(at now: Date = Date(), elapsed: Double? = nil) {
        guard !answerStarted else { return }
        answerStarted = true
        if let elapsed {
            duration = max(0, elapsed)
        } else if let startedAt {
            duration = max(0, now.timeIntervalSince(startedAt))
        }
    }

    /// The user tapped the disclosure — toggle expansion and take manual control.
    public mutating func toggle() {
        let wasExpanded = isExpanded
        userControlled = true
        userExpanded = !wasExpanded
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
            // Still reasoning: a manual collapse hides the text but must remain a LIVE "Thinking…"
            // state. Calling it "Thought for 0.0s" falsely says thinking has finished, and `duration`
            // intentionally remains nil until the first answer token arrives.
            return (userControlled && !userExpanded) ? .thinkingCollapsed : .thinking
        }
        // Answer has started: collapsed by default, expanded only if the user re-opened it.
        return (userControlled && userExpanded) ? .expanded(seconds: seconds) : .collapsed(seconds: seconds)
    }

    public var isExpanded: Bool {
        switch presentation {
        case .thinking, .expanded: return true
        case .idle, .thinkingCollapsed, .collapsed: return false
        }
    }

    /// The disclosure header label ("Thinking…" / "Thought for 4.2s").
    public var label: String {
        switch presentation {
        case .idle: return "Reasoning"
        case .thinking, .thinkingCollapsed: return "Thinking…"
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
