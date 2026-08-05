// SPDX-License-Identifier: MIT

import Foundation

/// One configured OpenAI-compatible online service (Responses API). Multiple services are supported:
/// each keeps its own base URL, model id, and Keychain key, and at most one is enabled as the active
/// online model for sends.
public struct OnlineService: Sendable, Hashable, Codable, Identifiable {
    /// Stable identity for the Keychain account and agent-approval destination. NEVER derived from the
    /// mutable base URL: editing a service's address must not re-scope previously approved operations.
    public let id: String
    /// Display name shown in the switcher and settings list.
    public var name: String
    public var baseURL: String
    public var modelID: String?
    /// True = this service is the active online model. The settings layer keeps at most one enabled.
    public var isEnabled: Bool

    /// The id used by the single-service era (and by the Mac-local config / test env seeding). Keeping
    /// it lets an upgraded install reuse the key already stored under this Keychain account.
    public static let defaultID = "responses-api-key"

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        modelID: String? = nil,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelID = modelID
        self.isEnabled = isEnabled
    }

    /// A copy with the enabled flag replaced.
    public func withEnabled(_ enabled: Bool) -> OnlineService {
        var copy = self
        copy.isEnabled = enabled
        return copy
    }

    /// Non-secret summary used by the settings list.
    public var summary: String {
        let key = modelID ?? "service default"
        return "\(key) · \(baseURL)"
    }
}
