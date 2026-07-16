// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// `SystemModelStatus` is the app's framework-free vocabulary for FoundationModels' availability: the
/// SDK type is `@available(iOS 26, macOS 26)`, so this — not the framework enum — is what the install
/// probe and the Models card read, and it's the only part of the story that can be tested on any OS.
final class SystemModelStatusTests: XCTestCase {

    private let allReasons: [SystemModelStatus.Reason] =
        [.unsupportedOS, .deviceNotEligible, .notEnabled, .modelNotReady, .unknown]

    func testAvailabilityPredicates() {
        XCTAssertTrue(SystemModelStatus.available.isAvailable)
        XCTAssertNil(SystemModelStatus.available.unavailableReason)
        for reason in allReasons {
            let status = SystemModelStatus.unavailable(reason)
            XCTAssertFalse(status.isAvailable, "\(reason) is not available")
            XCTAssertEqual(status.unavailableReason, reason, "the real reason must survive, not be flattened")
        }
    }

    /// Every reason carries user-facing prose. The card shows this verbatim, so it must never leak an
    /// enum case name, and must never be empty (an empty explanation is how a dead button happens).
    func testEveryReasonHasUserFacingText() {
        for reason in allReasons {
            let message = reason.message
            XCTAssertFalse(message.isEmpty, "\(reason) needs a message")
            XCTAssertTrue(message.hasSuffix("."), "\(reason) should read as a sentence")
            XCTAssertFalse(message.contains("deviceNotEligible") || message.contains("modelNotReady")
                           || message.contains("unsupportedOS") || message.contains("notEnabled"),
                           "\(reason) must not dump its case name at the user")
        }
    }

    /// The two reasons the user can actually act on say what to do; the rest state the fact without
    /// implying a fix that doesn't exist. This is A4's "say exactly why" contract.
    func testMessagesNameTheRealReason() {
        XCTAssertTrue(SystemModelStatus.Reason.notEnabled.message.contains("Settings"),
                      "the fixable case must point at Settings")
        XCTAssertTrue(SystemModelStatus.Reason.modelNotReady.message.lowercased().contains("downloading"),
                      "a model still downloading should say so — it becomes available on its own")
        XCTAssertTrue(SystemModelStatus.Reason.deviceNotEligible.message.lowercased().contains("eligible"))
        // Ineligible hardware and an old OS are NOT user-fixable: they must not send the user to Settings.
        XCTAssertFalse(SystemModelStatus.Reason.deviceNotEligible.message.contains("Settings"))
        XCTAssertFalse(SystemModelStatus.Reason.unsupportedOS.message.contains("Settings"))
    }

    /// Distinct reasons must read differently — a shared "not available" string would defeat the point
    /// of naming the reason at all.
    func testMessagesAreDistinct() {
        let messages = Set(allReasons.map(\.message))
        XCTAssertEqual(messages.count, allReasons.count, "each reason needs its own wording")
    }
}
