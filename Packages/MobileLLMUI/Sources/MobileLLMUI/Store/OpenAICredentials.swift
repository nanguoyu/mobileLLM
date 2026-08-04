// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// Where the OpenAI Responses API key lives. The app stores it in the device Keychain (this-device-only,
/// off-backup, never in UserDefaults or the repo); tests and the debug launcher can seed it through a
/// launch-environment variable, which is never committed.
public protocol OpenAICredentialStoring: Sendable {
    func saveAPIKey(_ key: String) throws
    func loadAPIKey() throws -> String?
    func deleteAPIKey() throws
}

/// Keychain-backed store, scoped to its own service so it never collides with MCP bearer tokens.
public struct KeychainOpenAICredentialStore: OpenAICredentialStoring, Sendable {
    public static func defaultService(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "mobileLLM"
    ) -> String {
        "\(bundleIdentifier).openai"
    }

    private let box: KeychainBox
    private let account = "responses-api-key"

    public init(service: String = KeychainOpenAICredentialStore.defaultService()) {
        box = KeychainBox(service: service)
    }

    public func saveAPIKey(_ key: String) throws {
        try box.save(key, account: account)
    }

    public func loadAPIKey() throws -> String? {
        try box.readString(account: account)
    }

    public func deleteAPIKey() throws {
        try box.delete(account: account)
    }
}

/// In-memory store for unit tests, previews, and any environment that must never touch the device
/// Keychain.
public final class EphemeralOpenAICredentialStore: OpenAICredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init() {}

    public func saveAPIKey(_ key: String) throws {
        lock.withLock { self.key = key }
    }

    public func loadAPIKey() throws -> String? {
        lock.withLock { key }
    }

    public func deleteAPIKey() throws {
        lock.withLock { key = nil }
    }
}

/// Debug-only launch-environment seeding: when the test runner injects
/// `MOBILELLM_OPENAI_API_KEY`, the app stores it once so device UI tests never need the key typed by
/// hand and the repository never contains it. Release builds ignore the environment entirely.
public enum OpenAIKeyEnvironment {
    public static let variableName = "MOBILELLM_OPENAI_API_KEY"
    public static let baseURLVariableName = "MOBILELLM_OPENAI_BASE_URL"
    public static let modelVariableName = "MOBILELLM_OPENAI_MODEL"

    public static func seedIfPresent(
        store: any OpenAICredentialStoring,
        environment: [String: String]
    ) {
        #if DEBUG
        guard let key = environment[variableName], !key.isEmpty else { return }
        try? store.saveAPIKey(key)
        #endif
    }
}

/// Non-secret service configuration for the Responses API. The base URL may point at a gateway,
/// proxy, or self-hosted endpoint; it is persisted in Settings (unlike the key, which stays in the
/// Keychain). Only https is accepted.
public enum OpenAIServiceConfiguration {
    public static let defaultBaseURL = "https://api.openai.com/v1"

    public static func normalizedBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return trimmed
    }
}
