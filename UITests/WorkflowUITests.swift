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
        field.typeText("/workflow research how sleep affects memory")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()

        // The DEBUG app seeds its online service from the build-time embedded openai-config.json
        // (scripts/embed-openai-app-config.sh), so no runner-side key injection is needed.
        let row = app.descendants(matching: .any)["workflow.row"]
        if !row.waitForExistence(timeout: 20) {
            XCTFail("the message-anchored workflow record must appear below the initiating message")
        }
        let value = row.value as? String ?? ""
        XCTAssertTrue(
            value.contains("Running") || value.contains("Completed"),
            "the workflow row should be Running or Completed, got '\(value)'"
        )
        // Drive the orchestrator to a terminal state through the real online model. This is the
        // end-to-end assertion: the child run completes (or genuinely fails) and the message row
        // reflects it.
        let deadline = Date().addingTimeInterval(120)
        var terminal = row.value as? String ?? ""
        while Date() < deadline,
              !terminal.contains("Completed"),
              !terminal.contains("Failed"),
              !terminal.contains("Cancelled")
        {
            Thread.sleep(forTimeInterval: 2)
            terminal = row.value as? String ?? terminal
        }
        XCTAssertTrue(
            terminal.contains("Completed"),
            "the workflow should complete through the online model, got '\(terminal)'"
        )
    }

}
