// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
import AgentRuntime
@testable import MobileLLMUI

/// The production outbox projector (spec §9.1/§33 gap 2): claims journal rows, applies them to the
/// conversation JSON idempotently, and acknowledges delivery. Failed rows stay leased for retry.
final class ConversationOutboxProjectorTests: XCTestCase {

    func testAcceptedUserMessageProjectsOnceAndIsIdempotent() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversationID = UUID()
        let conversation = Conversation(id: conversationID, modelID: "bonsai-8b", variantID: "mlx")
        try await store.save(conversation)

        let messageID = UUID()
        let payload = Data("hello from the journal".utf8)
        let outbox = FakeOutboxProvider()
        await outbox.seed([
            item(
                conversationID: conversationID,
                messageID: messageID,
                kind: .acceptedUserMessage,
                payload: payload
            )
        ])
        let projector = makeProjector(store: store, outbox: outbox, payloads: FakePayloadProvider(
            payloads: [artifactKey: payload]
        ))

        await projector.drain()
        let first = try await loadConversation(conversationID, from: store)
        XCTAssertEqual(first.messages.count, 1)
        XCTAssertEqual(first.messages[0].id, messageID)
        XCTAssertEqual(first.messages[0].answer, "hello from the journal")
        let delivered = await outbox.deliveredKeys()
        XCTAssertTrue(delivered.contains("user:1"))

        // A repeated row (crash between apply and ack, or a replay) must not duplicate the message.
        await outbox.seed([
            item(
                conversationID: conversationID,
                messageID: messageID,
                kind: .acceptedUserMessage,
                payload: payload
            )
        ])
        await projector.drain()
        let second = try await loadConversation(conversationID, from: store)
        XCTAssertEqual(second.messages.count, 1)
        let deliveredTwice = await outbox.deliveredKeys()
        XCTAssertTrue(deliveredTwice.filter { $0 == "user:1" }.count >= 2)
    }

    func testFinalAnswerFillsPlaceholderAndAcknowledges() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversationID = UUID()
        let assistantID = UUID()
        var conversation = Conversation(id: conversationID, modelID: "bonsai-8b", variantID: "mlx")
        conversation.messages.append(Message(id: assistantID, role: .assistant, answer: ""))
        try await store.save(conversation)

        let answerData = try JSONEncoder().encode(AgentAnswer(text: "the committed answer"))
        let outbox = FakeOutboxProvider()
        await outbox.seed([
            item(
                conversationID: conversationID,
                messageID: assistantID,
                kind: .finalAnswer,
                payload: answerData
            )
        ])
        let projector = makeProjector(store: store, outbox: outbox, payloads: FakePayloadProvider(
            payloads: [artifactKey: answerData]
        ))

        await projector.drain()
        let persisted = try await loadConversation(conversationID, from: store)
        XCTAssertEqual(persisted.messages.count, 1)
        XCTAssertEqual(persisted.messages[0].answer, "the committed answer")
        let delivered = await outbox.deliveredKeys()
        XCTAssertTrue(delivered.contains("final:1"))
    }

    func testFinalAnswerAppendsAssistantWhenPlaceholderMissing() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversationID = UUID()
        let userID = UUID()
        let assistantID = UUID()
        var conversation = Conversation(id: conversationID, modelID: "bonsai-8b", variantID: "mlx")
        conversation.messages.append(Message(id: userID, role: .user, answer: "question"))
        try await store.save(conversation)

        let answerData = try JSONEncoder().encode(AgentAnswer(text: "answer"))
        let outbox = FakeOutboxProvider()
        await outbox.seed([
            item(
                conversationID: conversationID,
                messageID: assistantID,
                kind: .finalAnswer,
                payload: answerData
            )
        ])
        let projector = makeProjector(store: store, outbox: outbox, payloads: FakePayloadProvider(
            payloads: [artifactKey: answerData]
        ))

        await projector.drain()
        let persisted = try await loadConversation(conversationID, from: store)
        XCTAssertEqual(persisted.messages.count, 2)
        guard let assistant = persisted.messages.last else {
            return XCTFail("missing assistant message")
        }
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.answer, "answer")
        XCTAssertEqual(assistant.parentID, userID)
    }

    func testFailedPayloadStaysLeasedAndRetriesAfterExpiry() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversationID = UUID()
        let conversation = Conversation(id: conversationID, modelID: "bonsai-8b", variantID: "mlx")
        try await store.save(conversation)

        let messageID = UUID()
        let payload = Data("recovered".utf8)
        let outbox = FakeOutboxProvider()
        await outbox.seed([
            item(
                conversationID: conversationID,
                messageID: messageID,
                kind: .acceptedUserMessage,
                payload: payload
            )
        ])
        // First drain: payload is missing → apply fails → row is NOT acknowledged.
        var payloads = FakePayloadProvider(payloads: [:])
        let projector = makeProjector(store: store, outbox: outbox, payloads: payloads)
        await projector.drain()
        let deliveredAfterFailure = await outbox.deliveredKeys()
        XCTAssertTrue(deliveredAfterFailure.isEmpty)
        let leasedAfterFailure = await outbox.leasedCount()
        XCTAssertEqual(leasedAfterFailure, 1)

        // Lease expires; a later drain retries and succeeds once the payload exists.
        await outbox.reclaimExpiredLeases()
        payloads = FakePayloadProvider(payloads: [artifactKey: payload])
        let retryProjector = makeProjector(store: store, outbox: outbox, payloads: payloads)
        await retryProjector.drain()
        let deliveredAfterRetry = await outbox.deliveredKeys()
        XCTAssertTrue(deliveredAfterRetry.contains("user:1"))
        let recovered = try await loadConversation(conversationID, from: store)
        XCTAssertEqual(recovered.messages.first?.answer, "recovered")
    }

    func testShouldProjectFalseAcknowledgesWithoutApplying() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversationID = UUID()
        let conversation = Conversation(id: conversationID, modelID: "bonsai-8b", variantID: "mlx")
        try await store.save(conversation)

        let payload = Data("workflow root answer".utf8)
        let outbox = FakeOutboxProvider()
        await outbox.seed([
            item(
                conversationID: conversationID,
                messageID: UUID(),
                kind: .finalAnswer,
                payload: payload
            )
        ])
        let projector = ConversationOutboxProjector(
            outbox: outbox,
            payloads: FakePayloadProvider(payloads: [artifactKey: payload]),
            store: store,
            shouldProject: { $0.kind == .finalAnswer ? false : true }
        )

        await projector.drain()
        let delivered = await outbox.deliveredKeys()
        XCTAssertTrue(delivered.contains("final:1"))
        let loaded = try await loadConversation(conversationID, from: store)
        XCTAssertTrue(loaded.messages.isEmpty)
    }

    func testDeleteConversationOutboxSoftDeletes() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let conversationID = UUID()
        let conversation = Conversation(id: conversationID, modelID: "bonsai-8b", variantID: "mlx")
        try await store.save(conversation)
        let indexBefore = await store.liveIndex()
        XCTAssertFalse(indexBefore.isEmpty)

        let outbox = FakeOutboxProvider()
        await outbox.seed([
            ProjectionOutboxItem(
                idempotencyKey: "delete:1",
                conversationID: ConversationID(rawValue: conversationID),
                runID: nil,
                messageID: nil,
                kind: .deleteConversation,
                payloadDigest: StableDigest.sha256(Data()),
                payloadArtifactID: nil
            )
        ])
        let projector = makeProjector(store: store, outbox: outbox, payloads: FakePayloadProvider(payloads: [:]))
        await projector.drain()
        let delivered = await outbox.deliveredKeys()
        XCTAssertTrue(delivered.contains("delete:1"))
        let indexAfter = await store.liveIndex()
        XCTAssertTrue(indexAfter.isEmpty)
    }

    // MARK: - Helpers

    private let artifactID = ArtifactID(
        rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )
    private var artifactKey: String { artifactID.description }

    private func item(
        conversationID: UUID,
        messageID: UUID,
        kind: ProjectionOutboxItem.Kind,
        payload: Data,
        idempotencyKey: String? = nil
    ) -> ProjectionOutboxItem {
        ProjectionOutboxItem(
            idempotencyKey: idempotencyKey
                ?? (kind == .acceptedUserMessage ? "user:1" : "final:1"),
            conversationID: ConversationID(rawValue: conversationID),
            runID: nil,
            messageID: MessageID(rawValue: messageID),
            kind: kind,
            payloadDigest: StableDigest.sha256(payload),
            payloadArtifactID: artifactID
        )
    }

    private func makeProjector(
        store: ConversationStore,
        outbox: FakeOutboxProvider,
        payloads: FakePayloadProvider
    ) -> ConversationOutboxProjector {
        ConversationOutboxProjector(outbox: outbox, payloads: payloads, store: store)
    }

    private func loadConversation(
        _ id: UUID,
        from store: ConversationStore
    ) async throws -> Conversation {
        let loaded = await store.load(id)
        return try XCTUnwrap(loaded)
    }

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-projector-\(UUID().uuidString)", isDirectory: true)
        return (ConversationStore(directory: dir), dir)
    }
}

