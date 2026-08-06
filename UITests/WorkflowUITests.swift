// SPDX-License-Identifier: MIT

import XCTest

// TEST-ID: AHT-WORKFLOW-001
/// Simulator E2E for the message-anchored workflow surface (spec §20/§22): `/workflow <goal>`
/// creates the running record below the initiating message immediately, then the orchestrator
/// drives the child run (online model injected from ~/.mobilellm/openai.json by the runner).
final class WorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWorkflowCommandShowsMessageAnchoredRecord() throws {
        let app = XCUIApplication()
        app.launch()

        let newChat = app.buttons.matching(identifier: "New chat").firstMatch
        if newChat.waitForExistence(timeout: 8) { newChat.tap() }

        let field = app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer never appeared")
        field.tap()
        field.typeText("/workflow deploy Kimi K3 on iPhone 16 Pro")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()

        // The DEBUG app seeds its online service from the build-time embedded openai-config.json
        // (scripts/embed-openai-app-config.sh), so no runner-side key injection is needed.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Workflow: deploy Kimi K3")
        ).firstMatch
        if !row.waitForExistence(timeout: 20) {
            XCTFail("the message-anchored workflow record must appear below the initiating message")
        }
        let value = readValue(row) ?? ""
        XCTAssertTrue(
            value.contains("Running") || value.contains("Completed"),
            "the workflow row should be Running or Completed, got '\(value)'"
        )
        XCTAssertTrue(
            value.contains("/") && value.contains("subagents"),
            "workflow subagent totals must be x/y from the start, got '\(value)'"
        )
        // The real planner + real children take many minutes on the online API; this routine E2E
        // asserts the multi-phase engine is genuinely progressing with live statistics, not full
        // completion (the full audit→revise→verify→deliver run is the device scenario test31).
        let deadline = Date().addingTimeInterval(480)
        var terminal = readValue(row) ?? ""
        var reachedPhaseThree = false
        var sawLiveStats = false
        while Date() < deadline,
              !terminal.contains("Completed"),
              !terminal.contains("Failed"),
              !terminal.contains("Cancelled")
        {
            if terminal.contains("phase 3/") || terminal.contains("phase 4/")
                || terminal.contains("phase 5/") || terminal.contains("phase 6/")
            {
                reachedPhaseThree = true
            }
            if terminal.contains("tokens") && !terminal.contains("0 tokens")
                && terminal.contains("tool calls")
            {
                sawLiveStats = true
            }
            if reachedPhaseThree, sawLiveStats { break }
            Thread.sleep(forTimeInterval: 2)
            terminal = readValue(row) ?? terminal
        }
        if terminal.contains("Completed") {
            reachedPhaseThree = true
            sawLiveStats = terminal.contains("tokens") && !terminal.contains("0 tokens")
                && terminal.contains("tool calls")
        }
        XCTAssertTrue(
            reachedPhaseThree,
            "the workflow must reach at least phase 3 of its auto-generated plan, got '\(terminal)'"
        )
        XCTAssertTrue(
            sawLiveStats,
            "live token/tool-call statistics must appear, got '\(terminal)'"
        )
        XCTAssertTrue(
            !terminal.contains("Failed") && !terminal.contains("Cancelled"),
            "the workflow must not fail during the progression window, got '\(terminal)'"
        )
    }

    /// Reading `.value` immediately after `waitForExistence` can race a list re-render; retry a few
    /// times before giving up.
    private func readValue(_ element: XCUIElement) -> String? {
        for _ in 0 ..< 10 {
            do {
                if element.exists, let value = element.value as? String {
                    return value
                }
            } catch {
                // Transient snapshot failure while the app's main thread is busy; retry.
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

}
