// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AppRuntime
import AgentRuntime

/// One immutable submission: the provider-neutral request plus the frozen execution inputs that the
/// runtime persists before the first model pass. App-owned stores (conversation, memory, skills,
/// model catalog, tool registry) snapshot into this value at submission time.
public struct AgentRunSubmission: Sendable {
    public let request: AgentRequest
    public let frozenInputs: FrozenAgentRunInputs

    public init(request: AgentRequest, frozenInputs: FrozenAgentRunInputs) {
        self.request = request
        self.frozenInputs = frozenInputs
    }
}

/// Builds the immutable request + frozen inputs for one user turn. Implemented at app-assembly
/// time where the model catalog, memory, skills, and tool registry are all available.
public protocol AgentRunRequestBuilding: Sendable {
    func buildSubmission(
        conversationID: UUID,
        userTurnID: UUID,
        text: String,
        imageRefs: [ImageRef]
    ) async throws -> AgentRunSubmission
}

/// Image reference used by the agent path. `ImageRef` lives in the UI layer; the resolver at app
/// assembly reads the exact attachment file the conversation store already persisted.
public struct AgentAttachmentReference: Sendable, Equatable {
    public let id: UUID
    public let fileName: String
    public let mimeType: String

    public init(id: UUID, fileName: String, mimeType: String) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
    }
}

/// Resolves pre-authorized attachment bytes for the local model provider (vision). The provider
/// verifies byte count and digest before handing bytes to the engine.
public protocol AgentAttachmentBytesResolving: Sendable {
    func bytes(for attachment: AgentAttachmentReference) async throws -> Data
}
