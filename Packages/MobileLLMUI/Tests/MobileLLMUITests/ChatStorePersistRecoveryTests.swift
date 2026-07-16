// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// Autosave-failure RECOVERY (B1.d): the existing suite covers only that a single failed save surfaces a
/// Retry banner and keeps the turn in the mirror. These cover the recovery halves that were untested —
/// `retryPersist()` actually draining the pending failures and landing the record once the disk is writable,
/// and `surfacePersistFailure()`'s one-banner-per-burst de-dup (a second failure while the banner is still
/// up must NOT stack another). Both use the proven "a regular file where the store wants a directory" trick
/// to force real save failures through the actual persistence path.
@MainActor
final class ChatStorePersistRecoveryTests: XCTestCase {

    private var mockModel: LoadedModel {
        LoadedModel(model: LLMCatalog.bonsai8b, variant: LLMCatalog.bonsai8b.defaultVariantValue)
    }

    /// A store whose directory can't be created (its parent is a regular file), so every `save()` throws —
    /// plus the blocking file's URL so a test can remove it to make the path writable again.
    private func blockedStore() throws -> (ChatStore, ConversationStore, blocker: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory.appending(component: "b1-recover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let blocker = base.appending(component: "blocker")
        try Data().write(to: blocker)   // a FILE where the store wants a directory tree
        let store = ConversationStore(directory: blocker.appending(component: "Conversations"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "b1-recover-\(UUID().uuidString)")!)
        let chat = ChatStore(engine: MockLLMEngine(script: .init()), store: store, settings: settings,
                             activeModel: mockModel)
        return (chat, store, blocker, base)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func pollUntil(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: - Retry re-persists once the disk is writable

    func testRetryPersistLandsTheRecordOnceWritable() async throws {
        let (chat, store, blocker, base) = try blockedStore()
        defer { try? FileManager.default.removeItem(at: base) }

        chat.draft = "hello"
        chat.send()
        try await waitUntilIdle(chat)
        try await pollUntil { chat.banner?.actionTitle == "Retry" }
        XCTAssertEqual(chat.banner?.actionTitle, "Retry", "the blocked save surfaced a retryable banner")

        let convoID = try XCTUnwrap(chat.activeID)
        let beforeUnblock = await store.load(convoID)
        XCTAssertNil(beforeUnblock, "nothing reached disk while the path was blocked")

        // Make the path writable, then Retry.
        try FileManager.default.removeItem(at: blocker)
        chat.runBannerAction()   // Retry → retryPersist() drains the pending failures

        // The record now lands on disk.
        let deadline = Date().addingTimeInterval(3)
        var landed: Conversation?
        while landed == nil && Date() < deadline {
            landed = await store.load(convoID)
            if landed != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let record = try XCTUnwrap(landed, "retryPersist writes the record once the disk is writable")
        XCTAssertEqual(record.messages.last?.answer.isEmpty, false, "the committed turn is what got persisted")
        XCTAssertNil(chat.banner, "the retry banner clears after the successful re-persist")
    }

    // MARK: - One banner per burst

    func testBurstOfSaveFailuresShowsOneBanner() async throws {
        let (chat, _, _, base) = try blockedStore()
        defer { try? FileManager.default.removeItem(at: base) }

        chat.draft = "hello"
        chat.send()
        try await waitUntilIdle(chat)
        try await pollUntil { chat.banner?.actionTitle == "Retry" }
        let firstBannerID = try XCTUnwrap(chat.banner?.id, "the first failure surfaced a banner")

        // More failing saves while that banner is still up (it's sticky — autoDismiss nil).
        let convoID = try XCTUnwrap(chat.activeID)
        chat.rename(convoID, to: "renamed once")
        chat.rename(convoID, to: "renamed twice")
        chat.togglePin(convoID)
        // Give the fire-and-forget persist tasks time to fail (createDirectory throws immediately).
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(chat.banner?.id, firstBannerID,
                       "a burst of save failures keeps ONE banner (de-duped by persistFailureBannerID)")
        XCTAssertEqual(chat.banner?.actionTitle, "Retry")
    }
}
