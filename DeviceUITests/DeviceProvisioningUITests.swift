// SPDX-License-Identifier: MIT

import XCTest

/// Run these four tests in order on a freshly deleted app. They deliberately exercise the production
/// install/download path; subsequent full-stack tests consume the two verified artifacts from disk.
final class DeviceProvisioningUITests: DeviceE2ETestCase {

    @MainActor
    func test00CleanInstallColdLaunch() throws {
        let app = try launchApp()
        XCTAssertTrue(app.navigationBars["Chat"].exists)
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["composer.field"].exists,
                       "cold launch must not create or enter a conversation")
        let runtime = diagnosticValue("device-e2e.runtime", in: app)
        XCTAssertTrue(runtime.contains("resident=false"), "clean install loaded weights: \(runtime)")
        XCTAssertTrue(runtime.contains("phase=idle"), "clean install started model work: \(runtime)")

        app.tabBars.buttons["Models"].tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 15))
        let inventory = diagnosticValue("device-e2e.inventory", in: app)
        XCTAssertFalse(inventory.contains(DeviceTestModel.bonsai.variantID),
                       "clean install retained Bonsai: \(inventory)")
        XCTAssertFalse(inventory.contains(DeviceTestModel.gemma.variantID),
                       "clean install retained Gemma: \(inventory)")
        attachDiagnostics(app, name: "clean-install")

        try goToChatList(in: app)
        let newChat = app.buttons.matching(identifier: "New chat").firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        XCTAssertTrue(app.buttons["Active model"].waitForExistence(timeout: 15))
        let openedRuntime = diagnosticValue("device-e2e.runtime", in: app)
        XCTAssertTrue(openedRuntime.contains("resident=false"),
                      "opening a new chat eagerly loaded its selected identity: \(openedRuntime)")
        XCTAssertTrue(openedRuntime.contains("phase=idle"),
                      "opening a new chat started inference work: \(openedRuntime)")
    }

    @MainActor
    func test01DownloadBonsaiWithPauseAndResume() throws {
        let app = try launchApp()
        try download(.bonsai, exercisingPause: true, in: app)
    }

    @MainActor
    func test02DownloadGemmaVisionBundle() throws {
        let app = try launchApp()
        try download(.gemma, exercisingPause: true, in: app)
    }

    @MainActor
    func test03InstalledInventoryAndRealLoads() throws {
        let app = try launchApp()
        try openNewChat(in: app)

        // The switcher contains installed artifacts only, so these exact labels prove the iPhone has the
        // intended GGUF variants rather than an MLX sibling or an incomplete Gemma projector download.
        try assertInstalledVariant(.bonsai, in: app)
        try assertInstalledVariant(.gemma, in: app)

        try activate(.bonsai, in: app)
        try activate(.gemma, in: app)
        assertNoMemoryInterlock(in: app)
        attachDiagnostics(app, name: "both-models-installed-and-loadable")

        try goToChatList(in: app)
        try relaunch(app)
        XCTAssertTrue(app.navigationBars["Chat"].exists)
        XCTAssertFalse(app.textFields["composer.field"].exists,
                       "relaunch must not reopen the prior thread")
        let runtime = diagnosticValue("device-e2e.runtime", in: app)
        XCTAssertTrue(runtime.contains("model=gemma-4-e2b"),
                      "last model identity should be restored: \(runtime)")
        XCTAssertTrue(runtime.contains("resident=false"),
                      "cold launch must restore identity without loading weights: \(runtime)")
    }

    @MainActor
    private func download(_ model: DeviceTestModel,
                          exercisingPause: Bool,
                          in app: XCUIApplication) throws {
        try goToChatList(in: app)
        app.tabBars.buttons["Models"].tap()
        guard app.navigationBars["Models"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Models screen did not open")
        }
        let search = app.textFields["Search models — name, publisher…"]
        guard search.waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Model search field is unavailable")
        }
        search.tap()
        search.typeText(model.displayName)

        // Bonsai ships same-quant MLX and llama.cpp siblings. Select the exact engine explicitly so a
        // layout/catalog-order change can never download the wrong 1-bit artifact. Gemma has only GGUF.
        if model == .bonsai {
            let llama = app.buttons["llama.cpp"].firstMatch
            guard llama.waitForExistence(timeout: 10) else {
                attachDiagnostics(app, name: "engine-picker-missing-\(model.modelID)")
                throw DeviceE2EHarnessError.precondition(
                    "Bonsai must expose distinct MLX and llama.cpp engine segment labels"
                )
            }
            if !llama.isSelected { llama.tap() }
            guard llama.isSelected else {
                throw DeviceE2EHarnessError.precondition("llama.cpp engine did not become selected")
            }
        }

        // Searching focuses the keyboard, which can cover the download action on a 6.1-inch phone.
        // Prefer the real Return key, then let the outer model scroll make the action hittable.
        let returnKey = app.keyboards.buttons["Return"].firstMatch
        if returnKey.exists, returnKey.isHittable { returnKey.tap() }

        let use = app.buttons["Use \(model.displayName)"]
        if use.waitForExistence(timeout: 3) {
            attachDiagnostics(app, name: "already-downloaded-\(model.modelID)")
            return
        }

        let download = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Download ·")
        ).firstMatch
        guard download.waitForExistence(timeout: 20),
              scrollToHittable(download, in: firstHittableScrollView(in: app)) else {
            attachDiagnostics(app, name: "download-action-missing-\(model.modelID)")
            throw DeviceE2EHarnessError.precondition("Download action is missing for \(model.displayName)")
        }
        download.tap()

        let progress = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Downloading \(model.displayName)")
        ).firstMatch
        guard progress.waitForExistence(timeout: 30) else {
            throw DeviceE2EHarnessError.precondition("Download did not start for \(model.displayName)")
        }

        if exercisingPause {
            let pause = app.buttons["Pause download"]
            guard pause.waitForExistence(timeout: 30), pause.isHittable else {
                throw DeviceE2EHarnessError.precondition("Pause is unavailable during \(model.displayName) download")
            }
            pause.tap()
            let resume = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Resume ·")
            ).firstMatch
            guard resume.waitForExistence(timeout: 90), resume.isHittable else {
                attachDiagnostics(app, name: "pause-timeout-\(model.modelID)")
                throw DeviceE2EHarnessError.timeout("\(model.displayName) did not reach paused state")
            }
            resume.tap()
            XCTAssertTrue(progress.waitForExistence(timeout: 30), "Download did not resume")
        }

        let deadline = Date().addingTimeInterval(2_400)
        while Date() < deadline {
            if use.exists { break }
            if app.state != .runningForeground {
                throw DeviceE2EHarnessError.precondition("App left foreground during model download")
            }
            let retry = app.buttons["Retry download"]
            if retry.exists {
                attachDiagnostics(app, name: "download-failed-\(model.modelID)")
                throw DeviceE2EHarnessError.precondition("Download failed for \(model.displayName)")
            }
            Thread.sleep(forTimeInterval: 2)
        }
        guard use.exists else {
            attachDiagnostics(app, name: "download-timeout-\(model.modelID)")
            throw DeviceE2EHarnessError.timeout("Download did not complete for \(model.displayName)")
        }
        attachDiagnostics(app, name: "downloaded-\(model.modelID)")
    }
}
