// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// Where the OpenAI Responses API key lives. The app stores it in the device Keychain (this-device-only,
/// off-backup, never in UserDefaults or the repo); tests and the debug launcher can seed it through a
/// launch-environment variable, which is never committed.
public protocol OpenAICredentialStoring: Sendable {
    /// Stores one service's key. `serviceID` is the OnlineService identity (also the Keychain account).
    func saveAPIKey(_ key: String, serviceID: String) throws
    func loadAPIKey(serviceID: String) throws -> String?
    func deleteAPIKey(serviceID: String) throws
}

/// Convenience for the legacy single-service surface (the Mac-local config / test env seeding and the
/// default service). Defaults to `OnlineService.defaultID`.
public extension OpenAICredentialStoring {
    func saveAPIKey(_ key: String) throws {
        try saveAPIKey(key, serviceID: OnlineService.defaultID)
    }

    func loadAPIKey() throws -> String? {
        try loadAPIKey(serviceID: OnlineService.defaultID)
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(serviceID: OnlineService.defaultID)
    }
}

/// Keychain-backed store, scoped to its own service so it never collides with MCP bearer tokens.
public struct KeychainOpenAICredentialStore: OpenAICredentialStoring, Sendable {
    public static func defaultService(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "mobileLLM"
    ) -> String {
        "\(bundleIdentifier).openai"
    }

    private let box: KeychainBox

    public init(service: String = KeychainOpenAICredentialStore.defaultService()) {
        box = KeychainBox(service: service)
    }

    public func saveAPIKey(_ key: String, serviceID: String) throws {
        try box.save(key, account: serviceID)
    }

    public func loadAPIKey(serviceID: String) throws -> String? {
        try box.readString(account: serviceID)
    }

    public func deleteAPIKey(serviceID: String) throws {
        try box.delete(account: serviceID)
    }
}

/// In-memory store for unit tests, previews, and any environment that must never touch the device
/// Keychain.
public final class EphemeralOpenAICredentialStore: OpenAICredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    public init() {}

    public func saveAPIKey(_ key: String, serviceID: String) throws {
        lock.withLock { keys[serviceID] = key }
    }

    public func loadAPIKey(serviceID: String) throws -> String? {
        lock.withLock { keys[serviceID] }
    }

    public func deleteAPIKey(serviceID: String) throws {
        lock.withLock { keys[serviceID] = nil }
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
