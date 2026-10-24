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
        app.launchEnvironment["MOBILELLM_DEVICE_E2E"] = "1"
        app.launchEnvironment["MOBILELLM_E2E_STORAGE_NAMESPACE"] = UUID().uuidString
        app.launch()

        let newChat = app.buttons.matching(identifier: "New chat").firstMatch
        if newChat.waitForExistence(timeout: 8) { newChat.tap() }

        let field = app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer never appeared")
        let answerCount = app.descendants(matching: .any)
            .matching(identifier: "assistant.answer").count
        let approvalMode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Approval:")).firstMatch
        approvalMode.tap()
        app.buttons["Ask"].tap()
        app.buttons["Chat options"].tap()
        app.buttons["composer.workflow.start"].tap()
        XCTAssertTrue(app.staticTexts["composer.workflow.mode"].waitForExistence(timeout: 5))
        XCTAssertTrue(((field.value as? String) ?? "").contains("/workflow"))
        field.tap()
        field.typeText(" deploy Kimi K3 on iPhone 16 Pro")
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
            value.contains("Planning") || value.contains("Needs approval") || value.contains("Running")
                || value.contains("Completed"),
            "the workflow must begin generating or running, got '\(value)'"
        )

        let workflowBar = app.navigationBars["Workflow"]
        for _ in 0 ..< 5 where !workflowBar.exists {
            if row.exists, row.isHittable { row.tap() }
            else { app.swipeDown() }
            if workflowBar.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(workflowBar.exists, "workflow row did not open its summary page")
        let state = app.descendants(matching: .any)["workflow.state"]
        let deadline = Date().addingTimeInterval(180)
        var reviewedPlanning = false
        var reviewedTasks: Set<String> = []
        while Date() < deadline, state.label != "Completed", state.label != "Failed" {
            let planning = app.buttons["workflow.planning.review"]
            var opened = false
            if !reviewedPlanning, planning.exists, planning.isHittable {
                planning.tap()
                reviewedPlanning = true
                opened = true
            } else {
                let pending = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Needs approval"))
                    .allElementsBoundByIndex.first { !reviewedTasks.contains($0.identifier) }
                if let pending {
                    for _ in 0..<6 where !pending.isHittable { app.swipeUp() }
                    XCTAssertFalse(pending.identifier.isEmpty, "attention tasks need stable identities")
                    reviewedTasks.insert(pending.identifier)
                    pending.tap()
                    opened = true
                }
            }
            if opened {
                let approve = app.buttons["approval.approve"]
                XCTAssertTrue(approve.waitForExistence(timeout: 10), "the exact run's approval control must remain accessible")
                approve.tap()
                app.buttons["Done"].tap()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(reviewedPlanning, "the initial coordinator must not hide its approval")
        XCTAssertFalse(reviewedTasks.isEmpty, "a child approval must be handled in its own inspector")
        XCTAssertEqual(state.label, "Completed", "complex workflow did not complete")
        XCTAssertEqual(app.staticTexts["workflow.task.count"].label, "3 tasks · 3 completed",
                       "coordination calls must not be counted as worker tasks")
        let task = app.buttons["workflow.task.model"]
        for _ in 0..<6 where !task.isHittable { app.swipeUp() }
        XCTAssertTrue(task.exists, "task card must expose a stable accessible action")
        task.tap()
        let taskResult = app.descendants(matching: .any).matching(identifier: "workflow.task.result").firstMatch
        XCTAssertTrue(taskResult.waitForExistence(timeout: 10), "saved worker output must load without regenerating it")
        XCTAssertTrue(taskResult.label.contains("Under the fixture assumptions"))
        app.buttons["Copy result"].tap()
        XCTAssertTrue(app.buttons["Copied"].exists, "copy must acknowledge the action")
        app.buttons["Done"].tap()

        let executionDetails = app.buttons["Execution details"]
        for _ in 0..<8 where !executionDetails.isHittable { app.swipeUp() }
        XCTAssertTrue(executionDetails.exists)
        executionDetails.tap()
        let callsDisclosure = app.buttons["workflow.call.history"]
        for _ in 0..<4 where !callsDisclosure.isHittable { app.swipeUp() }
        XCTAssertEqual(callsDisclosure.value as? String, "4 calls", "all actual invocations remain inspectable")
        callsDisclosure.tap()
        let calls = app.staticTexts.matching(identifier: "workflow.agent.call")
        XCTAssertTrue(calls.firstMatch.waitForExistence(timeout: 5), "opening history must expose individual calls")
        XCTAssertEqual(calls.count, 4)
        callsDisclosure.tap()
        let sourceDisclosure = app.buttons["Workflow source"]
        for _ in 0..<4 where !sourceDisclosure.isHittable { app.swipeUp() }
        XCTAssertTrue(sourceDisclosure.exists, "exact source must remain available under execution details")
        sourceDisclosure.tap()
        let source = app.descendants(matching: .any)["workflow.source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let sourceText = (source.value as? String) ?? source.label
        XCTAssertTrue(sourceText.contains("parallel("))
        XCTAssertTrue(sourceText.contains("MOBILELLM_COORDINATOR_V3"))
        XCTAssertFalse(app.descendants(matching: .any)["workflow.approval"].exists)
        sourceDisclosure.tap()

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
