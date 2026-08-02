// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Versioned registry used by crash-injection tests. Every durable boundary is named here.
public enum SQLiteJournalFaultPoint: String, CaseIterable, Codable, Sendable {
    public static let registryVersion: UInt16 = 1

    case beforeOpenForWrite
    case afterMigrationBackup
    case beforeTransaction
    case afterTransactionBegin
    case beforeEventInsert
    case afterEventInsert
    case beforeRunUpdate
    case afterRunUpdate
    case beforeOutboxInsert
    case afterOutboxInsert
    case beforeCommit
    case afterCommit
    case beforeOutboxClaim
    case afterOutboxClaim
    case beforeOutboxDelivery
    case afterOutboxDelivery
    case beforeRecovery
    case beforeDeletionIntent
    case afterDeletionIntent
    case beforeConversationCascade
    case afterConversationCascade
}

public typealias SQLiteJournalFaultInjector = @Sendable (SQLiteJournalFaultPoint) throws -> Void

/// Non-sensitive canonical message pointer. Bodies live only in protected artifacts.
public struct JournalMessageReference: Hashable, Codable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let messageID: MessageID
    public let conversationID: ConversationID
    public let runID: AgentRunID
    public let role: Role
    public let bodyDigest: StableDigest
    public let bodyArtifactID: ArtifactID
    public let createdAt: AgentTimestamp

    public init(
        messageID: MessageID,
        conversationID: ConversationID,
        runID: AgentRunID,
        role: Role,
        bodyDigest: StableDigest,
        bodyArtifactID: ArtifactID,
        createdAt: AgentTimestamp
    ) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.runID = runID
        self.role = role
        self.bodyDigest = bodyDigest
        self.bodyArtifactID = bodyArtifactID
        self.createdAt = createdAt
    }
}

public struct ProjectionOutboxItem: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case acceptedUserMessage, finalAnswer, deleteConversation }
    public let idempotencyKey: String
    public let conversationID: ConversationID
    public let runID: AgentRunID?
    public let messageID: MessageID?
    public let kind: Kind
    public let payloadDigest: StableDigest
    public let payloadArtifactID: ArtifactID?
    public let attemptCount: UInt32

    public init(idempotencyKey: String, conversationID: ConversationID, runID: AgentRunID?, messageID: MessageID?, kind: Kind, payloadDigest: StableDigest, payloadArtifactID: ArtifactID?, attemptCount: UInt32 = 0) {
        self.idempotencyKey = idempotencyKey
        self.conversationID = conversationID
        self.runID = runID
        self.messageID = messageID
        self.kind = kind
        self.payloadDigest = payloadDigest
        self.payloadArtifactID = payloadArtifactID
        self.attemptCount = attemptCount
    }
}

public struct OutboxClaim: Hashable, Codable, Sendable {
    public let owner: String
    public let expiresAt: AgentTimestamp
    public let items: [ProjectionOutboxItem]
}

public enum RecoveryDisposition: String, CaseIterable, Codable, Sendable {
    case discardIncompleteModelAttempt
    case retryPureRead
    case retryIdempotentWrite
    case waitingForReconciliation
    case alreadyStable
}

public enum InterruptedOperationKind: String, Codable, Sendable {
    case modelAttempt, pureRead, idempotentWrite, nonIdempotentWrite, stable
}

public struct RecoveryDirective: Hashable, Codable, Sendable {
    public let runID: AgentRunID
    public let disposition: RecoveryDisposition
    public let stableSequence: UInt64
    public let requiresExplicitResume: Bool
}

public enum DeletionIntentScope: String, Codable, Sendable { case conversation, deleteAll }

public struct DeletionIntent: Hashable, Codable, Sendable {
    public let id: String
    public let scope: DeletionIntentScope
    public let conversationID: ConversationID?
    public let createdAt: AgentTimestamp

    public init(id: String, scope: DeletionIntentScope, conversationID: ConversationID?, createdAt: AgentTimestamp) {
        self.id = id
        self.scope = scope
        self.conversationID = conversationID
        self.createdAt = createdAt
    }
}

/// Sidecar coordinator is implemented by the app layer; persistence only commits durable intent/state.
public protocol JournalDeletionSidecarCoordinator: Sendable {
    func removeOwnedSidecars(for conversationID: ConversationID) async throws
    func removeAllSidecars() async throws
}

public struct JournalPragmaReport: Hashable, Sendable {
    public let journalMode: String
    public let synchronous: Int64
    public let foreignKeys: Bool
    public let secureDelete: Bool
    public let trustedSchema: Bool
    public let busyTimeoutMilliseconds: Int64
    public let defensive: Bool
}

public struct JournalSchemaReport: Hashable, Sendable {
    public let currentVersion: Int32
    public let migrationBackupURL: URL?
}

public struct ExternalClaimReference: Hashable, Codable, Sendable {
    public let id: String
    public let runID: AgentRunID
    public let invocationID: ToolInvocationID?
    public let kind: String
    public let payloadDigest: StableDigest

    public init(id: String, runID: AgentRunID, invocationID: ToolInvocationID?, kind: String, payloadDigest: StableDigest) {
        self.id = id
        self.runID = runID
        self.invocationID = invocationID
        self.kind = kind
        self.payloadDigest = payloadDigest
    }
}

/// App-level Delete All marker. It intentionally lives outside every directory being erased.
public struct DeleteAllMarker: Sendable {
    public let url: URL

    public init(applicationSupportURL: URL) {
        url = applicationSupportURL.appendingPathComponent("mobileLLM.delete-all.pending", isDirectory: false)
    }

    public var blocksStoreOpening: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func create() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try Data().write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try Data().write(to: url, options: .atomic)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    public func removeLast() throws {
        if blocksStoreOpening { try FileManager.default.removeItem(at: url) }
    }
}
