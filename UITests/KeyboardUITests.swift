// SPDX-License-Identifier: MIT

import XCTest

/// The keyboard/composer geometry, asserted instead of eyeballed. Four "fixes" shipped blind against
/// this exact surface before the ground truth (UIWindow.keyboardLayoutGuide) landed — this test is the
/// reason a fifth never ships blind.
///
/// Prerequisite: a model on disk (any small GGUF), or the composer shows the no-model bar and there is
/// no text field to focus. The runner seeds one into the simulator container, e.g.:
///   simctl get_app_container <sim> <your-bundle-id> data
///   → <container>/Library/Application Support/mobileLLM/models/prism-ml/Bonsai-1.7B-gguf/Bonsai-1.7B-Q1_0.gguf
final class KeyboardUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testComposerRidesTheKeyboard() throws {
        let app = XCUIApplication()
        app.launch()

        // Reach a conversation: the list's New-chat CTA on first run, else the toolbar pencil (both carry
        // the "New chat" label — either works).
        let newChat = app.buttons.matching(identifier: "New chat").firstMatch
        if newChat.waitForExistence(timeout: 5) { newChat.tap() }

        let field = app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the composer field never appeared — did the seeded model fail to activate?")

        // At rest: no keyboard, the field sits in the bottom band of the screen.
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(field.frame.maxY, screen.maxY - 160,
                             "at rest the composer should hug the bottom (got \(field.frame))")

        // Focus → the software keyboard rises → the WHOLE input row must sit above it.
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 6), "tapping the field must raise the keyboard")
        // Let the lift animation settle before measuring.
        Thread.sleep(forTimeInterval: 0.6)

        let fieldFrame = field.frame
        let keyboardTop = keyboard.frame.minY
        XCTAssertLessThanOrEqual(fieldFrame.maxY, keyboardTop + 1,
                                 "input row buried: field bottom \(fieldFrame.maxY) vs keyboard top \(keyboardTop)")
        XCTAssertGreaterThan(fieldFrame.maxY, keyboardTop - 120,
                             "input row should sit right ABOVE the keyboard, not float mid-screen")

        // Tap blank thread space → keyboard drops → the composer settles back to the bottom.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(waitUntilGone(keyboard, timeout: 6), "tapping blank space must dismiss the keyboard")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(field.frame.maxY, screen.maxY - 160,
                             "after dismissal the composer must settle back down (got \(field.frame))")
    }

    /// The UIWindow survives a Home round-trip but UIKit may recreate its keyboard layout guide. This is
    /// the lifecycle edge that left a fully enabled Send button physically behind the keyboard on device.
    @MainActor
    func testComposerRebindsToKeyboardAfterBackgroundForeground() throws {
        let app = XCUIApplication()
        app.launch()

        let newChat = app.buttons.matching(identifier: "New chat").firstMatch
        if newChat.waitForExistence(timeout: 5) { newChat.tap() }
        XCTAssertTrue(app.textFields["composer.field"].waitForExistence(timeout: 20))

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 0.8)
        app.activate()

        let field = app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the active thread should survive foregrounding")
        field.tap()
        field.typeText("foreground keyboard regression")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 1,
                                 "after foregrounding the composer must still ride above the keyboard")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists && send.isEnabled && send.isHittable,
                      "Send must remain physically tappable; enabled-but-covered is still broken")
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !element.exists
    }
}

