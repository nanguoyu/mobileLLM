// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Versioned registry used by crash-injection tests. Every durable boundary is named here.
public enum SQLiteJournalFaultPoint: String, CaseIterable, Codable, Sendable {
    public static let registryVersion: UInt16 = 2

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
    case beforeCommandAdmission
    case afterCommandAdmission
    case beforeCommandClaim
    case afterCommandClaim
    case beforeCommandCompletion
    case afterCommandCompletion
    case beforeBudgetMutation
    case afterBudgetMutation
    case beforeSubmissionBoundary
    case afterSubmissionBoundary
    case beforeStableBoundaryProjection
    case afterStableBoundaryProjection
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

@available(*, deprecated, message: "Recovery classification is derived from RuntimeRecoveryFacts")
public enum InterruptedOperationKind: String, Codable, Sendable {
    case modelAttempt, pureRead, idempotentWrite, nonIdempotentWrite, stable
}

public struct RecoveryDirective: Hashable, Codable, Sendable {
    public let runID: AgentRunID
    public let disposition: RecoveryDisposition
    public let stableSequence: UInt64
    public let requiresExplicitResume: Bool
}

// MARK: - Production repository seam

/// Storage-level validation failures. Concrete SQLite availability failures remain implementation
/// details while these cases are safe for the runtime coordinator to branch on.
public enum RuntimeRepositoryError: Error, Hashable, Sendable {
    case invalidSubmission(String)
    case commandConflict(AgentCommandID)
    case commandNotFound(AgentCommandID)
    case commandLeaseMismatch(AgentCommandID)
    case commandLeaseExpired(AgentCommandID)
    case commandReceiptConflict(AgentCommandID)
    case budgetLedgerNotFound(AgentRunID)
    case budgetOperationConflict(BudgetReservationID)
    case boundaryClaimStateMismatch(AgentRunID)
    case durableFactCorrupt(String)
}

/// Exact durable state in which one external boundary hop is allowed to be claimed.
public struct RuntimeBoundaryClaimScope: Hashable, Sendable {
    public let runID: AgentRunID
    public let expectedState: AgentRunState
    public let expectedStateVersion: UInt64

    public init(
        runID: AgentRunID,
        expectedState: AgentRunState,
        expectedStateVersion: UInt64
    ) throws {
        guard expectedState == .generating || expectedState == .executingTools,
              expectedStateVersion > 0
        else {
            throw RuntimeRepositoryError.durableFactCorrupt("invalid boundary claim scope")
        }
        self.runID = runID
        self.expectedState = expectedState
        self.expectedStateVersion = expectedStateVersion
    }
}

/// Read-only recovery evidence for one exact prepared boundary attempt.
public enum RuntimeBoundaryClaimEvidence: Hashable, Sendable {
    case none
    case exact
    /// A pre-v5 claim proves a hop identity was consumed but cannot prove its full authorization
    /// binding. It must route to reconciliation and must never be replayed automatically.
    case legacyConservative
}

/// Durable lifecycle of one admitted state-changing command.
public enum DurableAgentCommandState: String, CaseIterable, Hashable, Codable, Sendable {
    case pending
    case claimed
    case completed
}

/// ABA-safe processing lease. A generation/token pair changes on every claim or reclaim.
public struct AgentCommandLeaseIdentity: Hashable, Codable, Sendable {
    public let owner: String
    public let token: UUID
    public let generation: UInt64
    public let expiresAt: AgentTimestamp

    public init(owner: String, token: UUID, generation: UInt64, expiresAt: AgentTimestamp) {
        self.owner = owner
        self.token = token
        self.generation = generation
        self.expiresAt = expiresAt
    }
}

/// Canonical command inbox row. Admission sequence is database-global and never reused.
public struct DurableAgentCommand: Hashable, Sendable {
    public let admissionSequence: UInt64
    public let envelope: AgentCommandEnvelope
    public let fingerprint: StableDigest
    public let state: DurableAgentCommandState
    public let admittedAt: AgentTimestamp
    public let claimOwner: String?
    public let claimExpiresAt: AgentTimestamp?
    public let leaseToken: UUID?
    public let leaseGeneration: UInt64
    public let attemptCount: UInt32
    public let receipt: AgentCommandReceiptEnvelope?
    public let completedAt: AgentTimestamp?

