// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

/// KeychainBox round-trip (A2.9). An unsigned `swift test` binary may be denied Keychain access on macOS;
/// when that happens the test SKIPS with an explicit reason rather than asserting a false success.
final class KeychainBoxTests: XCTestCase {

    /// Statuses that mean "this environment won't let us touch the Keychain" — a skip, not a failure.
    private static func isDenied(_ status: OSStatus) -> Bool {
        let denied: Set<OSStatus> = [errSecMissingEntitlement,   // -34018, unsigned CLI binary
                                     errSecNotAvailable,          // -25291, no keychain available
                                     errSecInteractionNotAllowed, // -25308
                                     errSecAuthFailed,            // -25293
                                     errSecParam]                 // -50, attribute rejected by this keychain
        return denied.contains(status)
    }

    func testSaveReadUpdateDelete() throws {
        let box = KeychainBox(service: "com.mobilellm.tests.\(UUID().uuidString)")
        let account = "unit-test-account"

        // The save is the first Keychain op; a denial here means skip the whole test.
        do {
            try box.save("s3cr3t-value", account: account)
        } catch let KeychainBox.KeychainError.unexpectedStatus(status) where Self.isDenied(status) {
            throw XCTSkip("Keychain access denied in this environment (OSStatus \(status)); skipping.")
        }
        addTeardownBlock { try? box.delete(account: account) }

        XCTAssertEqual(try box.readString(account: account), "s3cr3t-value")

        // Saving again replaces the value (no duplicate-item error).
        try box.save("updated-value", account: account)
        XCTAssertEqual(try box.readString(account: account), "updated-value")

        // Delete removes it; a subsequent read is nil, and a second delete is a no-op.
        try box.delete(account: account)
        XCTAssertNil(try box.read(account: account))
        XCTAssertNoThrow(try box.delete(account: account))
    }

    /// Reading an account that was never written returns nil (errSecItemNotFound is not an error).
    func testReadMissingIsNil() throws {
        let box = KeychainBox(service: "com.mobilellm.tests.\(UUID().uuidString)")
        do {
            XCTAssertNil(try box.read(account: "never-written"))
        } catch let KeychainBox.KeychainError.unexpectedStatus(status) where Self.isDenied(status) {
            throw XCTSkip("Keychain access denied in this environment (OSStatus \(status)); skipping.")
        }
    }

    /// Distinct services don't collide on the same account name.
    func testServicesAreIsolated() throws {
        let a = KeychainBox(service: "com.mobilellm.tests.a.\(UUID().uuidString)")
        let b = KeychainBox(service: "com.mobilellm.tests.b.\(UUID().uuidString)")
        let account = "shared-name"
        do {
            try a.save("from-a", account: account)
        } catch let KeychainBox.KeychainError.unexpectedStatus(status) where Self.isDenied(status) {
            throw XCTSkip("Keychain access denied in this environment (OSStatus \(status)); skipping.")
        }
        addTeardownBlock { try? a.delete(account: account); try? b.delete(account: account) }

        XCTAssertEqual(try a.readString(account: account), "from-a")
        XCTAssertNil(try b.read(account: account), "a different service must not see it")
    }
}
