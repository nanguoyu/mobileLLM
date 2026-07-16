// SPDX-License-Identifier: MIT

import XCTest

/// The keyboard/composer geometry, asserted instead of eyeballed. Four "fixes" shipped blind against
/// this exact surface before the ground truth (UIWindow.keyboardLayoutGuide) landed — this test is the
/// reason a fifth never ships blind.
///
/// Prerequisite: a model on disk (any small GGUF), or the composer shows the no-model bar and there is
/// no text field to focus. The runner seeds one into the simulator container, e.g.:
///   simctl get_app_container <sim> com.elss.mobileLLM data
///   → <container>/Library/Application Support/mobileLLM/models/prism-ml/Bonsai-1.7B-gguf/Bonsai-1.7B-Q1_0.gguf
final class KeyboardUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testComposerRidesTheKeyboard() throws {
        let app = XCUIApplication()
        app.launch()

        // Boot may show the OOM pre-flight banner (the simulator reports zero available memory) —
        // "Try anyway" loads the model regardless.
        let tryAnyway = app.buttons["Try anyway"]
        if tryAnyway.waitForExistence(timeout: 5) { tryAnyway.tap() }

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

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !element.exists
    }
}
