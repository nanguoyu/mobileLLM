// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// `ConversationStore` attachment persistence (C2.2): image bytes live as FILES beside the records
/// (never inline in the JSON), and a hard-delete / delete-all purges them with the thread — the privacy
/// promise.
final class AttachmentStoreTests: XCTestCase {

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-attach-tests-\(UUID().uuidString)")
        return (ConversationStore(directory: dir), dir)
    }

    func testAttachmentWriteReadRoundTrip() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ref = ImageRef()
        let bytes = makeTestImageData(width: 400, height: 300)
        try await store.writeAttachment(bytes, id: ref.id)
        let readBack = await store.attachmentData(ref.id)
        XCTAssertEqual(readBack, bytes, "written bytes read back verbatim")
        let unknown = await store.attachmentData(UUID())
        XCTAssertNil(unknown, "an unknown id has no bytes")
    }

    func testConversationRecordDoesNotInlineImageBytes() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ref = ImageRef()
        let bytes = makeTestImageData(width: 1200, height: 900)   // a chunky image
        try await store.writeAttachment(bytes, id: ref.id)
        let convo = Conversation(modelID: "m", variantID: "v",
                                 messages: [Message(role: .user, answer: "hi", attachments: [ref])])
        try await store.save(convo)

        // The record round-trips its refs …
        let loaded = await store.load(convo.id)
        XCTAssertEqual(loaded?.messages.first?.attachments, [ref])   // `loaded` is a plain local, not awaited here
        // … but the JSON record stays tiny — the image bytes are NOT inlined into it.
        let recordURL = dir.appending(component: "conversation-\(convo.id.uuidString).json")
        let recordBytes = (try? Data(contentsOf: recordURL))?.count ?? 0
        XCTAssertGreaterThan(bytes.count, 10_000, "the image is genuinely large")
        XCTAssertLessThan(recordBytes, 4_000, "the conversation JSON never carries the pixels")
    }

    func testHardDeletePurgesAttachmentFiles() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ref = ImageRef()
        try await store.writeAttachment(makeTestImageData(), id: ref.id)
        let convo = Conversation(modelID: "m", variantID: "v",
                                 messages: [Message(role: .user, answer: "x", attachments: [ref])])
        try await store.save(convo)
        let beforeDelete = await store.attachmentData(ref.id)
        XCTAssertNotNil(beforeDelete)

        try await store.hardDelete(convo.id)
        let goneRecord = await store.load(convo.id)
        XCTAssertNil(goneRecord, "the record is gone")
        let gonePixels = await store.attachmentData(ref.id)
        XCTAssertNil(gonePixels, "and its attachment pixels are purged")
    }

    func testDeleteAllPurgesAttachments() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ref = ImageRef()
        try await store.writeAttachment(makeTestImageData(), id: ref.id)
        let convo = Conversation(modelID: "m", variantID: "v",
                                 messages: [Message(role: .user, answer: "x", attachments: [ref])])
        try await store.save(convo)

        try await store.deleteAll()
        let purged = await store.attachmentData(ref.id)
        XCTAssertNil(purged, "delete-all leaves no attachment pixels behind")
    }

    func testStorageBytesCountsAttachments() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let convo = Conversation(modelID: "m", variantID: "v",
                                 messages: [Message(role: .user, answer: "hi")])
        try await store.save(convo)
        let beforeBytes = await store.storageBytes()

        let ref = ImageRef()
        try await store.writeAttachment(makeTestImageData(width: 1000, height: 800), id: ref.id)
        let afterBytes = await store.storageBytes()
        XCTAssertGreaterThan(afterBytes, beforeBytes, "the storage total includes attachment files")
    }
}