/// A model-free smoke test intended for a freshly installed app on a physical iPhone. It exercises the
/// navigation and settings controls that must work before a user downloads or loads any model.
final class DeviceSmokeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        throw XCTSkip("Superseded by the DeviceE2E target; retained only for xcresult compatibility")
        addUIInterruptionMonitor(withDescription: "Safely dismiss unrelated system alerts") { alert in
            // Never let XCTest's default handler choose a destructive/default action such as
            // "Edit Settings" or "Continue". Only explicit, reversible dismissal labels are allowed.
            for label in ["Cancel", "Not Now", "Later", "Close"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            XCTFail("Refusing to interact with unrelated system alert: \(alert.label)")
            return true
        }
    }

    @MainActor
    func testColdLaunchNavigationAndIndependentToolSelection() throws {
        let app = XCUIApplication()
        app.launch()

        let chatTab = app.tabBars.buttons["Chat"]
        let modelsTab = app.tabBars.buttons["Models"]
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 30), "Chat tab did not become interactive")
        XCTAssertTrue(modelsTab.exists, "Models tab is missing")
        XCTAssertTrue(settingsTab.exists, "Settings tab is missing")
        XCTAssertTrue(app.navigationBars["Chat"].exists, "cold launch must stay on the Chat list")
        XCTAssertFalse(app.textFields["composer.field"].exists,
                       "cold launch must not enter a conversation automatically")

        modelsTab.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 10),
                      "Models tab did not respond")

        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Settings tab did not respond")

        let master = switchStarting(with: "Allow selected tools", in: app)
        XCTAssertTrue(master.waitForExistence(timeout: 10), "tool master switch is missing")

        let chooseTools = buttonStarting(with: "Choose tools", in: app)
        XCTAssertTrue(chooseTools.waitForExistence(timeout: 10), "Choose tools button is missing")
        XCTAssertTrue(scrollToHittable(chooseTools, in: app.scrollViews.firstMatch),
                      "Choose tools button is not interactive")
        chooseTools.tap()
        XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 10),
                      "Choose tools did not open the Tools sheet")

        let toolsScroll = firstHittableScrollView(in: app)
        let webSearch = switchStarting(with: "Web search", in: toolsScroll)
        let calculator = switchStarting(with: "Calculator", in: toolsScroll)
        XCTAssertTrue(scrollToHittable(webSearch, in: toolsScroll), "Web search switch is not interactive")
        XCTAssertTrue(calculator.waitForExistence(timeout: 5), "Calculator switch is missing")

        let initialWebSearch = switchValue(webSearch)
        let initialCalculator = switchValue(calculator)
        webSearch.tap()
        XCTAssertTrue(waitForSwitch(webSearch, toDifferFrom: initialWebSearch),
                      "Web search switch did not change")
        XCTAssertEqual(switchValue(calculator), initialCalculator,
                       "changing Web search must not change Calculator")

        let sheetMaster = switchStarting(with: "Allow selected tools", in: toolsScroll)
        XCTAssertTrue(scrollToHittable(sheetMaster, in: toolsScroll, swipingUp: false),
                      "tool master switch in the sheet is not interactive")
        let initialMaster = switchValue(sheetMaster)
        sheetMaster.tap()
        XCTAssertTrue(waitForSwitch(sheetMaster, toDifferFrom: initialMaster),
                      "tool master switch did not change")

        XCTAssertTrue(scrollToHittable(webSearch, in: toolsScroll), "Web search switch disappeared")
        XCTAssertNotEqual(switchValue(webSearch), initialWebSearch,
                          "master switch must preserve individual tool selection")
        XCTAssertEqual(switchValue(calculator), initialCalculator,
                       "master switch must preserve Calculator selection")

        // Restore every setting changed by this test before leaving the sheet.
        webSearch.tap()
        XCTAssertTrue(waitForSwitch(webSearch, toEqual: initialWebSearch),
                      "Web search selection could not be restored")
        XCTAssertTrue(scrollToHittable(sheetMaster, in: toolsScroll, swipingUp: false),
                      "tool master switch disappeared")
        if switchValue(sheetMaster) != initialMaster {
            sheetMaster.tap()
            XCTAssertTrue(waitForSwitch(sheetMaster, toEqual: initialMaster),
                          "tool master setting could not be restored")
        }

        app.navigationBars["Tools"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Tools sheet did not close")

        chatTab.tap()
        XCTAssertTrue(app.navigationBars["Chat"].waitForExistence(timeout: 10),
                      "Chat tab did not respond after closing settings")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Chat"].waitForExistence(timeout: 30),
                      "relaunch did not return to the Chat list")
        XCTAssertFalse(app.textFields["composer.field"].exists,
                       "relaunch must not reopen the previous conversation")
    }

    /// A physical-device inference smoke that deliberately keeps the user's current model, Tools, and
    /// Thinking settings. The unique first line becomes the conversation title, which lets cleanup remove
    /// only this test's record after proving that Bonsai produced and committed a non-empty answer.
    @MainActor
    func testBonsaiRealInferenceWithCurrentSettings() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Chat"].waitForExistence(timeout: 30),
                      "cold launch did not reach the Chat list")
        XCTAssertFalse(app.textFields["composer.field"].exists,
                       "cold launch unexpectedly entered a conversation")

        // `newConversation()` intentionally reuses an existing empty thread. Never run a destructive smoke
        // through an ambiguous user-owned draft: this test creates and later removes only its own thread.
        let emptyRows = app.buttons.matching(NSPredicate(format: "value == %@", "No messages yet"))
        if emptyRows.count != 0 {
            throw XCTSkip("device already has an empty conversation; refusing to reuse or delete it")
        }

        let marker = "DEVICE_SMOKE_\(Int(Date().timeIntervalSince1970))"
        var openedSmokeConversation = false
        defer {
            if openedSmokeConversation {
                XCTAssertTrue(cleanUpSmokeConversation(marker,
                                                       removeFallbackEmpty: true,
                                                       in: app),
                              "could not precisely remove the device-smoke conversation")
            }
        }

        let newChat = app.buttons.matching(identifier: "New chat").firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New chat button is missing")
        newChat.tap()
        openedSmokeConversation = true

        let activeModel = app.buttons["Active model"]
        XCTAssertTrue(activeModel.waitForExistence(timeout: 15), "conversation did not open")
        XCTAssertTrue(waitForValue(of: activeModel,
                                   toStartWith: "Bonsai 8B · 1-bit",
                                   timeout: 180),
                      "the current default Bonsai 8B · 1-bit model did not become active")

        let field = app.textFields["composer.field"]
        XCTAssertTrue(waitForComposer(field, in: app, timeout: 180),
                      "the Bonsai composer never became ready")

        let responseMarker = "DEVICE_SMOKE_OK"
        let prompt = marker
            + "\nDo not use any tool. Reply with the words DEVICE, SMOKE, and OK joined by underscores, "
            + "and nothing else."
        field.tap()
        field.typeText(prompt)

        let send = app.buttons["Send"]
        XCTAssertTrue(waitForEnabled(send, timeout: 20), "Send did not enable after entering the prompt")
        send.tap()

        let committedPrompt = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND value CONTAINS %@", "You said", marker)
        ).firstMatch
        XCTAssertTrue(committedPrompt.waitForExistence(timeout: 30),
                      "the real-device prompt was not committed to the conversation")

        let answer = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", responseMarker)
        ).firstMatch
        // A committed non-empty assistant turn owns both the Copy action and Generation stats. Exact
        // wording is instruction-following quality, not an inference-liveness requirement: a 1-bit model
        // replying merely "OK" still completed a real generation and must not leave this test waiting.
        let committedAnswer = app.buttons["Copy answer"].firstMatch
        let stats = app.staticTexts["Generation stats"]
        let failedReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR label == %@",
                        "Couldn't generate a reply", "The model didn't reply")
        ).firstMatch
        let webSearchActivity = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Web Search")
        ).firstMatch

        let deadline = Date().addingTimeInterval(420)
        var completed = false
        var invokedWebSearch = false
        var reportedFailure = false
        var leftForeground = false
        while Date() < deadline {
            if app.state != .runningForeground {
                leftForeground = true
                break
            }
            if webSearchActivity.exists {
                invokedWebSearch = true
                break
            }
            if failedReply.exists {
                reportedFailure = true
                break
            }
            if committedAnswer.exists, stats.exists {
                completed = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }

        XCTAssertFalse(leftForeground, "mobileLLM exited the foreground during Bonsai inference")
        XCTAssertFalse(invokedWebSearch,
                       "Bonsai invoked Web Search despite an explicit no-tool request")
        XCTAssertFalse(reportedFailure, "Bonsai committed an empty or failed reply")
        XCTAssertTrue(completed,
                      "Bonsai did not commit a non-empty answer with Generation stats within 420 seconds")
        XCTAssertTrue(answer.exists,
                      "Bonsai completed inference but did not output the exact DEVICE_SMOKE_OK format")
    }

    @MainActor
    private func switchStarting(with label: String, in root: XCUIElement) -> XCUIElement {
        root.switches.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    @MainActor
    private func firstHittableScrollView(in app: XCUIApplication) -> XCUIElement {
        for scrollView in app.scrollViews.allElementsBoundByIndex where scrollView.isHittable {
            return scrollView
        }
        return app.scrollViews.firstMatch
    }

    @MainActor
    private func buttonStarting(with label: String, in root: XCUIElement) -> XCUIElement {
        root.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    @MainActor
    private func switchValue(_ element: XCUIElement) -> String {
        if let value = element.value as? String { return value }
        if let value = element.value as? NSNumber { return value.stringValue }
        return String(describing: element.value)
    }

    @MainActor
    private func scrollToHittable(_ element: XCUIElement,
                                  in scrollView: XCUIElement,
                                  swipingUp: Bool = true) -> Bool {
        for _ in 0..<8 {
            if element.exists, element.isHittable { return true }
            if swipingUp {
                scrollView.swipeUp()
            } else {
                scrollView.swipeDown()
            }
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func waitForSwitch(_ element: XCUIElement,
                               toDifferFrom oldValue: String,
                               timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if switchValue(element) != oldValue { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return switchValue(element) != oldValue
    }

    @MainActor
    private func waitForSwitch(_ element: XCUIElement,
                               toEqual expectedValue: String,
                               timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if switchValue(element) == expectedValue { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return switchValue(element) == expectedValue
    }

    @MainActor
    private func waitForValue(of element: XCUIElement,
                              toStartWith prefix: String,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = element.value as? String, value.hasPrefix(prefix) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return (element.value as? String)?.hasPrefix(prefix) == true
    }

    @MainActor
    private func waitForComposer(_ field: XCUIElement,
                                 in app: XCUIApplication,
                                 timeout: TimeInterval) -> Bool {
        let tryAnyway = app.buttons["Try anyway"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tryAnyway.exists, tryAnyway.isHittable { tryAnyway.tap() }
            if field.exists, field.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return field.exists && field.isHittable
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled, element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.exists && element.isEnabled && element.isHittable
    }

    /// Best-effort cleanup also runs after a failed load, crash, tool detour, or inference timeout. Relaunch
    /// first so the app is on the list with no resident model, then delete either the unique marker title or
    /// (only when proven safe above) the one smoke-created empty fallback. The undo window must expire while
    /// the app remains alive so the tombstone is hard-deleted.
    @MainActor
    private func cleanUpSmokeConversation(_ marker: String,
                                          removeFallbackEmpty: Bool,
                                          in app: XCUIApplication) -> Bool {
        if app.state == .runningForeground {
            let stop = app.buttons["Stop"]
            if waitForEnabled(stop, timeout: 2) {
                stop.tap()
                _ = waitUntilGone(stop, timeout: 15)
            }
        }

        app.terminate()
        app.launch()
        guard app.navigationBars["Chat"].waitForExistence(timeout: 30) else { return false }

        let search = app.textFields["Search chats"]
        guard search.waitForExistence(timeout: 10) else { return false }
        search.tap()
        search.typeText(marker)

        var target = app.buttons[marker]
        if !target.waitForExistence(timeout: 10) {
            if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
            guard removeFallbackEmpty else { return false }
            let emptyRows = app.buttons.matching(NSPredicate(format: "value == %@", "No messages yet"))
            guard emptyRows.count == 1 else { return false }
            target = emptyRows.firstMatch
        }

        target.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        guard delete.waitForExistence(timeout: 5) else { return false }
        delete.tap()
        guard waitUntilGone(target, timeout: 10) else { return false }

        Thread.sleep(forTimeInterval: 6)
        app.terminate()
        app.launch()
        guard app.navigationBars["Chat"].waitForExistence(timeout: 30) else { return false }

        let verifySearch = app.textFields["Search chats"]
        guard verifySearch.waitForExistence(timeout: 10) else { return false }
        verifySearch.tap()
        verifySearch.typeText(marker)
        let markerIsGone = !app.buttons[marker].waitForExistence(timeout: 3)
        if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
        let fallbackIsGone = !removeFallbackEmpty
            || app.buttons.matching(NSPredicate(format: "value == %@", "No messages yet")).count == 0
        return markerIsGone && fallbackIsGone
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !element.exists
    }
}
