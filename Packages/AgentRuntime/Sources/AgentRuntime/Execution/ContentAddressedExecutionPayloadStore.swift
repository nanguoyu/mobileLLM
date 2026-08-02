// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Production adapter that stores every stable-boundary body in the confined content-addressed
/// artifact store before its journal reference is committed.
public struct ContentAddressedExecutionPayloadStore: AgentExecutionPayloadStoring, Sendable {
    public let store: ContentAddressedArtifactStore

    public init(store: ContentAddressedArtifactStore) { self.store = store }

    public func commit(
        data: Data,
        mimeType: String,
        semanticType: String,
        runID: AgentRunID,
        stepID: AgentStepID?,
        invocationID: ToolInvocationID?,
        owner: ArtifactOwner,
        sensitivity: RedactionClassification
    ) async throws -> ArtifactReference {
        let provenance = try ArtifactProvenance(
            runID: runID,
            stepID: stepID,
            invocationID: invocationID,
            providerID: "mobilellm.agent-runtime"
        )
        let retention: ArtifactRetentionPolicy = switch owner.kind {
        case .run: .run
        case .conversation, .message: .conversation
        case .userManaged: .userManaged
        case .transient: .transient
        case .durableRecord:
            throw AgentExecutionError.internalInvariant(
                "durable-record payload owner has no compatible retention policy"
            )
        }
        return try await store.commit(
            ArtifactCommitRequest(
                data: data,
                mimeType: mimeType,
                semanticType: semanticType,
                provenance: provenance,
                retentionPolicy: retention,
                sensitivity: sensitivity,
                initialOwner: owner
            )
        )
    }

    public func load(_ reference: ArtifactReference, maximumBytes: UInt64) async throws -> Data {
        try await store.data(
            for: reference,
            maximumBytes: maximumBytes
        )
    }

    public func reference(for id: ArtifactID) async -> ArtifactReference? {
        await store.reference(for: id)
    }

    public func toolArtifactWriter(
        runID: AgentRunID,
        stepID: AgentStepID,
        invocationID: ToolInvocationID
    ) async throws -> any ToolArtifactWriting {
        try ScopedToolArtifactWriter(
            store: store,
            provenance: ArtifactProvenance(
                runID: runID,
                stepID: stepID,
                invocationID: invocationID,
                providerID: "mobilellm.agent-runtime"
            ),
            owner: .run(runID)
        )
    }
}
