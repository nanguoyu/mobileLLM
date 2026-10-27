// SPDX-License-Identifier: MIT
import XCTest

// TEST-ID: AHT-SANDBOX-001
final class OpenSandboxUITests: XCTestCase {
    @MainActor func testRealConnectionCanReconnectDisableAndForgetWithoutLeakingTheKey() throws {
        guard let path = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_SANDBOX_CONFIG"] else {
            throw XCTSkip("A real local OpenSandbox configuration is required")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MOBILELLM_DEVICE_E2E"] = "1"
        let namespace = UUID().uuidString
        app.launchEnvironment["MOBILELLM_E2E_STORAGE_NAMESPACE"] = namespace
        print("[OpenSandboxUI] isolated namespace: " + namespace)
        app.launchEnvironment["MOBILELLM_SANDBOX_CONFIG_PATH"] = path
        app.launch()
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20)); settings.tap()
        let tools = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose tools")).firstMatch
        for _ in 0..<8 where !tools.isHittable { app.swipeUp() }
        XCTAssertTrue(tools.isHittable); tools.tap()
        let execution = app.buttons["settings.execution.environment"]
        for _ in 0..<10 where !execution.isHittable { app.swipeUp() }
        XCTAssertTrue(execution.isHittable); execution.tap()
        XCTAssertTrue(app.staticTexts["execution.connected"].waitForExistence(timeout: 30))
        let key = app.secureTextFields["execution.api-key"]
        XCTAssertTrue(key.exists)
        XCTAssertTrue((key.value as? String ?? "").isEmpty || (key.value as? String ?? "").contains("API key"))
        app.buttons["execution.connect"].tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND label == %@", "Check and connect"),
            object: app.buttons["execution.connect"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertTrue(app.staticTexts["execution.connected"].exists)
        let enabled = app.switches["execution.enabled"]
        XCTAssertEqual(enabled.value as? String, "1")
        // SwiftUI exposes the entire form row as Switch; only its trailing control is hit-testable.
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: enabled)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let reenabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: enabled)
        XCTAssertEqual(XCTWaiter.wait(for: [reenabled], timeout: 5), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Real OpenSandbox settings"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["execution.remove"].tap()
        XCTAssertFalse(app.staticTexts["execution.connected"].exists)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "MOBILELLM_SANDBOX_CONFIG_PATH")
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 20))
        app.terminate()
    }
}
