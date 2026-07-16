// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
import LLMCore

/// Settings persistence across app versions, plus the context clamp. Both are places where a quiet
/// regression doesn't crash — it just silently changes what the user configured.
@MainActor
final class SettingsPersistenceTests: XCTestCase {

    private var defaults: UserDefaults!
    private let key = "mobileLLM.settings.v1"
    private let suite = "SettingsPersistenceTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func write(_ json: String) { defaults.set(Data(json.utf8), forKey: key) }

    // MARK: System prompt

    func testFreshInstallStartsWithTheStockPrompt() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(SystemPrompt.isStandard(settings.systemPrompt))
    }

    /// A v1 install has `systemPrompt: ""` and no seed marker — it should get the stock prompt once.
    func testSeedsTheStockPromptIntoAPreExistingInstall() {
        write(#"""
        {"defaultModelID":"bonsai-8b","systemPrompt":"","thinkingDefault":true,
         "thinkingDisplay":"autoCollapse","temperature":0.7,"topP":0.95,"topK":20,
         "repetitionPenalty":1.05,"maxTokens":1024,"contextLength":8192,"kvBits":4,
         "appearance":"system"}
        """#)
        XCTAssertTrue(SystemPrompt.isStandard(AppSettings(defaults: defaults).systemPrompt))
    }

    /// …but exactly once. Clearing the prompt on purpose must survive a relaunch, or the seed is a bug.
    func testDoesNotResurrectAPromptTheUserCleared() {
        let settings = AppSettings(defaults: defaults)
        settings.systemPrompt = ""                      // deliberate clear → persists with the seed marker
        XCTAssertEqual(AppSettings(defaults: defaults).systemPrompt, "")
    }

    func testKeepsACustomPrompt() {
        let settings = AppSettings(defaults: defaults)
        settings.systemPrompt = "Answer only in haiku."
        XCTAssertEqual(AppSettings(defaults: defaults).systemPrompt, "Answer only in haiku.")
    }

    // MARK: MCP back-compat (through the whole snapshot)

    /// `MCPServer` grew fields after v1. Decoding is all-or-nothing inside the snapshot, so a server
    /// written by the old build must not take temperature/model/appearance down with it.
    func testOldMCPServerEntryDoesNotDestroyEveryOtherSetting() {
        write(#"""
        {"defaultModelID":"qwen35-9b","systemPrompt":"keep me","thinkingDefault":false,
         "thinkingDisplay":"autoCollapse","toolsEnabled":true,
         "mcpServers":[{"name":"DeepWiki","url":"https://mcp.deepwiki.com/mcp"}],
         "temperature":0.42,"topP":0.95,"topK":20,"repetitionPenalty":1.05,"maxTokens":1024,
         "contextLength":16384,"kvBits":4,"appearance":"dark"}
        """#)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.temperature, 0.42, accuracy: 0.001)
        XCTAssertEqual(settings.defaultModelID, "qwen35-9b")
        XCTAssertEqual(settings.systemPrompt, "keep me")
        XCTAssertEqual(settings.mcpServers.count, 1)
        XCTAssertTrue(settings.mcpServers.first?.isEnabled ?? false)
    }

    // MARK: Context clamp

    func testSamplingClampsContextToTheModelsNativeCeiling() {
        let settings = AppSettings(defaults: defaults)
        settings.contextLength = 32_768
        // No model → the raw request (nothing to clamp against).
        XCTAssertEqual(settings.sampling(thinking: false).contextTokenCap, 32_768)
        // A model that supports it → unchanged.
        let big = LLMCatalog.bonsai8b
        XCTAssertEqual(settings.sampling(thinking: false, model: big).contextTokenCap,
                       min(32_768, big.architecture.nativeContext))
    }
}
