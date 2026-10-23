// SPDX-License-Identifier: MIT

import XCTest

// TEST-ID: AHT-DYNAMIC-UI-001
/// Simulator E2E for the message-anchored Dynamic Workflow surface (spec §34): `/workflow <goal>`
/// records one exact analyzed JavaScript candidate, converts the explicit slash command into a
/// one-run approval, runs a parallel research/fan-in workflow, and projects a substantive final
/// answer without exposing a redundant launch-permission prompt.
final class WorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWorkflowCommandShowsMessageAnchoredRecord() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MOBILELLM_DYNAMIC_WORKFLOW_RESPONSES_FIXTURE"] = "1"
        app.launch()

        let newChat = app.buttons.matching(identifier: "New chat").firstMatch
        if newChat.waitForExistence(timeout: 8) { newChat.tap() }

        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer never appeared")
        let answerCount = app.descendants(matching: .any)
            .matching(identifier: "assistant.answer").count
        field.tap()
        field.typeText("/workflow deploy Kimi K3 on iPhone 16 Pro")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let composerDeadline = Date().addingTimeInterval(3)
        while Date() < composerDeadline {
            if !((field.value as? String) ?? "").contains("/workflow") { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(
            !((field.value as? String) ?? "").contains("/workflow"),
            "the composer must clear after a /workflow send"
        )

        // The DEBUG app seeds its online service from the build-time config and routes Responses API
        // traffic through an opt-in deterministic transport. This still exercises the production
        // provider parser/runtime path without making UI acceptance depend on a live model.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Workflow: deploy Kimi K3")
        ).firstMatch
        if !row.waitForExistence(timeout: 20) {
            XCTFail("the message-anchored workflow record must appear below the initiating message")
        }
        let value = readValue(row) ?? ""
        XCTAssertTrue(
            value.contains("Generating candidate") || value.contains("Running")
                || value.contains("Completed"),
            "the workflow must begin generating or running, got '\(value)'"
        )

        let candidateDeadline = Date().addingTimeInterval(180)
        var candidateState = readValue(row) ?? ""
        while Date() < candidateDeadline,
              !candidateState.contains("Running"),
              !candidateState.contains("Completed"),
              !candidateState.contains("Failed")
        {
            Thread.sleep(forTimeInterval: 1)
            candidateState = readValue(row) ?? candidateState
        }
        XCTAssertTrue(
            candidateState.contains("Running") || candidateState.contains("Completed"),
            "the explicit /workflow command must auto-start after validation, got '\(candidateState)'"
        )

        let workflowBar = app.navigationBars["Workflow"]
        for _ in 0 ..< 5 where !workflowBar.exists {
            if row.exists, row.isHittable { row.tap() }
            if workflowBar.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(workflowBar.exists, "workflow row did not open its summary page")
        let sourceDisclosure = app.buttons["JavaScript source"]
        XCTAssertTrue(sourceDisclosure.waitForExistence(timeout: 20), "source disclosure is missing")
        sourceDisclosure.tap()
        let source = app.descendants(matching: .any)["workflow.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5), "exact JavaScript source is not inspectable")
        XCTAssertFalse(app.buttons["Once"].exists)
        XCTAssertFalse(app.buttons["Always"].exists)
        XCTAssertFalse(app.buttons["Deny"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["workflow.approval"].exists)

        let sourceText = (source.value as? String) ?? source.label
        XCTAssertTrue(sourceText.contains("parallel("), "complex fixture must exercise parallel fan-out")
        XCTAssertTrue(sourceText.contains("MOBILELLM_ACCEPTANCE_REVIEW_V1"), "the shipped program must include independent acceptance review")
        sourceDisclosure.tap()

        let state = app.descendants(matching: .any)["workflow.state"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, state.label != "Completed", state.label != "Failed" {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(state.label, "Completed", "complex workflow did not complete")

        let callsDisclosure = app.buttons["Agent calls"]
        XCTAssertTrue(callsDisclosure.waitForExistence(timeout: 10), "agent-call evidence is missing")
        XCTAssertTrue(
            ((callsDisclosure.value as? String) ?? "").hasPrefix("6 calls"),
            "three workers, coordinator, draft and acceptance review must be durably projected"
        )
        callsDisclosure.tap()

        workflowBar.buttons.firstMatch.tap()
        let answers = app.descendants(matching: .any).matching(identifier: "assistant.answer")
        let answerDeadline = Date().addingTimeInterval(20)
        while Date() < answerDeadline, answers.count <= answerCount {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertGreaterThan(answers.count, answerCount, "workflow result was not projected into chat")
        let answer = answers.allElementsBoundByIndex.last
        let answerText = answer.flatMap { ($0.value as? String) ?? $0.label } ?? ""
        XCTAssertTrue(answerText.contains("EVAL_KIMI_LOCAL"), "final answer lost the user's acceptance token")
        XCTAssertTrue(answerText.localizedCaseInsensitiveContains("not feasible"))
        XCTAssertTrue(answerText.localizedCaseInsensitiveContains("iPhone 16 Pro"))
        XCTAssertTrue(answerText.localizedCaseInsensitiveContains("smaller"))
        XCTAssertTrue(answerText.localizedCaseInsensitiveContains("remote"))
    }

    /// Reading `.value` immediately after `waitForExistence` can race a list re-render; retry a few
    /// snapshots before giving up.
    @MainActor
    private func readValue(_ element: XCUIElement) -> String? {
        for _ in 0 ..< 10 {
            if element.exists, let value = element.value as? String {
                return value
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

}
