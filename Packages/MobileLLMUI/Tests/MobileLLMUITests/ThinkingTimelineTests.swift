// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
