// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import LLMCore

/// Durable projection outbox seam consumed by `ConversationOutboxProjector`.
public protocol AgentOutboxProviding: Sendable {
    func claimOutbox(
        owner: String,
        now: AgentTimestamp,
        leaseUntil: AgentTimestamp,
        limit: Int
    ) async throws -> OutboxClaim

    func markOutboxDelivered(
        idempotencyKey: String,
        owner: String,
        deliveredAt: AgentTimestamp
    ) async throws
}

/// Loads one outbox payload body by its content-addressed artifact id.
public protocol AgentOutboxPayloadLoading: Sendable {
    func loadOutboxPayload(artifactID: ArtifactID, maximumBytes: UInt64) async throws -> Data
}

public enum ConversationOutboxProjectorError: Error, Equatable, Sendable {
    case conversationMissing
    case payloadMissing
    case invalidPayload(String)
    case invalidMessageID
}

/// Production outbox projector (spec §9.1, §33 gap 2): claims `acceptedUserMessage` /
/// `finalAnswer` / `deleteConversation` rows written atomically with the journal, applies them to the
/// conversation JSON idempotently, and acknowledges delivery. A failed apply leaves the row leased so
/// a later drain retries it after the lease expires; the journal, never the JSON, is the source of
/// truth.
public final class ConversationOutboxProjector: Sendable {
    public let owner: String
    private let outbox: any AgentOutboxProviding
    private let payloads: any AgentOutboxPayloadLoading
    private let store: ConversationStore
    private let clock: @Sendable () throws -> AgentTimestamp
    private let leaseMilliseconds: Int64
    private let shouldProject: @Sendable (ProjectionOutboxItem) async throws -> Bool

    public init(
        outbox: any AgentOutboxProviding,
        payloads: any AgentOutboxPayloadLoading,
        store: ConversationStore,
        owner: String = "conversation-projector",
        clock: @escaping @Sendable () throws -> AgentTimestamp = { try AgentTimestamp(Date()) },
        leaseMilliseconds: Int64 = 60_000,
        shouldProject: @escaping @Sendable (ProjectionOutboxItem) async throws -> Bool = { _ in true }
    ) {
        self.outbox = outbox
        self.payloads = payloads
        self.store = store
        self.owner = owner
        self.clock = clock
        self.leaseMilliseconds = max(1_000, leaseMilliseconds)
        self.shouldProject = shouldProject
    }

    /// One claim → apply → acknowledge pass. Never throws: an unavailable journal or a failing item
    /// simply remains pending for the next drain.
    public func drain(limit: Int = 32) async {
        let now: AgentTimestamp
        do {
            now = try clock()
        } catch {
            return
        }
        let claim: OutboxClaim
        do {
            claim = try await outbox.claimOutbox(
                owner: owner,
                now: now,
                leaseUntil: AgentTimestamp(rawValue: now.rawValue + leaseMilliseconds),
                limit: limit
            )
        } catch {
            return
        }
        for item in claim.items {
            do {
                guard try await shouldProject(item) else {
                    // Consumed by another projection path (e.g. workflow summaries own their root and
                    // child final answers); acknowledge so the row is not retried forever.
                    try await outbox.markOutboxDelivered(
                        idempotencyKey: item.idempotencyKey,
                        owner: owner,
                        deliveredAt: try clock()
                    )
                    continue
                }
                try await apply(item)
                try await outbox.markOutboxDelivered(
                    idempotencyKey: item.idempotencyKey,
                    owner: owner,
                    deliveredAt: try clock()
                )
            } catch {
                // The lease expires and a later drain retries. A genuinely bad row (e.g. corrupted
                // payload) must not block the rest of the batch.
                continue
            }
        }
    }

    private func apply(_ item: ProjectionOutboxItem) async throws {
        switch item.kind {
        case .acceptedUserMessage:
            try await applyAcceptedUserMessage(item)
        case .finalAnswer:
            try await applyFinalAnswer(item)
        case .deleteConversation:
            try await store.softDelete(item.conversationID.rawValue)
        }
    }

    private func applyAcceptedUserMessage(_ item: ProjectionOutboxItem) async throws {
        guard let messageID = item.messageID, let artifactID = item.payloadArtifactID else {
            throw ConversationOutboxProjectorError.payloadMissing
        }
        // Never resurrect a deleted conversation from a stale row; the app owns creation.
        guard var conversation = await store.load(item.conversationID.rawValue) else {
            throw ConversationOutboxProjectorError.conversationMissing
        }
        guard !conversation.messages.contains(where: { $0.id == messageID.rawValue }) else {
            return  // already projected (live compatibility path) — acknowledge idempotently
        }
        let data = try await payloads.loadOutboxPayload(
            artifactID: artifactID,
            maximumBytes: 1 * 1_024 * 1_024
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConversationOutboxProjectorError.invalidPayload("user message is not UTF-8 text")
        }
        conversation.messages.append(
            Message(id: messageID.rawValue, role: .user, answer: text)
        )
        conversation.updatedAt = Date()
        try await store.save(conversation)
    }

    private func applyFinalAnswer(_ item: ProjectionOutboxItem) async throws {
        guard let messageID = item.messageID, let artifactID = item.payloadArtifactID else {
            throw ConversationOutboxProjectorError.payloadMissing
        }
        guard var conversation = await store.load(item.conversationID.rawValue) else {
            throw ConversationOutboxProjectorError.conversationMissing
        }
        let data = try await payloads.loadOutboxPayload(
            artifactID: artifactID,
            maximumBytes: 8 * 1_024 * 1_024
        )
        let answer: AgentAnswer
        do {
            answer = try JSONDecoder().decode(AgentAnswer.self, from: data)
        } catch {
            throw ConversationOutboxProjectorError.invalidPayload(
                "final answer artifact is not an AgentAnswer: \(error.localizedDescription)"
            )
        }
        let text = answer.text ?? Self.renderStructured(answer.structuredOutput)
        if let mi = conversation.messages.firstIndex(where: { $0.id == messageID.rawValue }) {
            // Idempotent: only fill a still-empty placeholder (the live path may already have
            // persisted the committed text; never overwrite or duplicate it).
            guard conversation.messages[mi].answer.isEmpty else { return }
            conversation.messages[mi].answer = text
            conversation.messages[mi].emptyOutcome = nil
        } else {
            let parentID = conversation.messages.last(where: { $0.role == .user })?.id
            conversation.messages.append(
                Message(
                    id: messageID.rawValue,
                    role: .assistant,
                    answer: text,
                    parentID: parentID
                )
            )
        }
        conversation.updatedAt = Date()
        try await store.save(conversation)
    }

    private static func renderStructured(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
