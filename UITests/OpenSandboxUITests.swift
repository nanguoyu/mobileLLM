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
        app.launchEnvironment["MOBILELLM_E2E_STORAGE_NAMESPACE"] = UUID().uuidString
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
        XCTAssertTrue(app.staticTexts["execution.connected"].waitForExistence(timeout: 30))
        let enabled = app.switches["execution.enabled"]
        XCTAssertEqual(enabled.value as? String, "1")
        enabled.tap()
        XCTAssertEqual(enabled.value as? String, "0")
        enabled.tap()
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