/// In-memory outbox seam with claim → leased → delivered states and explicit lease expiry.
private actor FakeOutboxProvider: AgentOutboxProviding {
    private var pending: [ProjectionOutboxItem] = []
    private var leased: [ProjectionOutboxItem] = []
    private var delivered: [String] = []

    func seed(_ items: [ProjectionOutboxItem]) {
        pending = items
    }

    func deliveredKeys() -> [String] { delivered }

    func leasedCount() -> Int { leased.count }

    func reclaimExpiredLeases() {
        pending.append(contentsOf: leased)
        leased.removeAll()
    }

    func claimOutbox(
        owner: String,
        now: AgentTimestamp,
        leaseUntil: AgentTimestamp,
        limit: Int
    ) async throws -> OutboxClaim {
        let items = Array(pending.prefix(limit))
        pending.removeFirst(items.count)
        leased.append(contentsOf: items)
        return OutboxClaim(owner: owner, expiresAt: leaseUntil, items: items)
    }

    func markOutboxDelivered(
        idempotencyKey: String,
        owner: String,
        deliveredAt: AgentTimestamp
    ) async throws {
        leased.removeAll { $0.idempotencyKey == idempotencyKey }
        delivered.append(idempotencyKey)
    }
}

private struct FakePayloadProvider: AgentOutboxPayloadLoading {
    var payloads: [String: Data]

    func loadOutboxPayload(artifactID: ArtifactID, maximumBytes: UInt64) async throws -> Data {
        guard let data = payloads[artifactID.description] else {
            throw ConversationOutboxProjectorError.payloadMissing
        }
        return data
    }
}