    public var commandID: AgentCommandID { envelope.payload.commandID }
    public var runID: AgentRunID { envelope.payload.runID }
    public var lease: AgentCommandLeaseIdentity? {
        guard let claimOwner, let claimExpiresAt, let leaseToken else { return nil }
        return AgentCommandLeaseIdentity(
            owner: claimOwner,
            token: leaseToken,
            generation: leaseGeneration,
            expiresAt: claimExpiresAt
        )
    }
}

/// Whether enqueue created a new inbox row, replayed the exact row, or found a reused identity.
public enum AgentCommandAdmissionDisposition: String, CaseIterable, Hashable, Codable, Sendable {
    case admitted
    case replayed
    case conflict
}

public struct AgentCommandAdmission: Hashable, Sendable {
    public let disposition: AgentCommandAdmissionDisposition
    public let command: DurableAgentCommand
}

public struct AgentCommandClaim: Hashable, Sendable {
    public let owner: String
    public let expiresAt: AgentTimestamp
    public let commands: [DurableAgentCommand]
}

/// A ledger mutation that must share the same SQLite transaction as its causal CAS/event append.
public enum BudgetLedgerOperation: Hashable, Codable, Sendable {
    case reserve(BudgetReservation)
    case settle(reservationID: BudgetReservationID, actualUsage: AgentUsage)
    case release(reservationID: BudgetReservationID)
}

/// Production event mutation. Budget changes cannot be submitted outside the causal journal CAS.
public struct RuntimeJournalMutation: Sendable {
    public let append: RunJournalAppendRequest
    public let budgetOperations: [BudgetLedgerOperation]

    public init(
        append: RunJournalAppendRequest,
        budgetOperations: some Sequence<BudgetLedgerOperation> = []
    ) {
        self.append = append
        self.budgetOperations = Array(budgetOperations)
    }
}

public struct RuntimeJournalMutationReceipt: Sendable {
    public let appendReceipt: RunJournalAppendReceipt
    public let budgetLedger: BudgetLedgerSnapshot
}

/// Canonical terminal transaction. The final assistant message pointer, projection outbox,
/// terminal event batch, and causal budget settlement commit or roll back together.
public struct RuntimeFinalizationCommit: Sendable {
    public let message: JournalMessageReference
    public let outbox: ProjectionOutboxItem
    public let mutation: RuntimeJournalMutation

    public init(
        message: JournalMessageReference,
        outbox: ProjectionOutboxItem,
        mutation: RuntimeJournalMutation
    ) {
        self.message = message
        self.outbox = outbox
        self.mutation = mutation
    }
}

/// Complete first durable transaction for an agent execution.
public struct RuntimeSubmissionCommit: Sendable {
    public let commandID: AgentCommandID
    public let request: AgentRequestEnvelope
    public let executionHandleID: AgentExecutionHandleID
    public let userMessage: JournalMessageReference
    public let inputSnapshot: AgentStableBoundaryReference
    public let initialAppend: RunJournalAppendRequest
    public let initialLedger: BudgetLedgerSnapshot
    public let outbox: ProjectionOutboxItem

    public init(
        commandID: AgentCommandID,
        request: AgentRequestEnvelope,
        executionHandleID: AgentExecutionHandleID,
        userMessage: JournalMessageReference,
        inputSnapshot: AgentStableBoundaryReference,
        initialAppend: RunJournalAppendRequest,
        initialLedger: BudgetLedgerSnapshot,
        outbox: ProjectionOutboxItem
    ) {
        self.commandID = commandID
        self.request = request
        self.executionHandleID = executionHandleID
        self.userMessage = userMessage
        self.inputSnapshot = inputSnapshot
        self.initialAppend = initialAppend
        self.initialLedger = initialLedger
        self.outbox = outbox
    }
}

public struct RuntimeSubmissionReceipt: Sendable {
    public let executionHandleID: AgentExecutionHandleID
    public let appendReceipt: RunJournalAppendReceipt
    public let budgetLedger: BudgetLedgerSnapshot
}

/// Exact durable submission binding, decoded through the bounded contract entry point.
public struct RuntimeSubmissionRecord: Hashable, Sendable {
    /// Database-assigned, process-independent FIFO position for root-resource admission.
    public let admissionSequence: UInt64
    public let commandID: AgentCommandID
    public let request: AgentRequestEnvelope
    public let executionHandleID: AgentExecutionHandleID
    public let inputSnapshot: AgentStableBoundaryReference
    public let fingerprint: StableDigest
}

/// Typed canonical and materialized facts needed to attach to an existing run.
public struct RuntimeRunFacts: Sendable {
    public let projection: AgentRunProjection
    public let conversationID: ConversationID?
    public let submission: RuntimeSubmissionRecord?
    public let budgetLedger: BudgetLedgerSnapshot?
}

/// One transactionally consistent view of a run's typed facts and canonical event stream.
public struct RuntimeRunSnapshot: Sendable {
    public let facts: RuntimeRunFacts
    public let events: [AgentEventEnvelope]
}

public struct DurableCompiledManifest: Hashable, Sendable {
    public let eventID: AgentEventID
    public let runID: AgentRunID
    public let stepID: AgentStepID
    public let reference: AgentStableBoundaryReference
}

public enum DurableApprovalState: String, CaseIterable, Hashable, Codable, Sendable {
    case requested
    case decided
}

public struct DurableApproval: Hashable, Sendable {
    public let runID: AgentRunID
    public let state: DurableApprovalState
    public let request: AgentApprovalRequest
    public let receipt: ApprovalReceipt?
}

public enum DurableInteractionState: String, CaseIterable, Hashable, Codable, Sendable {
    case requested
    case responded
}

public struct DurableInteraction: Hashable, Sendable {
    public let runID: AgentRunID
    public let state: DurableInteractionState
    public let request: UserInputRequest
    public let response: AgentStableBoundaryReference?
}

public enum DurableToolInvocationState: String, CaseIterable, Hashable, Codable, Sendable {
    case prepared
    case completed
}

public struct DurableToolInvocation: Hashable, Sendable {
    public let runID: AgentRunID
    public let state: DurableToolInvocationState
    public let request: PreparedExternalOperationRequest
    public let outcome: AgentToolInvocationOutcome?

