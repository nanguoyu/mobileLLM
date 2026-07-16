// SPDX-License-Identifier: MIT

import Foundation
import Security

/// A minimal generic-password Keychain store (A2.9): save / read / delete a small secret by account key.
///
/// Items are pinned to THIS device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) — never synced to
/// iCloud, and readable only after the first unlock following a boot. `service` scopes the items so
/// several boxes (or the test suite) don't collide on the same account name. No UI and no app dependency;
/// the Settings migration that moves secrets off `UserDefaults` wires this in a later wave.
public struct KeychainBox: Sendable {

    /// The `kSecAttrService` all this box's items share (e.g. a reverse-DNS app id).
    public let service: String

    public init(service: String) { self.service = service }

    /// A non-success Keychain status. `errSecItemNotFound` is modeled as `nil`/no-op, not an error.
    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Store `secret` for `account`, replacing any existing value.
    public func save(_ secret: Data, account: String) throws {
        // Delete any existing item first so the add can't fail with errSecDuplicateItem.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Convenience: store a UTF-8 string.
    public func save(_ string: String, account: String) throws {
        try save(Data(string.utf8), account: account)
    }

    /// The stored secret for `account`, or `nil` when there is none.
    public func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:      return item as? Data
        case errSecItemNotFound: return nil
        default:                 throw KeychainError.unexpectedStatus(status)
        }
    }

    /// The stored secret decoded as a UTF-8 string, or `nil` when absent / not valid UTF-8.
    public func readString(account: String) throws -> String? {
        try read(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Delete the stored secret for `account` (a no-op when there is none).
    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
