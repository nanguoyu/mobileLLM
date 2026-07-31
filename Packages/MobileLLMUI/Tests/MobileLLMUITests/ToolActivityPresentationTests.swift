// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

final class ToolActivityPresentationTests: XCTestCase {

    func testCompletedMemoryHidesCanonicalAndLegacyPayloads() {
        let run = ToolRun(
            name: "remember",
            arguments: #"{"text":"The user is named Dong."}"#,
            result: "Saved: 用户叫Dong"
        )
        let presentation = ToolActivityPresentation(run: run)

        XCTAssertEqual(presentation.state, .succeeded)
        XCTAssertEqual(presentation.title, "Saved to memory")
        XCTAssertNil(presentation.detail)
        XCTAssertEqual(presentation.accessibilityLabel, "Saved to memory")
        XCTAssertFalse(String(describing: presentation).contains("Dong"))
        XCTAssertFalse(String(describing: presentation).contains("用户"))
    }

    func testMemoryRunningAndFailureUseStatusOnly() {
        let running = ToolActivityPresentation(
            run: ToolRun(name: "remember", arguments: #"{"text":"The user likes tea."}"#)
        )
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.title, "Saving to memory…")
        XCTAssertNil(running.detail)

        let failed = ToolActivityPresentation(
            run: ToolRun(name: "remember", arguments: #"{"text":""}"#,
                         result: "Error: missing 'text' to remember.")
        )
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.title, "Couldn't save to memory")
        XCTAssertNil(failed.detail)
        XCTAssertFalse(failed.accessibilityLabel.contains("missing"))
    }

    func testDuplicateMemoryIsNotPresentedAsNewlySaved() {
        let presentation = ToolActivityPresentation(
            run: ToolRun(name: "remember", arguments: #"{"text":"The user likes tea."}"#,
                         result: "Already in memory.")
        )

        XCTAssertEqual(presentation.state, .succeeded)
        XCTAssertEqual(presentation.title, "Already in memory")
        XCTAssertNil(presentation.detail)
        XCTAssertEqual(presentation.accessibilityLabel, "Already in memory")
    }

    func testOtherToolsKeepTheirArgumentsAndResult() {
        let presentation = ToolActivityPresentation(
            run: ToolRun(name: "calculator", arguments: #"{"expression":"17+25"}"#, result: "42")
        )
        XCTAssertEqual(presentation.state, .succeeded)
        XCTAssertEqual(presentation.title, "Calculator(17+25)")
        XCTAssertEqual(presentation.detail, "→ 42")
        XCTAssertEqual(presentation.accessibilityLabel, "Calculator returned 42")
    }

    func testBuiltInErrorResultIsPresentedAsFailure() {
        let presentation = ToolActivityPresentation(
            run: ToolRun(name: "calculator", arguments: #"{"expression":"nope"}"#,
                         result: "  Error: unsupported characters in expression.")
        )
        XCTAssertEqual(presentation.state, .failed)
        XCTAssertEqual(presentation.title, "Calculator(nope) failed")
        XCTAssertEqual(presentation.detail, "→   Error: unsupported characters in expression.")
        XCTAssertTrue(presentation.accessibilityLabel.hasPrefix("Calculator failed"))
    }

    func testMCPToolLevelAndTransportErrorsArePresentedAsFailures() {
        for result in [
            "Tool error: remote validation failed",
            #"MCP tool "lookup" failed: The request timed out."#,
        ] {
            let presentation = ToolActivityPresentation(
                run: ToolRun(name: "lookup", arguments: "{}", result: result)
            )
            XCTAssertEqual(presentation.state, .failed, "\(result) must not receive a success seal")
            XCTAssertEqual(presentation.title, "Lookup failed")
        }
    }

    func testPermissionAndBuiltInNetworkFailuresArePresentedAsFailures() {
        for (name, result) in [
            ("create_calendar_event", "Calendar access is off — enable it in Settings to add events."),
            ("current_location", "Location is unavailable right now."),
            ("wikipedia", "Search failed — couldn't reach Wikipedia."),
        ] {
            let presentation = ToolActivityPresentation(
                run: ToolRun(name: name, arguments: "{}", result: result)
            )
            XCTAssertEqual(presentation.state, .failed, "\(result) must not receive a success seal")
        }
    }
}
