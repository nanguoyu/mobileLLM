// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// The signature thinking-disclosure phase logic (DESIGN §4): expanded while reasoning streams,
/// auto-collapsed to "Thought for Ns" on the first answer token, tap to re-expand.
final class ThinkingTimelineTests: XCTestCase {

    func testIdleBeforeAnyReasoning() {
        let timeline = ThinkingTimeline()
        XCTAssertEqual(timeline.presentation, .idle)
        XCTAssertFalse(timeline.isExpanded)
        XCTAssertFalse(timeline.hasReasoning)
    }

    func testExpandedWhileReasoningStreams() {
        var timeline = ThinkingTimeline()
        timeline.onReasoning(at: Date())
        XCTAssertEqual(timeline.presentation, .thinking)
        XCTAssertTrue(timeline.isExpanded)
        XCTAssertEqual(timeline.label, "Thinking…")
    }

    func testManualCollapseWhileReasoningStaysLiveUntilAnswerStarts() {
        let start = Date()
        var timeline = ThinkingTimeline()
        timeline.onReasoning(at: start)

        timeline.toggle()
        XCTAssertEqual(timeline.presentation, .thinkingCollapsed)
        XCTAssertFalse(timeline.isExpanded)
        XCTAssertEqual(timeline.label, "Thinking…",
                       "collapsing live reasoning must not claim it already thought for 0.0s")

        timeline.onReasoning(at: start.addingTimeInterval(2))
        XCTAssertEqual(timeline.presentation, .thinkingCollapsed,
                       "later reasoning deltas must preserve the user's collapsed state")

        timeline.onAnswerStart(at: start.addingTimeInterval(4.2))
        guard case let .collapsed(seconds) = timeline.presentation else {
            return XCTFail("the live label should become a completed duration only when the answer starts")
        }
        XCTAssertEqual(seconds, 4.2, accuracy: 0.01)
        XCTAssertEqual(timeline.label, "Thought for 4.2s")
    }

    func testTapDuringReasoningCollapsesThenReopensOnTheNextTap() {
        var timeline = ThinkingTimeline()
        timeline.onReasoning()
        timeline.toggle()
        XCTAssertFalse(timeline.isExpanded)
        timeline.toggle()
        XCTAssertTrue(timeline.isExpanded)
        XCTAssertEqual(timeline.presentation, .thinking)
    }

    func testReasoningAfterPreToolProseReturnsToLiveAndRefreezesTotalDuration() {
        let start = Date()
        var timeline = ThinkingTimeline()
        timeline.onReasoning(at: start)
        timeline.onAnswerStart(at: start.addingTimeInterval(2))
        XCTAssertEqual(timeline.presentation, .collapsed(seconds: 2))

        // The apparent answer was only prose before a tool call. A later model pass starts reasoning
        // again, so the disclosure is live rather than stuck at "Thought for 2.0s".
        timeline.onReasoning(at: start.addingTimeInterval(4))
        XCTAssertEqual(timeline.presentation, .thinking)
        XCTAssertEqual(timeline.label, "Thinking…")

        timeline.onAnswerStart(at: start.addingTimeInterval(9))
        XCTAssertEqual(timeline.presentation, .collapsed(seconds: 9),
                       "the final answer freezes the full multi-pass duration from the first reasoning")
    }

    func testExplicitAccumulatedDurationExcludesTimeBetweenToolPasses() {
        let start = Date()
        var timeline = ThinkingTimeline()
        timeline.onReasoning(at: start)
        timeline.onAnswerStart(at: start.addingTimeInterval(2), elapsed: 0.4)
        XCTAssertEqual(timeline.presentation, .collapsed(seconds: 0.4))

        // Ten seconds later another pass reasons. The store reports 0.9s of actual accumulated reasoning,
        // so the disclosure must not substitute the 20s wall-clock span.
        timeline.onReasoning(at: start.addingTimeInterval(10))
        XCTAssertEqual(timeline.presentation, .thinking)
        timeline.onAnswerStart(at: start.addingTimeInterval(20), elapsed: 0.9)
        XCTAssertEqual(timeline.presentation, .collapsed(seconds: 0.9))
        XCTAssertEqual(timeline.label, "Thought for 0.9s")
    }

    func testManualCollapseSurvivesASecondReasoningPassAfterToolProse() {
        let start = Date()
        var timeline = ThinkingTimeline()
        timeline.onReasoning(at: start)
        timeline.toggle()
        timeline.onAnswerStart(at: start.addingTimeInterval(1))

        timeline.onReasoning(at: start.addingTimeInterval(2))
        XCTAssertEqual(timeline.presentation, .thinkingCollapsed)
        XCTAssertFalse(timeline.isExpanded)
        XCTAssertEqual(timeline.label, "Thinking…")
    }

    func testAutoCollapsesOnFirstAnswerToken() {
        let start = Date()
        var timeline = ThinkingTimeline()
        timeline.onReasoning(at: start)
        timeline.onAnswerStart(at: start.addingTimeInterval(4.2))
        guard case let .collapsed(seconds) = timeline.presentation else {
            return XCTFail("expected collapsed after first answer token, got \(timeline.presentation)")
        }
        XCTAssertEqual(seconds, 4.2, accuracy: 0.01)
        XCTAssertFalse(timeline.isExpanded)
        XCTAssertTrue(timeline.label.hasPrefix("Thought for"))
    }

    func testTapReexpandsCollapsedReasoning() {
        let start = Date()
        var timeline = ThinkingTimeline()
        timeline.onReasoning(at: start)
        timeline.onAnswerStart(at: start.addingTimeInterval(1))
        XCTAssertFalse(timeline.isExpanded)
        timeline.toggle()
        XCTAssertTrue(timeline.isExpanded)
        if case .expanded = timeline.presentation {} else { XCTFail("expected expanded after tap") }
        timeline.toggle()
        XCTAssertFalse(timeline.isExpanded)
    }

    func testOnlyFirstAnswerFreezesDuration() {
        let start = Date()
        var timeline = ThinkingTimeline()
        timeline.onReasoning(at: start)
        timeline.onAnswerStart(at: start.addingTimeInterval(2))
        timeline.onAnswerStart(at: start.addingTimeInterval(9))   // ignored
        if case let .collapsed(seconds) = timeline.presentation {
            XCTAssertEqual(seconds, 2, accuracy: 0.01)
        } else { XCTFail("expected collapsed") }
    }

    func testRestoreCompletedIsCollapsedAndTappable() {
        var timeline = ThinkingTimeline()
        timeline.restoreCompleted(seconds: 3.5)
        XCTAssertFalse(timeline.isExpanded)
        XCTAssertTrue(timeline.hasReasoning)
        timeline.toggle()
        XCTAssertTrue(timeline.isExpanded)
    }
}
