// SPDX-License-Identifier: MIT

import XCTest

// TEST-ID: AHT-LAUNCH-001
/// Deterministic, model-free simulator coverage that is safe for every pull request. It proves the
/// neutral launch contract and top-level interaction wiring without requiring downloaded weights or
/// an online-model secret; richer online and physical-model matrices remain separate release gates.
final class SimulatorCISmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNeutralLaunchAndPrimaryNavigationAreInteractive() throws {
        let app = XCUIApplication()
        app.launch()

        let chat = app.tabBars.buttons["Chat"]
        let models = app.tabBars.buttons["Models"]
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(chat.waitForExistence(timeout: 30))
        XCTAssertTrue(models.exists)
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(app.navigationBars["Chat"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "composer.field").firstMatch.exists,
                       "cold launch must not reopen a conversation or load a model")

        models.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        chat.tap()
        XCTAssertTrue(app.navigationBars["Chat"].waitForExistence(timeout: 10))
    }

    // TEST-ID: AHT-UI-002
    @MainActor
    func testApprovalIsCompleteAtMaximumDynamicTypeAndAcceptsOneDecision() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MOBILELLM_APPROVAL_ACCESSIBILITY_FIXTURE"] = "1"
        app.launch()

        let action = app.descendants(matching: .any)["approval.preview"]
        let destination = app.descendants(matching: .any)["approval.destination"]
        let data = app.descendants(matching: .any)["approval.data"]
        let effects = app.descendants(matching: .any)["approval.effects"]
        let warning = app.descendants(matching: .any)["approval.warning"]
        let scope = app.descendants(matching: .any)["approval.scope"]
        XCTAssertTrue(destination.waitForExistence(timeout: 30))
        XCTAssertEqual(
            action.value as? String,
            "Create an event titled Quarterly planning tomorrow at 09:30 and invite the selected attendees without changing any other event."
        )
        XCTAssertEqual(
            destination.value as? String,
            "calendar://Personal/Events/Quarterly planning with the complete invited-attendee list"
        )
        XCTAssertEqual(data.value as? String, "calendar title, start time, attendee addresses")
        XCTAssertEqual(effects.value as? String, "creates one calendar event, sends invitations")
        XCTAssertTrue(warning.exists)
        XCTAssertEqual(warning.label, "This may change data outside mobileLLM.")
        XCTAssertTrue(scope.exists)
        XCTAssertEqual(scope.label, "Authorizes only this exact prepared operation.")

        let deny = app.buttons["approval.deny"]
        let approve = app.buttons["approval.approve"]
        XCTAssertTrue(deny.exists)
        XCTAssertTrue(approve.exists)
        XCTAssertEqual(deny.label, "Deny Calendar writer")
        XCTAssertEqual(approve.label, "Approve Calendar writer")
        let horizontalOrder = abs(deny.frame.midY - approve.frame.midY) < 1
            && deny.frame.maxX <= approve.frame.minX
        let verticalOrder = deny.frame.maxY <= approve.frame.minY
        XCTAssertTrue(horizontalOrder || verticalOrder, "Deny must precede Approve without overlap")

        let count = app.descendants(matching: .any)["approval.fixture.decision-count"]
        XCTAssertEqual(count.value as? String, "0")
        approve.tap()
        approve.tap()
        let oneDecision = NSPredicate(format: "value == '1'")
        expectation(for: oneDecision, evaluatedWith: count)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(approve.isEnabled, "the projected approval stays latched while its command is pending")
    }
}
