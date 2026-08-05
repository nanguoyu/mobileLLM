// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// Local, non-repo OpenAI-compatible service config used by UI tests on macOS. The developer stores it
/// once at `~/.mobilellm/openai.json`; tests forward it into the app's launch environment so the
/// simulator and physical device never need the key typed by hand.
private struct OpenAILocalTestConfig: Codable {
    var apiKey: String?
    var baseURL: String?
    var model: String?
}

private func loadOpenAITestConfig() -> (
    apiKey: String?, baseURL: String?, model: String?
) {
    let env = ProcessInfo.processInfo.environment
    var apiKey = env["MOBILELLM_OPENAI_API_KEY"]
    var baseURL = env["MOBILELLM_OPENAI_BASE_URL"]
    var model = env["MOBILELLM_OPENAI_MODEL"]
    if apiKey == nil || baseURL == nil || model == nil {
        #if os(macOS)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mobilellm/openai.json")
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(OpenAILocalTestConfig.self, from: data)
        {
            apiKey = apiKey ?? config.apiKey
            baseURL = baseURL ?? config.baseURL
            model = model ?? config.model
        }
        #endif
    }
    return (apiKey, baseURL, model)
}

enum DeviceTestModel: CaseIterable, Equatable {
    case bonsai
    case gemma

    var displayName: String {
        switch self {
        case .bonsai: "Bonsai 8B"
        case .gemma: "Gemma 4 E2B"
        }
    }

    var modelID: String {
        switch self {
        case .bonsai: "bonsai-8b"
        case .gemma: "gemma-4-e2b"
        }
    }

    var variantID: String {
        switch self {
        case .bonsai: "prism-ml/Bonsai-8B-gguf#gguf"
        case .gemma: "unsloth/gemma-4-E2B-it-GGUF#gguf"
        }
    }

    var quant: String {
        switch self {
        case .bonsai: "1-bit"
        case .gemma: "Q4_K_M"
        }
    }

    var headerValue: String { "\(displayName) · \(quant)" }
    var switcherLabel: String { "\(displayName), \(quant), llama.cpp" }
    var loadTimeout: TimeInterval { self == .bonsai ? 240 : 360 }
    var generationTimeout: TimeInterval { self == .bonsai ? 480 : 600 }
}

struct GenerationEvidence {
    let answer: String
    let stats: String
    let toolActivities: [String]
    let reasoning: String?
    let wallSeconds: TimeInterval
}

enum DeviceE2EHarnessError: LocalizedError {
    case precondition(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .precondition(let message), .timeout(let message): message
        }
    }
}

