// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// The OpenAI credential and service-configuration storage: Keychain-backed in the app, in-memory for
/// tests, launch-environment seeding in DEBUG, and https-only base URLs. The key must never appear in
/// UserDefaults or the repo.
final class OpenAICredentialsTests: XCTestCase {
    func testEphemeralStoreRoundTripAndDelete() throws {
        let store = EphemeralOpenAICredentialStore()
        XCTAssertNil(try store.loadAPIKey())
        try store.saveAPIKey("sk-test-123")
        XCTAssertEqual(try store.loadAPIKey(), "sk-test-123")
        try store.deleteAPIKey()
        XCTAssertNil(try store.loadAPIKey())
    }

    /// Keys are scoped per service: saving one service's key must never leak into another's account.
    func testPerServiceKeysAreIsolated() throws {
        let store = EphemeralOpenAICredentialStore()
        try store.saveAPIKey("sk-service-a", serviceID: "svc-a")
        try store.saveAPIKey("sk-service-b", serviceID: "svc-b")

        XCTAssertEqual(try store.loadAPIKey(serviceID: "svc-a"), "sk-service-a")
        XCTAssertEqual(try store.loadAPIKey(serviceID: "svc-b"), "sk-service-b")
        XCTAssertNil(try store.loadAPIKey(serviceID: "svc-c"))

        try store.deleteAPIKey(serviceID: "svc-a")
        XCTAssertNil(try store.loadAPIKey(serviceID: "svc-a"))
        XCTAssertEqual(try store.loadAPIKey(serviceID: "svc-b"), "sk-service-b")
    }

    func testEnvironmentSeedingOnlyWhenKeyPresent() throws {
        let store = EphemeralOpenAICredentialStore()
        OpenAIKeyEnvironment.seedIfPresent(store: store, environment: [:])
        XCTAssertNil(try store.loadAPIKey())

        OpenAIKeyEnvironment.seedIfPresent(store: store, environment: [
            OpenAIKeyEnvironment.variableName: "sk-env-secret",
        ])
        XCTAssertEqual(try store.loadAPIKey(), "sk-env-secret")

        OpenAIKeyEnvironment.seedIfPresent(store: store, environment: [
            OpenAIKeyEnvironment.variableName: "",
        ])
        XCTAssertEqual(try store.loadAPIKey(), "sk-env-secret",
                       "an empty env value must not overwrite an existing key")
    }

    func testBaseURLNormalizationAcceptsHTTPSOnly() {
        XCTAssertEqual(
            OpenAIServiceConfiguration.normalizedBaseURL("https://api.openai.com/v1"),
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            OpenAIServiceConfiguration.normalizedBaseURL("  https://gateway.example.com/custom  "),
            "https://gateway.example.com/custom"
        )
        XCTAssertNil(OpenAIServiceConfiguration.normalizedBaseURL("http://api.openai.com/v1"))
        XCTAssertNil(OpenAIServiceConfiguration.normalizedBaseURL("https://"))
        XCTAssertNil(OpenAIServiceConfiguration.normalizedBaseURL(""))
    }

    func testLocalConfigLoadAndEnvironmentOverrides() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-local-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        {"apiKey":"file-key","baseURL":"https://gateway.example.com/v1","model":"file-model"}
        """.utf8).write(to: url)

        var config = try OpenAILocalConfigLoader.load(from: url)
        XCTAssertEqual(config.apiKey, "file-key")
        XCTAssertEqual(config.baseURL, "https://gateway.example.com/v1")
        XCTAssertEqual(config.model, "file-model")

        OpenAILocalConfigLoader.applyEnvironment([
            OpenAIKeyEnvironment.variableName: "env-key",
            OpenAIKeyEnvironment.modelVariableName: "env-model",
        ], to: &config)
        XCTAssertEqual(config.apiKey, "env-key")
        XCTAssertEqual(config.model, "env-model")
        XCTAssertEqual(config.baseURL, "https://gateway.example.com/v1",
                       "an absent env base URL must keep the file value")

        OpenAILocalConfigLoader.applyEnvironment([
            OpenAIKeyEnvironment.baseURLVariableName: "http://insecure.example",
        ], to: &config)
        XCTAssertEqual(config.baseURL, "https://gateway.example.com/v1",
                       "invalid env base URLs must be ignored")
    }
}
