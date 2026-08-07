// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import MobileLLMUI

/// Production outbox seam over the SQLite journal (spec §9.1/§33 gap 2): claim rows written
/// atomically with the journal, and acknowledge only after the conversation JSON applied them.
struct SQLiteOutboxProvider: AgentOutboxProviding {
    let repository: SQLiteRunJournal

    func claimOutbox(
        owner: String,
        now: AgentTimestamp,
        leaseUntil: AgentTimestamp,
        limit: Int
    ) async throws -> OutboxClaim {
        try await repository.claimOutbox(
            owner: owner,
            now: now,
            leaseUntil: leaseUntil,
            limit: limit
        )
    }

    func markOutboxDelivered(
        idempotencyKey: String,
        owner: String,
        deliveredAt: AgentTimestamp
    ) async throws {
        try await repository.markOutboxDelivered(
            idempotencyKey: idempotencyKey,
            owner: owner,
            deliveredAt: deliveredAt
        )
    }
}

/// Loads outbox payload bodies from the content-addressed execution payload store.
struct PayloadOutboxProvider: AgentOutboxPayloadLoading {
    let payloadStore: ContentAddressedExecutionPayloadStore

    func loadOutboxPayload(artifactID: ArtifactID, maximumBytes: UInt64) async throws -> Data {
        guard let reference = await payloadStore.reference(for: artifactID) else {
            throw ConversationOutboxProjectorError.payloadMissing
        }
        return try await payloadStore.load(reference, maximumBytes: maximumBytes)
    }
}