/// Shared robot for signed, serial XCUITests on the connected iPhone. Tests intentionally drive the
/// production data path because the device is a user-provided clean install. Unknown system UI is still
/// a hard boundary: screenshot, Home, terminate, fail — never open Settings, Mail, or an account flow.
class DeviceE2ETestCase: XCTestCase {
    var activeApp: XCUIApplication?
    private var systemAlertMonitor: NSObjectProtocol?

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 3_600
        systemAlertMonitor = addUIInterruptionMonitor(
            withDescription: "Unknown-system-alert firewall"
        ) { alert in
            MainActor.assumeIsolated {
                // Handoff's "Pasting from <Mac>" prompt is unrelated to the app under test; dismiss it
                // so memory/typing tests are not derailed by an ambient system UI. Everything else stays
                // a hard boundary below.
                if alert.label.hasPrefix("Pasting from") {
                    let dontPaste = alert.buttons["Don't Paste"]
                    if dontPaste.exists { dontPaste.tap() }
                    return true
                }
                XCTContext.runActivity(named: "Blocked unexpected system alert") { activity in
                    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    screenshot.name = "blocked-system-alert-\(alert.label)"
                    screenshot.lifetime = .keepAlways
                    activity.add(screenshot)
                    let hierarchy = XCTAttachment(string: alert.debugDescription)
                    hierarchy.name = "blocked-system-alert-hierarchy"
                    hierarchy.lifetime = .keepAlways
                    activity.add(hierarchy)
                }
                XCUIDevice.shared.press(.home)
                XCUIApplication().terminate()
                XCTFail("Refusing to interact with unexpected system alert: \(alert.label)")
                return true
            }
        }
    }

    override func tearDownWithError() throws {
        if let systemAlertMonitor {
            removeUIInterruptionMonitor(systemAlertMonitor)
            self.systemAlertMonitor = nil
        }
        activeApp = nil
    }

    @MainActor
    func launchApp(visionFixture: Bool = false) throws -> XCUIApplication {
        #if targetEnvironment(simulator)
        throw XCTSkip("DeviceE2E must run on a physical iPhone")
        #endif
        let app = XCUIApplication()
        app.launchEnvironment["MOBILELLM_DEVICE_E2E"] = "1"
        app.launchEnvironment["MOBILELLM_DEVICE_E2E_FIXTURE"] = visionFixture ? "1" : "0"
        // The OpenAI-compatible service config is stored ONCE on the Mac at ~/.mobilellm/openai.json
        // (never in Git). Environment variables win when present; otherwise the file is read here and
        // injected through launchEnvironment so simulator and physical-device apps never need manual
        // entry. The DEBUG app seeds the key into its own Keychain.
        let openAI = loadOpenAITestConfig()
        // Debug-only breadcrumb: confirms the runner read ~/.mobilellm/openai.json (flags + model only,
        // never the key).
        print("[DeviceE2E] openai runner config: key=\(openAI.apiKey?.isEmpty == false) "
            + "baseURL=\(openAI.baseURL ?? "nil") model=\(openAI.model ?? "nil")")
        if let key = openAI.apiKey, !key.isEmpty {
            app.launchEnvironment["MOBILELLM_OPENAI_API_KEY"] = key
        }
        if let baseURL = openAI.baseURL, !baseURL.isEmpty {
            app.launchEnvironment["MOBILELLM_OPENAI_BASE_URL"] = baseURL
        }
        if let model = openAI.model, !model.isEmpty {
            app.launchEnvironment["MOBILELLM_OPENAI_MODEL"] = model
        }
        // Long-form device tests measure engine behavior, not the cooling duty cycle: the harness
        // opts out of cooperative thermal pacing (production is unaffected).
        app.launchEnvironment["MOBILELLM_DISABLE_THERMAL"] = "1"
        activeApp = app
        app.launch()

        guard app.tabBars.buttons["Chat"].waitForExistence(timeout: 45) else {
            attachDiagnostics(app, name: "launch-failed")
            throw DeviceE2EHarnessError.precondition("App did not reach its interactive shell")
        }
        guard diagnostic("device-e2e.runtime", in: app).waitForExistence(timeout: 10) else {
            app.terminate()
            throw DeviceE2EHarnessError.precondition("DEBUG DeviceE2E diagnostics handshake is missing")
        }
        assertNoMemoryInterlock(in: app)
        return app
    }

    @MainActor
    func relaunch(_ app: XCUIApplication, visionFixture: Bool = false) throws {
        app.terminate()
        app.launchEnvironment["MOBILELLM_DEVICE_E2E"] = "1"
        app.launchEnvironment["MOBILELLM_DEVICE_E2E_FIXTURE"] = visionFixture ? "1" : "0"
        app.launch()
        guard app.tabBars.buttons["Chat"].waitForExistence(timeout: 45),
              diagnostic("device-e2e.runtime", in: app).waitForExistence(timeout: 10) else {
            attachDiagnostics(app, name: "relaunch-failed")
            throw DeviceE2EHarnessError.precondition("App did not recover after relaunch")
        }
        assertNoMemoryInterlock(in: app)
    }

    @MainActor
    func diagnostic(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func diagnosticValue(_ identifier: String, in app: XCUIApplication) -> String {
        let element = diagnostic(identifier, in: app)
        return (element.value as? String) ?? element.label
    }

    @MainActor
    func assertNoMemoryInterlock(in app: XCUIApplication, file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertFalse(app.buttons["Try anyway"].exists,
                       "Model loading must never be blocked by a Try anyway gate", file: file, line: line)
        let warning = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Not enough free memory")
        ).firstMatch
        XCTAssertFalse(warning.exists,
                       "Free-memory estimates are advisory and must not block activation", file: file, line: line)
    }

    @MainActor
    func openNewChat(in app: XCUIApplication) throws {
        try goToChatList(in: app)
        let newChat = app.buttons.matching(identifier: "New chat").firstMatch
        guard newChat.waitForExistence(timeout: 15), newChat.isHittable else {
            throw DeviceE2EHarnessError.precondition("New chat is not available")
        }
        newChat.tap()
        guard app.buttons["Active model"].waitForExistence(timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("New conversation did not open")
        }
    }

    @MainActor
    func goToChatList(in app: XCUIApplication) throws {
        if app.textFields["composer.field"].exists || app.buttons["Active model"].exists {
            let back = app.navigationBars.buttons["Chat"].firstMatch
            if back.exists, back.isHittable { back.tap() }
        }
        if !app.navigationBars["Chat"].exists {
            let tab = app.tabBars.buttons["Chat"]
            guard tab.waitForExistence(timeout: 10) else {
                throw DeviceE2EHarnessError.precondition("Chat tab is unavailable")
            }
            tab.tap()
        }
        guard app.navigationBars["Chat"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Chat list did not appear")
        }
    }

    /// Clears every saved memory fact through the Settings UI. Cross-model memory tests need exactly one
    /// fact on the device, otherwise a small reader model can pick the wrong one of two similar notes.
    @MainActor
    func clearAllMemories(in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let memory = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Memory")
        ).firstMatch
        guard scrollToHittable(memory, in: app.scrollViews.firstMatch) else {
            throw DeviceE2EHarnessError.precondition("Memory settings row is unreachable")
        }
        memory.tap()
        guard app.navigationBars["Memory"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Memory sheet did not open")
        }
        let forget = app.buttons["Forget everything"]
        if forget.exists, forget.isHittable {
            forget.tap()
            let alert = app.alerts["Forget everything?"]
            guard alert.waitForExistence(timeout: 5) else {
                throw DeviceE2EHarnessError.precondition("Forget-everything confirmation did not appear")
            }
            alert.buttons["Forget everything"].tap()
            guard waitUntilGone(forget, timeout: 10) else {
                throw DeviceE2EHarnessError.precondition("Memory was not cleared")
            }
        }
        let done = app.navigationBars["Memory"].buttons["Done"]
        if done.exists, done.isHittable { done.tap() }
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Memory sheet did not close")
        }
        try goToChatList(in: app)
    }

    /// Adds a public MCP server (DeepWiki) through Settings and waits for its explicit discovery.
    /// Discovery is the ONLY network touch allowed by spec §13; the agent runtime never connects at
    /// prompt-compilation time.
    @MainActor
    func addPublicMCPServer(in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let toolsRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Choose tools")
        ).firstMatch
        guard scrollToHittable(toolsRow, in: app.scrollViews.firstMatch) else {
            throw DeviceE2EHarnessError.precondition("Tools settings row is unreachable")
        }
        toolsRow.tap()
        guard app.navigationBars["Tools"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Tools settings did not open")
        }
        let mcpRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "MCP servers")
        ).firstMatch
        guard scrollToHittable(mcpRow, in: app.scrollViews.firstMatch) else {
            throw DeviceE2EHarnessError.precondition("MCP servers row is unreachable")
        }
        mcpRow.tap()
        guard app.navigationBars["MCP servers"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("MCP servers sheet did not open")
        }
        let add = app.buttons["Add a server"]
        guard add.waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Add-a-server button is missing")
        }
        add.tap()

        let name = app.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "DeepWiki")
        ).firstMatch
        guard name.waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("MCP name field is missing")
        }
        name.tap()
        name.typeText("DeepWiki")
        let url = app.textFields.matching(
            NSPredicate(format: "placeholderValue == %@", "https://host/mcp")
        ).firstMatch
        guard url.waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("MCP URL field is missing")
        }
        url.tap()
        url.typeText("https://mcp.deepwiki.com/mcp")

        let test = app.buttons["Test connection"]
        guard test.waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Test-connection button is missing")
        }
        test.tap()
        let connected = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Connected ·")
        ).firstMatch
        guard connected.waitForExistence(timeout: 90) else {
            attachDiagnostics(app, name: "mcp-connect-failed")
            throw DeviceE2EHarnessError.precondition("DeepWiki MCP did not connect")
        }
        let confirmAdd = app.buttons["Add"]
        guard confirmAdd.waitForExistence(timeout: 10), confirmAdd.isEnabled else {
            throw DeviceE2EHarnessError.precondition("MCP Add stayed disabled")
        }
        confirmAdd.tap()

        guard app.navigationBars["MCP servers"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("MCP servers sheet did not reappear")
        }
        // Give the post-add probe a moment to finish discovery and cache the tool specs.
        Thread.sleep(forTimeInterval: 3)
        let done = app.navigationBars["MCP servers"].buttons["Done"]
        guard done.exists, done.isHittable else {
            throw DeviceE2EHarnessError.precondition("MCP servers Done is not actionable")
        }
        done.tap()
        guard app.navigationBars["Tools"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("MCP sheet did not close to Tools")
        }
        let toolsDone = app.navigationBars["Tools"].buttons["Done"]
        if toolsDone.exists, toolsDone.isHittable { toolsDone.tap() }
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Tools settings did not close")
        }
        try goToChatList(in: app)
    }

    /// Removes every configured MCP server before model tests that must exercise only the built-in
    /// tool chain. A server added by the MCP test (or by manual device use) persists in Settings and
    /// can push dozens of remote tools into the prompt, which overwhelms the local 1-bit models and
    /// makes unrelated tests fail with "could not produce a valid structured action".
    @MainActor
    func removeAllMCPServers(in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let choose = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Choose tools")
        ).firstMatch
        guard scrollToHittable(choose, in: app.scrollViews.firstMatch) else {
            throw DeviceE2EHarnessError.precondition("Choose tools is unreachable while removing MCP servers")
        }
        choose.tap()
        guard app.navigationBars["Tools"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Tools settings did not open while removing MCP servers")
        }
        let mcpRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "MCP servers")
        ).firstMatch
        guard scrollToHittable(mcpRow, in: firstHittableScrollView(in: app)) else {
            throw DeviceE2EHarnessError.precondition("MCP servers row is unreachable while removing servers")
        }
        mcpRow.tap()
        guard app.navigationBars["MCP servers"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("MCP servers sheet did not open")
        }
        while true {
            // The list must be on top before we scan for rows: while the detail sheet is up the rows
            // are covered and a scan would wrongly conclude there are no servers left. Removal can
            // land on the detail's Done, back on the list, or back at the Tools sheet; settle each.
            try settleMCPList(in: app)
            let serverRow = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "://")
            ).firstMatch
            guard serverRow.waitForExistence(timeout: 3), serverRow.isHittable else { break }
            serverRow.tap()
            let remove = app.buttons["Remove server"]
            guard remove.waitForExistence(timeout: 10), remove.isHittable else {
                throw DeviceE2EHarnessError.precondition("MCP server detail did not expose Remove server")
            }
            remove.tap()
            let alert = app.alerts.firstMatch
            guard alert.waitForExistence(timeout: 10) else {
                throw DeviceE2EHarnessError.precondition("MCP remove confirmation did not appear")
            }
            alert.buttons["Remove"].tap()
            // Let the detail sheet dismiss before the next iteration scans the list.
            let detailDone = app.buttons["Done"]
            if detailDone.exists, detailDone.isHittable {
                // Detail is still up: dismiss it (the removal already committed).
                detailDone.tap()
            }
        }
        let done = app.navigationBars["MCP servers"].buttons["Done"]
        if done.exists, done.isHittable { done.tap() }
        guard app.navigationBars["Tools"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("MCP sheet did not close after cleanup")
        }
        let toolsDone = app.navigationBars["Tools"].buttons["Done"]
        if toolsDone.exists, toolsDone.isHittable { toolsDone.tap() }
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Tools settings did not close after MCP cleanup")
        }
        try goToChatList(in: app)
    }

    /// Brings the MCP servers LIST sheet back on top: taps the detail's Done when a server detail is
    /// still up, re-enters from the Tools sheet when removal dismissed the whole flow, and otherwise
    /// waits for the list to settle.
    @MainActor
    private func settleMCPList(in app: XCUIApplication) throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if app.buttons["Add a server"].exists { return }
            if app.buttons["Remove server"].exists {
                let detailDone = app.navigationBars["MCP servers"].buttons["Done"].firstMatch
                if detailDone.exists, detailDone.isHittable {
                    detailDone.tap()
                }
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            if app.navigationBars["Tools"].exists {
                let mcpRow = app.buttons.matching(
                    NSPredicate(format: "label CONTAINS %@", "MCP servers")
                ).firstMatch
                if scrollToHittable(mcpRow, in: firstHittableScrollView(in: app)) {
                    mcpRow.tap()
                }
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw DeviceE2EHarnessError.precondition("MCP servers list did not reappear after removal")
    }

    @MainActor
    func activate(_ model: DeviceTestModel, in app: XCUIApplication) throws {
        let active = app.buttons["Active model"]
        guard active.waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("A conversation must be open before model activation")
        }
        active.tap()
        guard app.navigationBars["Switch model"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Model switcher did not open")
        }
        let row = app.buttons[model.switcherLabel]
        guard row.waitForExistence(timeout: 20) else {
            attachDiagnostics(app, name: "missing-\(model.modelID)")
            throw DeviceE2EHarnessError.precondition(
                "Required installed variant is missing: \(model.switcherLabel)"
            )
        }
        row.tap()

        let deadline = Date().addingTimeInterval(model.loadTimeout)
        var runtime = ""
        while Date() < deadline {
            assertNoMemoryInterlock(in: app)
            runtime = diagnosticValue("device-e2e.runtime", in: app)
            if !app.navigationBars["Switch model"].exists,
               runtime.contains("variant=\(model.variantID)"),
               runtime.contains("engine=llama.cpp"),
               runtime.contains("resident=true") {
                break
            }
            if app.state != .runningForeground {
                throw DeviceE2EHarnessError.precondition("App left foreground while loading \(model.displayName)")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard runtime.contains("variant=\(model.variantID)"),
              runtime.contains("engine=llama.cpp"),
              runtime.contains("resident=true") else {
            attachDiagnostics(app, name: "load-timeout-\(model.modelID)")
            throw DeviceE2EHarnessError.timeout(
                "\(model.displayName) did not become resident through the expected GGUF/llama.cpp variant; \(runtime)"
            )
        }
        guard waitForValue(of: active, equalTo: model.headerValue, timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("Active-model header did not identify \(model.headerValue)")
        }
        let field = app.textFields["composer.field"]
        // The engine can report resident=true just before the model-switch sheet finishes its UI
        // transition. A field behind that sheet technically exists but is not usable; wait for the
        // user-observable ready state rather than sampling isHittable once.
        guard waitForEnabled(field, timeout: 60) else {
            attachDiagnostics(app, name: "composer-not-ready-\(model.modelID)")
            throw DeviceE2EHarnessError.precondition("Composer is unavailable after loading \(model.displayName)")
        }
    }

    @MainActor
    func assertInstalledVariant(_ model: DeviceTestModel, in app: XCUIApplication) throws {
        let active = app.buttons["Active model"]
        guard active.waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Open a conversation before inventory inspection")
        }
        active.tap()
        guard app.navigationBars["Switch model"].waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Model switcher did not open")
        }
        let row = app.buttons[model.switcherLabel]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Missing installed variant \(model.switcherLabel)")
        app.navigationBars["Switch model"].buttons["Done"].tap()
    }

    @MainActor
    @discardableResult
    func send(_ prompt: String,
              model: DeviceTestModel,
              in app: XCUIApplication,
              timeout: TimeInterval? = nil,
              acceptedStops: [String] = ["eos", "stopSequence", "maxTokens"],
              assertEvidence: Bool = true) throws -> GenerationEvidence {
        let field = app.textFields["composer.field"]
        guard field.waitForExistence(timeout: 20), field.isHittable else {
            throw DeviceE2EHarnessError.precondition("Composer is not ready for \(model.displayName)")
        }
        // The whole device matrix must exercise the durable agent runtime; a silent fallback to the
        // legacy loop would make tool/vision scenarios pass without ever testing the agent path.
        let agentRuntime = diagnosticValue("device-e2e.agent", in: app)
        XCTAssertTrue(
            agentRuntime.contains("enabled=true"),
            "device tests must run on the agent runtime; diagnostics: \(agentRuntime)"
        )

        let answerQuery = app.descendants(matching: .any).matching(identifier: "assistant.answer")
        let statsQuery = app.descendants(matching: .any).matching(identifier: "assistant.stats")
        let copyCount = app.buttons.matching(identifier: "Copy answer").count
        let statsCount = statsQuery.count
        let toolCount = app.descendants(matching: .any)
            .matching(identifier: "assistant.tool.run").count
        let start = Date()

        field.tap()
        field.typeText(prompt)
        let send = app.buttons["Send"]
        guard waitForEnabled(send, timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("Send did not enable for a non-empty prompt")
        }
        send.tap()

        let deadline = Date().addingTimeInterval(timeout ?? model.generationTimeout)
        while Date() < deadline {
            if app.state != .runningForeground {
                attachDiagnostics(app, name: "generation-left-foreground")
                throw DeviceE2EHarnessError.precondition("App left foreground during \(model.displayName) generation")
            }
            approvePendingAgentApprovalIfNeeded(in: app)
            let failure = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@ OR label == %@",
                            "Couldn't generate a reply", "The model didn't reply")
            ).firstMatch
            if failure.exists {
                Thread.sleep(forTimeInterval: 3)
                let finalDiagnostics = diagnosticValue("device-e2e.agent", in: app)
                attachDiagnostics(app, name: "generation-failed-\(model.modelID)")
                throw DeviceE2EHarnessError.precondition(
                    "\(model.displayName) committed a failed/empty reply; diagnostics: \(finalDiagnostics)"
                )
            }
            // The agent runtime surfaces failures in its own projection panel; detect that state
            // directly so a failed run fails fast with full diagnostics instead of waiting out the
            // generation deadline.
            let agentDiagnostics = diagnosticValue("device-e2e.agent", in: app)
            if agentDiagnostics.contains("run=failed")
                || agentDiagnostics.contains("run=cancelled")
            {
                // Let the diagnostics overlay's 1s poll pick up the worker log before reading.
                Thread.sleep(forTimeInterval: 3)
                let finalDiagnostics = diagnosticValue("device-e2e.agent", in: app)
                attachDiagnostics(app, name: "agent-run-failed-\(model.modelID)")
                throw DeviceE2EHarnessError.precondition(
                    "\(model.displayName) agent run failed; diagnostics: \(finalDiagnostics)"
                )
            }
            if app.buttons.matching(identifier: "Copy answer").count > copyCount,
               statsQuery.count > statsCount,
               !app.buttons["Stop"].exists {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard app.buttons.matching(identifier: "Copy answer").count > copyCount,
              statsQuery.count > statsCount else {
            attachDiagnostics(app, name: "generation-timeout-\(model.modelID)")
            throw DeviceE2EHarnessError.timeout("\(model.displayName) did not commit a reply within the deadline")
        }

        let answers = answerQuery.allElementsBoundByIndex
        let statsElements = statsQuery.allElementsBoundByIndex
        guard let answerElement = answers.last, let statsElement = statsElements.last else {
            throw DeviceE2EHarnessError.precondition("Committed reply lacks raw answer or stats diagnostics")
        }
        let answer = ((answerElement.value as? String) ?? answerElement.label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stats = (statsElement.value as? String) ?? statsElement.label
        let allTools = app.descendants(matching: .any)
            .matching(identifier: "assistant.tool.run")
            .allElementsBoundByIndex.map(\.label)
        let tools = Array(allTools.dropFirst(min(toolCount, allTools.count)))
        let reasoningElement = app.descendants(matching: .any)
            .matching(identifier: "assistant.reasoning").allElementsBoundByIndex.last
        let reasoning = reasoningElement.flatMap { ($0.value as? String) ?? $0.label }
        let evidence = GenerationEvidence(answer: answer, stats: stats, toolActivities: tools,
                                          reasoning: reasoning, wallSeconds: Date().timeIntervalSince(start))
        attachGenerationEvidence(evidence, app: app, name: model.modelID)

        if assertEvidence {
            let failures = generationEvidenceFailures(evidence, model: model,
                                                       acceptedStops: acceptedStops)
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        }
        return evidence
    }

    /// Baseline invariants shared by ordinary turns and tests that deliberately defer assertions until
    /// every dependent surface has been inspected. The latter prevents an output-format miss from hiding
    /// whether a tool ran, durable state changed, or another model could consume that state.
    @MainActor
    func generationEvidenceFailures(_ evidence: GenerationEvidence,
                                    model: DeviceTestModel,
                                    acceptedStops: [String] = ["eos", "stopSequence", "maxTokens"])
        -> [String] {
        var failures: [String] = []
        if evidence.answer.isEmpty {
            failures.append("Committed answer is empty")
        }
        if !evidence.stats.hasPrefix(model.displayName + " ·") {
            failures.append("Stats do not identify \(model.displayName): \(evidence.stats)")
        }
        if evidence.stats.range(of: #"· [1-9][0-9]* tok ·"#,
                                options: .regularExpression) == nil {
            failures.append("Stats do not report a positive generated-token count: \(evidence.stats)")
        }
        if reportedDecodeThroughput(in: evidence.stats) == nil {
            failures.append("Stats do not report positive decode throughput: \(evidence.stats)")
        }
        if !acceptedStops.contains(where: { evidence.stats.contains("stop: \($0)") }) {
            failures.append("Unexpected stop reason in stats: \(evidence.stats)")
        }
        return failures
    }

    /// Reads the human-facing rate without assuming it is a whole number. The formatter uses a
    /// `<0.1` bound for very small positive rates so that slow decoding is never reported as zero;
    /// the positive bound is valid evidence even though the exact sub-bound value is intentionally hidden.
    private func reportedDecodeThroughput(in stats: String) -> Double? {
        let suffix = " tok/s"
        guard let component = stats.components(separatedBy: " · ")
            .first(where: { $0.hasSuffix(suffix) }) else { return nil }

        var numericText = String(component.dropLast(suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if numericText.hasPrefix("<") {
            numericText.removeFirst()
        }
        guard let value = Double(numericText), value > 0 else { return nil }
        return value
    }

    /// Finish observing a turn that a test started manually (thinking-collapse, Stop, or a settings race).
    /// Callers capture the two baseline counts before tapping Send.
    @MainActor
    func waitForCommittedGeneration(model: DeviceTestModel,
                                    in app: XCUIApplication,
                                    previousCopyCount: Int,
                                    previousStatsCount: Int,
                                    startedAt: Date,
                                    timeout: TimeInterval? = nil,
                                    acceptedStops: [String] = ["eos", "stopSequence", "maxTokens"])
        throws -> GenerationEvidence {
        let agentRuntime = diagnosticValue("device-e2e.agent", in: app)
        XCTAssertTrue(
            agentRuntime.contains("enabled=true"),
            "manual generation must run on the agent runtime; diagnostics: \(agentRuntime)"
        )
        let statsQuery = app.descendants(matching: .any).matching(identifier: "assistant.stats")
        let deadline = Date().addingTimeInterval(timeout ?? model.generationTimeout)
        while Date() < deadline {
            if app.state != .runningForeground {
                throw DeviceE2EHarnessError.precondition("App left foreground during generation")
            }
            approvePendingAgentApprovalIfNeeded(in: app)
            if app.buttons.matching(identifier: "Copy answer").count > previousCopyCount,
               statsQuery.count > previousStatsCount,
               !app.buttons["Stop"].exists { break }
            let failure = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@ OR label == %@",
                            "Couldn't generate a reply", "The model didn't reply")
            ).firstMatch
            if failure.exists {
                Thread.sleep(forTimeInterval: 3)
                let finalDiagnostics = diagnosticValue("device-e2e.agent", in: app)
                attachDiagnostics(app, name: "manual-generation-failed")
                throw DeviceE2EHarnessError.precondition(
                    "Model committed an empty/failed reply; diagnostics: \(finalDiagnostics)"
                )
            }
            let agentDiagnostics = diagnosticValue("device-e2e.agent", in: app)
            if agentDiagnostics.contains("run=failed")
                || agentDiagnostics.contains("run=cancelled")
            {
                Thread.sleep(forTimeInterval: 3)
                let finalDiagnostics = diagnosticValue("device-e2e.agent", in: app)
                attachDiagnostics(app, name: "manual-agent-run-failed")
                throw DeviceE2EHarnessError.precondition(
                    "agent run failed during manual generation; diagnostics: \(finalDiagnostics)"
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard app.buttons.matching(identifier: "Copy answer").count > previousCopyCount,
              statsQuery.count > previousStatsCount else {
            attachDiagnostics(app, name: "manual-generation-timeout")
            throw DeviceE2EHarnessError.timeout("Manually observed generation did not commit")
        }
        let answers = app.descendants(matching: .any).matching(identifier: "assistant.answer")
            .allElementsBoundByIndex
        let statsElements = statsQuery.allElementsBoundByIndex
        guard let answerElement = answers.last, let statsElement = statsElements.last else {
            throw DeviceE2EHarnessError.precondition("Generation diagnostics are incomplete")
        }
        let answer = ((answerElement.value as? String) ?? answerElement.label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stats = (statsElement.value as? String) ?? statsElement.label
        let tools = app.descendants(matching: .any).matching(identifier: "assistant.tool.run")
            .allElementsBoundByIndex.map(\.label)
        let reasoningElement = app.descendants(matching: .any)
            .matching(identifier: "assistant.reasoning").allElementsBoundByIndex.last
        let reasoning = reasoningElement.flatMap { ($0.value as? String) ?? $0.label }
        let evidence = GenerationEvidence(answer: answer, stats: stats, toolActivities: tools,
                                          reasoning: reasoning,
                                          wallSeconds: Date().timeIntervalSince(startedAt))
        attachGenerationEvidence(evidence, app: app, name: model.modelID + "-manual")
        XCTAssertTrue(stats.hasPrefix(model.displayName + " ·"), "Wrong model in stats: \(stats)")
        XCTAssertTrue(acceptedStops.contains { stats.contains("stop: \($0)") },
                      "Unexpected stop reason: \(stats)")
        return evidence
    }

    @MainActor
    func configureTools(master: Bool,
                        enabled: Set<String>,
                        in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let choose = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Choose tools")
        ).firstMatch
        guard scrollToHittable(choose, in: app.scrollViews.firstMatch) else {
            throw DeviceE2EHarnessError.precondition("Choose tools row is not reachable")
        }
        choose.tap()
        guard app.navigationBars["Tools"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Tools settings did not open")
        }
        let scroll = firstHittableScrollView(in: app)
        let rows = ["Web search", "Webpage reader", "Wikipedia", "Calculator", "Clock", "Memory"]
        for title in rows {
            let toggle = switchStarting(with: title, in: app)
            guard scrollToHittable(toggle, in: scroll) else {
                throw DeviceE2EHarnessError.precondition("Tool toggle is unreachable: \(title)")
            }
            try setSwitch(toggle, on: enabled.contains(title))
        }
        let masterToggle = switchStarting(with: "Allow selected tools", in: app)
        guard scrollToHittable(masterToggle, in: scroll, swipingUp: false) else {
            throw DeviceE2EHarnessError.precondition("Tool master switch is unreachable")
        }
        try setSwitch(masterToggle, on: master)
        app.navigationBars["Tools"].buttons["Done"].tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Tools settings did not close")
        }
    }

    @MainActor
    func setThinkingDefault(_ enabled: Bool, in app: XCUIApplication) throws {
        try goToSettings(in: app)
        let toggle = switchStarting(with: "Thinking mode by default", in: app)
        guard scrollToHittable(toggle, in: app.scrollViews.firstMatch, swipingUp: false) else {
            throw DeviceE2EHarnessError.precondition("Thinking default toggle is unreachable")
        }
        try setSwitch(toggle, on: enabled)
    }

    @MainActor
    func goToSettings(in app: XCUIApplication) throws {
        try goToChatList(in: app)
        let tab = app.tabBars.buttons["Settings"]
        guard tab.waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Settings tab is unavailable")
        }
        tab.tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Settings did not open")
        }
    }

    @MainActor
    func reopenConversation(titled title: String, in app: XCUIApplication) throws {
        try goToChatList(in: app)
        let search = app.textFields["Search chats"]
        guard search.waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Chat search is unavailable")
        }
        search.tap()
        search.typeText(title)
        let row = app.buttons[title]
        guard row.waitForExistence(timeout: 15) else {
            throw DeviceE2EHarnessError.precondition("Conversation not found: \(title)")
        }
        row.tap()
        guard app.buttons["Active model"].waitForExistence(timeout: 20) else {
            throw DeviceE2EHarnessError.precondition("Conversation did not reopen: \(title)")
        }
    }

    @MainActor
    func uniqueMarker(_ suffix: String) -> String {
        let compact = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "E2E_\(suffix)_\(compact.prefix(8))"
    }

    /// Open the SwiftUI composer menu only after its anchor is actionable, then wait for a positive menu
    /// sentinel. Negative assertions made before this returns cannot distinguish "not offered" from "the
    /// menu never opened".
    @MainActor
    func openChatOptions(in app: XCUIApplication) throws {
        let anchor = app.buttons["Chat options"]
        guard waitForEnabled(anchor, timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Chat options is not actionable")
        }
        anchor.tap()
        guard freshMenuElement("Tools", in: app).waitForExistence(timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Chat options did not expose its Tools sentinel")
        }
    }

    /// Select the semantically neutral Skill -> None leaf to dismiss the menu. Re-tapping the obscured
    /// anchor produces an invalid hit point on iOS and is not a valid dismissal strategy.
    @MainActor
    func dismissChatOptionsSelectingNoSkill(in app: XCUIApplication) throws {
        let skill = freshMenuElement("Skill", in: app)
        guard skill.waitForExistence(timeout: 10), skill.isHittable else {
            throw DeviceE2EHarnessError.precondition("Skill submenu is unavailable for deterministic dismissal")
        }
        skill.tap()
        let none = freshMenuElement("None", in: app)
        guard none.waitForExistence(timeout: 10), none.isHittable else {
            throw DeviceE2EHarnessError.precondition("Skill -> None is unavailable for deterministic dismissal")
        }
        none.tap()
        guard waitForFreshMenuElementToDisappear("Tools", in: app, timeout: 10) else {
            throw DeviceE2EHarnessError.precondition("Chat options remained open after Skill -> None")
        }
    }

    /// A Toggle leaf usually dismisses its SwiftUI Menu on iPhone, but that behavior is not an API
    /// contract. Handle all observed outcomes without reusing the selected node or tapping coordinates:
    /// already dismissed; returned to the top-level menu; or still inside Tools.
    @MainActor
    func settleChatOptionsAfterToolSelection(in app: XCUIApplication) throws {
        let quickDeadline = Date().addingTimeInterval(2)
        while Date() < quickDeadline {
            if !freshMenuElement("Tools", in: app).exists,
               !freshMenuElement("Tool Settings…", in: app).exists {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let toolSettings = freshMenuElement("Tool Settings…", in: app)
        if toolSettings.exists, toolSettings.isHittable {
            toolSettings.tap()
            guard app.navigationBars["Tools"].waitForExistence(timeout: 10) else {
                throw DeviceE2EHarnessError.precondition("Tool Settings did not open while dismissing its menu")
            }
            let done = app.navigationBars["Tools"].buttons["Done"]
            guard done.waitForExistence(timeout: 10), done.isHittable else {
                throw DeviceE2EHarnessError.precondition("Tool Settings has no actionable Done button")
            }
            done.tap()
            guard app.navigationBars["Tools"].waitForNonExistence(timeout: 10) else {
                throw DeviceE2EHarnessError.precondition("Tool Settings did not dismiss")
            }
            return
        }

        if freshMenuElement("Tools", in: app).exists {
            try dismissChatOptionsSelectingNoSkill(in: app)
            return
        }
        throw DeviceE2EHarnessError.precondition("Chat options remained in an unknown menu state")
    }

    /// SwiftUI Menu rebuilds or removes its accessibility subtree after a selection. Always obtain a new
    /// XCUIElement for every post-tap observation; reading `value` from the pre-tap node can fail snapshot
    /// matching instead of returning a state.
    @MainActor
    func freshMenuElement(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    func waitForFreshMenuElementToDisappear(_ label: String,
                                            in app: XCUIApplication,
                                            timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !freshMenuElement(label, in: app).exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !freshMenuElement(label, in: app).exists
    }

    @MainActor
    func switchStarting(with label: String, in root: XCUIElement) -> XCUIElement {
        root.switches.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    @MainActor
    func setSwitch(_ element: XCUIElement, on: Bool) throws {
        guard element.exists, element.isHittable else {
            throw DeviceE2EHarnessError.precondition("Switch is not interactive: \(element.label)")
        }
        if switchIsOn(element) != on {
            element.tap()
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, switchIsOn(element) != on { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard switchIsOn(element) == on else {
            throw DeviceE2EHarnessError.precondition("Switch did not reach \(on): \(element.label)")
        }
    }

    @MainActor
    func switchIsOn(_ element: XCUIElement) -> Bool {
        if let value = element.value as? String { return value == "1" || value.lowercased() == "on" }
        if let value = element.value as? NSNumber { return value.boolValue }
        return false
    }

    @MainActor
    func firstHittableScrollView(in app: XCUIApplication) -> XCUIElement {
        app.scrollViews.allElementsBoundByIndex.first(where: \.isHittable) ?? app.scrollViews.firstMatch
    }

    @MainActor
    @discardableResult
    func scrollToHittable(_ element: XCUIElement,
                          in scroll: XCUIElement,
                          swipingUp: Bool = true,
                          attempts: Int = 12) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            if swipingUp { scroll.swipeUp() } else { scroll.swipeDown() }
        }
        // A previous helper may have left a long form at the opposite end. Search back once before
        // declaring a stable control missing; this avoids depending on scroll position between screens.
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            if swipingUp { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        return element.exists && element.isHittable
    }

    @MainActor
    func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.isEnabled, element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.exists && element.isEnabled && element.isHittable
    }

    /// The durable agent runtime pauses a network tool on first use in a conversation and presents an
    /// approval card (spec §15.2). Approve it when it appears; local tools never trigger this.
    @MainActor
    func approvePendingAgentApprovalIfNeeded(in app: XCUIApplication, timeout: TimeInterval = 60) {
        let approve = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Approve")
        ).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if approve.exists, approve.isHittable {
                approve.tap()
                let gone = Date().addingTimeInterval(10)
                while Date() < gone, approve.exists { Thread.sleep(forTimeInterval: 0.2) }
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    @MainActor
    func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !element.exists
    }

    @MainActor
    func waitForValue(of element: XCUIElement, equalTo expected: String,
                      timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (element.value as? String) == expected
    }

    @MainActor
    func waitForRuntime(_ fragment: String, in app: XCUIApplication,
                        timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if diagnosticValue("device-e2e.runtime", in: app).contains(fragment) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return diagnosticValue("device-e2e.runtime", in: app).contains(fragment)
    }

    @MainActor
    func waitForFixtureCount(_ count: Int, in app: XCUIApplication,
                             timeout: TimeInterval = 20) -> Bool {
        let expected = "pendingImages=\(count)"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if diagnosticValue("device-e2e.fixture", in: app) == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return diagnosticValue("device-e2e.fixture", in: app) == expected
    }

    @MainActor
    func attachGenerationEvidence(_ evidence: GenerationEvidence, app: XCUIApplication, name: String) {
        let text = """
        wall_seconds=\(String(format: "%.2f", evidence.wallSeconds))
        stats=\(evidence.stats)
        answer=\(evidence.answer)
        reasoning=\(evidence.reasoning ?? "<none>")
        tools=\(evidence.toolActivities.joined(separator: " | "))
        runtime=\(diagnosticValue("device-e2e.runtime", in: app))
        """
        let attachment = XCTAttachment(string: text)
        attachment.name = "generation-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "generation-\(name)-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func attachDiagnostics(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name + "-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
