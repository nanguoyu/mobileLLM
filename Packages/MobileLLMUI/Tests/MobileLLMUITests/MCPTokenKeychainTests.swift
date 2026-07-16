// SPDX-License-Identifier: MIT

import XCTest
import Security
import AppRuntime
@testable import MobileLLMUI
import LLMCore

/// MCP bearer tokens migrate off plaintext UserDefaults into the Keychain (B2.d / A2.9). An unsigned
/// `swift test` binary may be denied Keychain access on macOS; those tests SKIP (as KeychainBoxTests do)
/// rather than asserting a false result.
@MainActor
final class MCPTokenKeychainTests: XCTestCase {

    private let key = "mobileLLM.settings.v1"
    private var suite: String!
    private var defaults: UserDefaults!
    private var service: String!
    private var keychain: KeychainBox!

    override func setUp() {
        super.setUp()
        suite = "MCPTokenKeychainTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        service = "com.mobilellm.tests.mcp.\(UUID().uuidString)"
        keychain = KeychainBox(service: service)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Probe the Keychain once; a denial means the whole test can't run here → skip.
    private func requireKeychain() throws {
        let probe = "probe"
        do {
            try keychain.save("x", account: probe)
            try keychain.delete(account: probe)
        } catch let KeychainBox.KeychainError.unexpectedStatus(status) {
            throw XCTSkip("Keychain access denied in this environment (OSStatus \(status)); skipping.")
        }
    }

    private func write(_ json: String) { defaults.set(Data(json.utf8), forKey: key) }
    private func rawSnapshot() -> String { String(data: defaults.data(forKey: key) ?? Data(), encoding: .utf8) ?? "" }

    /// A legacy snapshot with an inline plaintext token: on load it moves into the Keychain, stays in
    /// memory (so MCPClient still works), and is scrubbed from the re-persisted UserDefaults snapshot.
    func testMigratesPlaintextTokenToKeychainAndScrubs() throws {
        try requireKeychain()
        let url = "https://mcp.example.com/mcp"
        addTeardownBlock { [keychain] in try? keychain?.delete(account: url) }
        write(#"""
        {"defaultModelID":"bonsai-8b","systemPrompt":"x","systemPromptSeeded":true,
         "thinkingDefault":true,"thinkingDisplay":"autoCollapse","toolsEnabled":true,
         "mcpServers":[{"name":"DeepWiki","url":"https://mcp.example.com/mcp","token":"secret-123"}],
         "temperature":0.7,"topP":0.95,"topK":20,"repetitionPenalty":1.05,"maxTokens":1024,
         "contextLength":8192,"kvBits":4,"appearance":"system"}
        """#)
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        XCTAssertEqual(settings.mcpServers.first?.token, "secret-123", "token preserved in memory")
        XCTAssertEqual(try keychain.readString(account: url), "secret-123", "moved into the Keychain")
        XCTAssertFalse(rawSnapshot().contains("secret-123"), "plaintext token scrubbed from UserDefaults")
    }

    /// A token added at runtime goes to the Keychain, never UserDefaults, and rehydrates on reload.
    func testNewTokenGoesToKeychainAndRehydrates() throws {
        try requireKeychain()
        let url = "https://s.example.com/mcp"
        addTeardownBlock { [keychain] in try? keychain?.delete(account: url) }
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        settings.mcpServers = [MCPServer(name: "S", url: url, token: "tok-abc")]
        XCTAssertEqual(try keychain.readString(account: url), "tok-abc")
        XCTAssertFalse(rawSnapshot().contains("tok-abc"), "never written to UserDefaults")

        let reloaded = AppSettings(defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.mcpServers.first?.token, "tok-abc", "rehydrated from the Keychain")
    }

    /// Removing a server deletes its Keychain secret.
    func testRemovingServerDeletesToken() throws {
        try requireKeychain()
        let url = "https://gone.example.com/mcp"
        addTeardownBlock { [keychain] in try? keychain?.delete(account: url) }
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        settings.mcpServers = [MCPServer(name: "G", url: url, token: "tok-gone")]
        XCTAssertEqual(try keychain.readString(account: url), "tok-gone")
        settings.mcpServers = []
        XCTAssertNil(try keychain.readString(account: url), "token deleted with the server")
    }

    /// A snapshot without a token isn't corrupted by the migration (and no Keychain read is forced).
    func testTokenlessServerSurvivesUntouched() throws {
        write(#"""
        {"defaultModelID":"bonsai-8b","systemPrompt":"keep","systemPromptSeeded":true,
         "thinkingDefault":true,"thinkingDisplay":"autoCollapse","toolsEnabled":true,
         "mcpServers":[{"name":"NoTok","url":"https://n.example.com/mcp"}],
         "temperature":0.7,"topP":0.95,"topK":20,"repetitionPenalty":1.05,"maxTokens":1024,
         "contextLength":8192,"kvBits":4,"appearance":"system"}
        """#)
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        XCTAssertEqual(settings.mcpServers.count, 1)
        XCTAssertNil(settings.mcpServers.first?.token)
    }
}