    public var invocationID: ToolInvocationID? { request.invocationID }
}

/// Facts used by recovery classification. No transient caller guess participates in the result.
public struct RuntimeRecoveryFacts: Sendable {
    public let run: RuntimeRunFacts
    public let outstandingReservations: [BudgetReservation]
    public let toolInvocations: [DurableToolInvocation]
    public let pendingApprovalIDs: [ApprovalID]
    public let pendingInteractionIDs: [InteractionRequestID]
    public let hasIncompleteModelAttempt: Bool
}

/// Production persistence boundary for submissions, commands, journal CAS, budgets, and recovery.
public protocol RuntimeRepository: RunJournal {
    func commitSubmission(_ submission: RuntimeSubmissionCommit) async throws -> RuntimeSubmissionReceipt
    func commit(_ mutation: RuntimeJournalMutation) async throws -> RuntimeJournalMutationReceipt
    func commitFinalization(
        _ finalization: RuntimeFinalizationCommit
    ) async throws -> RuntimeJournalMutationReceipt

    func enqueueCommand(_ envelope: AgentCommandEnvelope) async throws -> AgentCommandAdmission
    func claimCommands(
        owner: String,
        now: AgentTimestamp,
        leaseUntil: AgentTimestamp,
        limit: Int
    ) async throws -> AgentCommandClaim
    func completeCommand(
        commandID: AgentCommandID,
        lease: AgentCommandLeaseIdentity,
        receipt: AgentCommandReceiptEnvelope,
        completedAt: AgentTimestamp
    ) async throws -> DurableAgentCommand
    func loadCommand(_ commandID: AgentCommandID) async throws -> DurableAgentCommand?

    func loadRunFacts(for runID: AgentRunID) async throws -> RuntimeRunFacts?
    func loadRunFacts(
        for executionHandleID: AgentExecutionHandleID
    ) async throws -> RuntimeRunFacts?
    func loadRunSnapshot(for runID: AgentRunID) async throws -> RuntimeRunSnapshot?
    func loadRunSnapshot(
        for executionHandleID: AgentExecutionHandleID
    ) async throws -> RuntimeRunSnapshot?
    /// Read-only exact recovery probe. Unlike `claimBoundaryHop`, this never consumes authority.
    func boundaryClaimEvidence(
        approvalID: ApprovalID,
        prepared: PreparedExternalOperationRequest,
        attempt: ExternalOperationAttempt
    ) async throws -> RuntimeBoundaryClaimEvidence
    /// Atomically validates the owning run state/version and consumes one boundary hop.
    func claimBoundaryHop(
        scope: RuntimeBoundaryClaimScope,
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool
    func loadBudgetLedger(for runID: AgentRunID) async throws -> BudgetLedgerSnapshot?
    func loadCompiledManifests(for runID: AgentRunID) async throws -> [DurableCompiledManifest]
    func loadApprovals(for runID: AgentRunID) async throws -> [DurableApproval]
    func loadInteractions(for runID: AgentRunID) async throws -> [DurableInteraction]
    func loadToolInvocations(for runID: AgentRunID) async throws -> [DurableToolInvocation]
    func loadRecoveryFacts(for runID: AgentRunID) async throws -> RuntimeRecoveryFacts?
    func recoveryDirective(for runID: AgentRunID) async throws -> RecoveryDirective?
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
