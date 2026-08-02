// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
import AgentContracts
import AgentRuntime

/// `ConversationStore` round-trip + index consistency + soft-delete + search (DESIGN §2.4).
// TEST-ID: AHT-SELECT-001
final class ConversationStoreTests: XCTestCase {

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-tests-\(UUID().uuidString)")
        return (ConversationStore(directory: dir), dir)
    }

    private func makeConversation(title: String, body: String) -> Conversation {
        Conversation(title: title, modelID: "bonsai-8b", variantID: "prism-ml/Bonsai-8B-mlx-1bit",
                     messages: [
                        Message(role: .user, answer: body),
                        Message(role: .assistant, answer: "reply about \(body)", reasoning: "thinking"),
                     ])
    }

    func testRoundTrip() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let convo = makeConversation(title: "Weather", body: "how's the weather")
        try await store.save(convo)

        let loaded = await store.load(convo.id)
        XCTAssertEqual(loaded, convo)

        let live = await store.loadAllLive()
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.id, convo.id)
    }

    func testConversationToolPolicyPersistsAcrossReload() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calculator = try AgentToolLogicalID(providerID: "builtin", name: "calculator")
        let policy = try ConversationToolPolicy(
            masterEnabled: true,
            allowedToolIDs: [calculator],
            pinnedToolIDs: [calculator],
            selectionPolicyVersion: 1,
            materializedFromGlobalTemplate: true
        )
        var convo = makeConversation(title: "Policy", body: "tools")
        convo.toolPolicy = policy
        try await store.save(convo)

        let loadedValue = await store.load(convo.id)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.toolPolicy, policy)
        XCTAssertTrue(loaded.toolPolicy?.materializedFromGlobalTemplate == true)

        // Legacy records without the key decode as nil and stay readable (spec §26).
        var legacy = makeConversation(title: "Legacy", body: "pre-agent")
        legacy.toolPolicy = nil
        try await store.save(legacy)
        let legacyValue = await store.load(legacy.id)
        let legacyLoaded = try XCTUnwrap(legacyValue)
        XCTAssertNil(legacyLoaded.toolPolicy)
    }

    func testIndexConsistency() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var convo = makeConversation(title: "First", body: "one")
        try await store.save(convo)

        // Update title + append a message; the index entry must reflect it after re-save.
        convo.title = "Renamed"
        convo.messages.append(Message(role: .user, answer: "two"))
        convo.updatedAt = Date().addingTimeInterval(10)
        try await store.save(convo)

        let index = await store.liveIndex()
        XCTAssertEqual(index.count, 1, "re-saving the same id must not duplicate the index entry")
        XCTAssertEqual(index.first?.title, "Renamed")
        XCTAssertEqual(index.first?.messageCount, convo.messages.count)
    }

    func testConcurrentSavesDoNotOverwriteEachOthersIndexEntries() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversations = (0..<24).map {
            makeConversation(title: "Concurrent \($0)", body: "body \($0)")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for conversation in conversations {
                group.addTask { try await store.save(conversation) }
            }
            try await group.waitForAll()
        }

        let index = await store.liveIndex()
        XCTAssertEqual(Set(index.map(\.id)), Set(conversations.map(\.id)),
                       "record + index read-modify-write operations must be one serialized transaction")
    }

    func testSoftDeleteAndRestore() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let convo = makeConversation(title: "Trash me", body: "temp")
        try await store.save(convo)

        try await store.softDelete(convo.id)
        let liveAfterDelete = await store.liveIndex()
        XCTAssertTrue(liveAfterDelete.isEmpty, "soft-deleted thread is hidden from the live index")
        // The full record is preserved (undo is possible).
        let preservedRecord = await store.load(convo.id)
        XCTAssertNotNil(preservedRecord, "soft-delete keeps the file")

        try await store.restore(convo.id)
        let liveAfterRestore = await store.liveIndex()
        XCTAssertEqual(liveAfterRestore.count, 1, "restore clears the tombstone")
    }

    func testSearchTitlesAndBodies() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await store.save(makeConversation(title: "Groceries", body: "buy milk"))
        try await store.save(makeConversation(title: "Trip plan", body: "flight to Osaka"))

        let byTitle = await store.search("grocer")
        XCTAssertEqual(byTitle.count, 1)
        XCTAssertEqual(byTitle.first?.title, "Groceries")

        let byBody = await store.search("osaka")
        XCTAssertEqual(byBody.count, 1)
        XCTAssertEqual(byBody.first?.title, "Trip plan")

        let noHit = await store.search("zzzz")
        XCTAssertTrue(noHit.isEmpty)

        let emptyQuery = await store.search("   ")
        XCTAssertEqual(emptyQuery.count, 2, "empty query returns the full live index")
    }

    func testSweepRemovesOnlyExpiredTombstones() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let deletedA = makeConversation(title: "Old A", body: "a")
        let deletedB = makeConversation(title: "Old B", body: "b")
        let liveOne = makeConversation(title: "Keep", body: "keep")
        try await store.save(deletedA)
        try await store.save(deletedB)
        try await store.save(liveOne)
        try await store.softDelete(deletedA.id)   // tombstoned ≈ now
        try await store.softDelete(deletedB.id)

        // Sweep as if 48h have passed: only tombstones older than the 24h window go; a live thread never does.
        let future = Date().addingTimeInterval(48 * 60 * 60)
        let swept = await store.sweepExpiredTombstones(olderThan: 24 * 60 * 60, now: future)
        XCTAssertEqual(Set(swept), Set([deletedA.id, deletedB.id]))
        let loadedA = await store.load(deletedA.id)
        let loadedB = await store.load(deletedB.id)
        let loadedLive = await store.load(liveOne.id)
        XCTAssertNil(loadedA, "expired tombstone's file is purged")
        XCTAssertNil(loadedB)
        XCTAssertNotNil(loadedLive, "a live conversation is never swept")

        // A recent tombstone survives a present-time sweep (still undoable).
        let recent = makeConversation(title: "Recent", body: "r")
        try await store.save(recent)
        try await store.softDelete(recent.id)
        let sweptNow = await store.sweepExpiredTombstones(olderThan: 24 * 60 * 60, now: Date())
        let loadedRecent = await store.load(recent.id)
        XCTAssertTrue(sweptNow.isEmpty, "a fresh tombstone is kept")
        XCTAssertNotNil(loadedRecent)
    }

    func testHardDeleteRemovesFile() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let convo = makeConversation(title: "Gone", body: "bye")
        try await store.save(convo)
        try await store.hardDelete(convo.id)
        let gone = await store.load(convo.id)
        XCTAssertNil(gone)
        let live = await store.liveIndex()
        XCTAssertTrue(live.isEmpty)
    }
}
