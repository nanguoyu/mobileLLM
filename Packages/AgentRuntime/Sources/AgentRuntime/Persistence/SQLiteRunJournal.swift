// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import SQLite3

/// Single-actor, single-connection canonical journal. Construction is side-effect free; the file is
/// created only by `openForWrite` or a mutation.
public actor SQLiteRunJournal: RuntimeRepository {
    public static let schemaVersion: Int32 = 3
    public static let maximumCommandPayloadBytes = 256 * 1_024

    private let databaseURL: URL
    private let faultInjector: SQLiteJournalFaultInjector?
    private var connection: SQLiteConnection?
    private var connectionIsWritable = false
    private var lastMigrationBackupURL: URL?
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    private static let commandDecodingLimits = try! AgentWireDecodingLimits(
        maximumBytes: maximumCommandPayloadBytes,
        maximumNestingDepth: 64,
        maximumCollectionItems: 8_192,
        maximumStringBytes: 192 * 1_024
    )

    public init(databaseURL: URL, faultInjector: SQLiteJournalFaultInjector? = nil) {
        self.databaseURL = databaseURL
        self.faultInjector = faultInjector
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public nonisolated var location: URL { databaseURL }

    /// A non-opening launch probe. It does not create a database, migrate, replay, or resume work.
    public nonisolated func databaseExists() -> Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    public func openForWrite() throws -> JournalSchemaReport {
        _ = try writableConnection()
        return JournalSchemaReport(
            currentVersion: Self.schemaVersion,
            migrationBackupURL: lastMigrationBackupURL
        )
    }

    public func close() {
        connection?.close()
        connection = nil
        connectionIsWritable = false
    }

    public func checkpointWAL() throws {
        let db = try writableConnection()
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func pragmaReport() throws -> JournalPragmaReport? {
        guard let db = try existingConnection() else { return nil }
        guard let journalMode = try db.scalarText("PRAGMA journal_mode"),
              let synchronous = try db.scalarInt("PRAGMA synchronous"),
              let foreignKeys = try db.scalarInt("PRAGMA foreign_keys"),
              let secureDelete = try db.scalarInt("PRAGMA secure_delete"),
              let trustedSchema = try db.scalarInt("PRAGMA trusted_schema"),
              let busyTimeoutMilliseconds = try db.scalarInt("PRAGMA busy_timeout"),
              let writableSchema = try db.scalarInt("PRAGMA writable_schema")
        else {
            throw SQLiteStoreError.corrupt
        }
        return JournalPragmaReport(
            journalMode: journalMode,
            synchronous: synchronous,
            foreignKeys: foreignKeys == 1,
            secureDelete: secureDelete == 1,
            trustedSchema: trustedSchema == 1,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds,
            defensive: writableSchema == 0
        )
    }

    public func loadProjection(for runID: AgentRunID) async throws -> AgentRunProjection? {
        guard let db = try existingConnection() else { return nil }
        return try projection(for: runID, db: db)
    }

    public func readEvents(_ request: RunJournalReadRequest) async throws -> RunJournalEventPage {
        guard let db = try existingConnection() else {
            return try RunJournalEventPage(events: [], nextCursor: nil, reachedEnd: true)
        }
        let afterSequence = request.after?.sequence ?? 0
        if let cursor = request.after {
            guard cursor.executionHandleID.description == (try db.scalarText(
                "SELECT execution_handle_id FROM runs WHERE run_id = ?",
                [.text(request.runID.description)]
            )) else { throw SQLiteStoreError.invariantViolation("cursor belongs to another stream") }
        }
        let rows = try db.rows(
            "SELECT payload FROM events WHERE run_id = ? AND sequence > ? ORDER BY sequence LIMIT ?",
            [.text(request.runID.description), .integer(Int64(afterSequence)), .integer(Int64(request.limit + 1))]
        )
        let reachedEnd = rows.count <= request.limit
        let pageRows = rows.prefix(request.limit)
        let events = try pageRows.map { row -> AgentEventEnvelope in
            guard let data = row.first?.blob else {
                throw SQLiteStoreError.corrupt
            }
            return try AgentEventEnvelope.decodeUntrusted(from: data)
        }
        return try RunJournalEventPage(
            events: events,
            nextCursor: events.last?.payload.cursor,
            reachedEnd: reachedEnd
        )
    }

    public func append(_ request: RunJournalAppendRequest) async throws -> RunJournalAppendReceipt {
        try mutate(request: request, projectionCommit: nil).receipt
    }

    /// Commits the causal event batch and every ledger reservation transition in one CAS.
    public func commit(_ mutation: RuntimeJournalMutation) async throws -> RuntimeJournalMutationReceipt {
        let result = try mutate(
            request: mutation.append,
            projectionCommit: nil,
            budgetOperations: mutation.budgetOperations
        )
        let ledger = if let committed = result.ledger {
            committed
        } else {
            try loadBudgetLedgerFromConnection(for: mutation.append.runID)
        }
        guard let ledger else {
            throw RuntimeRepositoryError.budgetLedgerNotFound(mutation.append.runID)
        }
        return RuntimeJournalMutationReceipt(appendReceipt: result.receipt, budgetLedger: ledger)
    }

    /// Atomically establishes the immutable request/handle binding and complete initial run facts.
    public func commitSubmission(_ submission: RuntimeSubmissionCommit) async throws -> RuntimeSubmissionReceipt {
        try validate(submission)
        let result = try mutate(
            request: submission.initialAppend,
            projectionCommit: MessageProjectionCommit(
                message: submission.userMessage,
                outbox: submission.outbox
            ),
            initialLedger: submission.initialLedger,
            submission: submission
        )
        if result.receipt.disposition == .rejected,
           result.receipt.diagnostic == .duplicateCommandConflict
        {
            throw RuntimeRepositoryError.commandConflict(submission.commandID)
        }
        let ledger = if let committed = result.ledger {
            committed
        } else {
            try loadBudgetLedgerFromConnection(for: submission.request.payload.runID)
        }
        guard let ledger else {
            throw RuntimeRepositoryError.budgetLedgerNotFound(submission.request.payload.runID)
        }
        return RuntimeSubmissionReceipt(
            executionHandleID: submission.executionHandleID,
            appendReceipt: result.receipt,
            budgetLedger: ledger
        )
    }

    /// Canonical send acceptance: message pointer, initial run events, and projection outbox commit together.
    public func acceptUserMessage(
        _ message: JournalMessageReference,
        initialAppend: RunJournalAppendRequest,
        outbox: ProjectionOutboxItem
    ) throws -> RunJournalAppendReceipt {
        guard message.role == .user, message.runID == initialAppend.runID,
              outbox.kind == .acceptedUserMessage, outbox.runID == message.runID,
              outbox.messageID == message.messageID, outbox.conversationID == message.conversationID,
              outbox.payloadDigest == message.bodyDigest,
              outbox.payloadArtifactID == message.bodyArtifactID
        else { throw SQLiteStoreError.invariantViolation("invalid accepted-message transaction") }
        return try mutate(
            request: initialAppend,
            projectionCommit: MessageProjectionCommit(message: message, outbox: outbox)
        ).receipt
    }

    /// Canonical finalization: final answer event, terminal state, assistant pointer, and outbox commit together.
    public func commitFinalAnswer(
        _ message: JournalMessageReference,
        terminalAppend: RunJournalAppendRequest,
        outbox: ProjectionOutboxItem
    ) throws -> RunJournalAppendReceipt {
        guard message.role == .assistant, message.runID == terminalAppend.runID,
              terminalAppend.events.last?.payload.event.isRunTerminal == true,
              outbox.kind == .finalAnswer, outbox.runID == message.runID,
              outbox.messageID == message.messageID, outbox.conversationID == message.conversationID,
              outbox.payloadDigest == message.bodyDigest,
              outbox.payloadArtifactID == message.bodyArtifactID
        else { throw SQLiteStoreError.invariantViolation("invalid final-answer transaction") }
        return try mutate(
            request: terminalAppend,
            projectionCommit: MessageProjectionCommit(message: message, outbox: outbox)
        ).receipt
    }

    // MARK: Durable command inbox

    public func enqueueCommand(_ envelope: AgentCommandEnvelope) async throws -> AgentCommandAdmission {
        let payload = try boundedCommandPayload(envelope)
        let fingerprint = StableDigest.fingerprint(
            domain: "sqlite-agent-command.v1",
            components: [payload]
        )
        let commandPayload = envelope.payload
        let db = try writableConnection()
        try inject(.beforeCommandAdmission)
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.execute("ROLLBACK") } }

        if let existing = try command(commandPayload.commandID, db: db) {
            let disposition: AgentCommandAdmissionDisposition = existing.fingerprint == fingerprint
                ? .replayed : .conflict
            try db.execute("COMMIT")
            committed = true
            return AgentCommandAdmission(disposition: disposition, command: existing)
        }

        try db.execute(
            """
            INSERT INTO agent_commands(
                command_id, run_id, fingerprint, state, payload_version, payload, admitted_at,
                attempt_count
            ) VALUES(?, ?, ?, 'pending', ?, ?, ?, 0)
            """,
            [
                .text(commandPayload.commandID.description), .text(commandPayload.runID.description),
                .text(fingerprint.rawValue), .integer(Int64(envelope.payloadVersion)), .blob(payload),
                .integer(commandPayload.issuedAt.rawValue),
            ]
        )
        try inject(.afterCommandAdmission)
        guard let admitted = try self.command(commandPayload.commandID, db: db) else {
            throw RuntimeRepositoryError.durableFactCorrupt("admitted command disappeared")
        }
        try db.execute("COMMIT")
        committed = true
        return AgentCommandAdmission(disposition: .admitted, command: admitted)
    }

    public func loadCommand(_ commandID: AgentCommandID) async throws -> DurableAgentCommand? {
        guard let db = try existingConnection() else { return nil }
        return try command(commandID, db: db)
    }

    public func claimCommands(
        owner: String,
        now: AgentTimestamp,
        leaseUntil: AgentTimestamp,
        limit: Int = 32
    ) async throws -> AgentCommandClaim {
        guard isValidLeaseOwner(owner), leaseUntil > now, (1 ... 256).contains(limit) else {
            throw SQLiteStoreError.invariantViolation("invalid command lease")
        }
        let db = try writableConnection()
        try inject(.beforeCommandClaim)
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.execute("ROLLBACK") } }

        let rows = try db.rows(
            """
            SELECT candidate.command_id
            FROM agent_commands AS candidate
            WHERE (
                    candidate.state = 'pending'
                    OR (candidate.state = 'claimed' AND candidate.claim_expires_at <= ?)
                  )
              AND NOT EXISTS (
                    SELECT 1 FROM agent_commands AS earlier
                    WHERE earlier.run_id = candidate.run_id
                      AND earlier.state != 'completed'
                      AND earlier.admission_sequence < candidate.admission_sequence
                  )
            ORDER BY candidate.admission_sequence
            LIMIT ?
            """,
            [.integer(now.rawValue), .integer(Int64(limit))]
        )
        let ids = try rows.map { row -> AgentCommandID in
            guard let raw = row[0].text, let id = AgentCommandID(raw) else {
                throw RuntimeRepositoryError.durableFactCorrupt("invalid command identity")
            }
            return id
        }
        for id in ids {
            let token = UUID().uuidString.lowercased()
            try db.execute(
                """
                UPDATE agent_commands
                SET state = 'claimed', claim_owner = ?, claim_expires_at = ?,
                    lease_token = ?, lease_generation = lease_generation + 1,
                    attempt_count = attempt_count + 1
                WHERE command_id = ? AND state != 'completed'
                """,
                [
                    .text(owner), .integer(leaseUntil.rawValue), .text(token),
                    .text(id.description),
                ]
            )
        }
        try inject(.afterCommandClaim)
        let commands = try ids.map { id -> DurableAgentCommand in
            guard let value = try command(id, db: db) else {
                throw RuntimeRepositoryError.durableFactCorrupt("claimed command disappeared")
            }
            return value
        }
        try db.execute("COMMIT")
        committed = true
        return AgentCommandClaim(owner: owner, expiresAt: leaseUntil, commands: commands)
    }

    public func completeCommand(
        commandID: AgentCommandID,
        lease: AgentCommandLeaseIdentity,
        receipt: AgentCommandReceiptEnvelope,
        completedAt: AgentTimestamp
    ) async throws -> DurableAgentCommand {
        guard isValidLeaseOwner(lease.owner), lease.generation > 0,
              receipt.payload.commandID == commandID
        else {
            throw RuntimeRepositoryError.commandReceiptConflict(commandID)
        }
        let receiptPayload = try boundedCommandReceiptPayload(receipt)
        let db = try writableConnection()
        try inject(.beforeCommandCompletion)
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.execute("ROLLBACK") } }

        guard let existing = try command(commandID, db: db) else {
            throw RuntimeRepositoryError.commandNotFound(commandID)
        }
        guard existing.runID == receipt.payload.runID else {
            throw RuntimeRepositoryError.commandReceiptConflict(commandID)
        }
        if existing.state == .completed {
            let existingPayload = try existing.receipt.map { try boundedCommandReceiptPayload($0) }
            guard existingPayload == receiptPayload else {
                throw RuntimeRepositoryError.commandReceiptConflict(commandID)
            }
            try db.execute("COMMIT")
            committed = true
            return existing
        }
        guard existing.state == .claimed, existing.lease == lease else {
            throw RuntimeRepositoryError.commandLeaseMismatch(commandID)
        }
        guard completedAt <= lease.expiresAt else {
            throw RuntimeRepositoryError.commandLeaseExpired(commandID)
        }
        try db.execute(
            """
            UPDATE agent_commands
            SET state = 'completed', claim_owner = NULL, claim_expires_at = NULL,
                lease_token = NULL,
                receipt_payload_version = ?, receipt = ?, completed_at = ?
            WHERE command_id = ? AND state = 'claimed' AND claim_owner = ?
              AND lease_token = ? AND lease_generation = ?
            """,
            [
                .integer(Int64(receipt.payloadVersion)), .blob(receiptPayload),
                .integer(completedAt.rawValue), .text(commandID.description), .text(lease.owner),
                .text(lease.token.uuidString.lowercased()), .integer(Int64(lease.generation)),
            ]
        )
        try inject(.afterCommandCompletion)
        guard let completed = try command(commandID, db: db) else {
            throw RuntimeRepositoryError.durableFactCorrupt("completed command disappeared")
        }
        try db.execute("COMMIT")
        committed = true
        return completed
    }

    /// Compatibility-only completion surface. It snapshots the current lease and therefore must
    /// not be used by concurrent workers; production consumers pass the claim's exact identity.
    @available(*, deprecated, message: "Pass the exact AgentCommandLeaseIdentity returned by claimCommands")
    public func completeCommand(
        commandID: AgentCommandID,
        owner: String,
        receipt: AgentCommandReceiptEnvelope,
        completedAt: AgentTimestamp
    ) async throws -> DurableAgentCommand {
        guard let current = try await loadCommand(commandID),
              current.claimOwner == owner,
              let lease = current.lease
        else { throw RuntimeRepositoryError.commandLeaseMismatch(commandID) }
        return try await completeCommand(
            commandID: commandID,
            lease: lease,
            receipt: receipt,
            completedAt: completedAt
        )
    }

    public func claimOutbox(
        owner: String,
        now: AgentTimestamp,
        leaseUntil: AgentTimestamp,
        limit: Int = 32
    ) throws -> OutboxClaim {
        guard !owner.isEmpty, leaseUntil > now, (1 ... 256).contains(limit) else {
            throw SQLiteStoreError.invariantViolation("invalid outbox lease")
        }
        let db = try writableConnection()
        try inject(.beforeOutboxClaim)
        try db.execute("BEGIN IMMEDIATE")
        do {
            let rows = try db.rows(
                """
                SELECT idempotency_key, conversation_id, run_id, message_id, kind, payload_digest,
                       payload_artifact_id, attempt_count
                FROM projection_outbox
                WHERE delivered_at IS NULL AND (claim_expires_at IS NULL OR claim_expires_at <= ?)
                ORDER BY created_at, idempotency_key LIMIT ?
                """,
                [.integer(now.rawValue), .integer(Int64(limit))]
            )
            let keys = rows.compactMap { $0[0].text }
            for key in keys {
                try db.execute(
                    "UPDATE projection_outbox SET claim_owner = ?, claim_expires_at = ?, attempt_count = attempt_count + 1 WHERE idempotency_key = ? AND delivered_at IS NULL",
                    [.text(owner), .integer(leaseUntil.rawValue), .text(key)]
                )
            }
            try inject(.afterOutboxClaim)
            try db.execute("COMMIT")
            let items = try rows.map { row in try decodeOutbox(row, incrementAttempt: true) }
            return OutboxClaim(owner: owner, expiresAt: leaseUntil, items: items)
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// Marks delivery idempotently. A stale claim owner cannot acknowledge another worker's lease.
    public func markOutboxDelivered(
        idempotencyKey: String,
        owner: String,
        deliveredAt: AgentTimestamp
    ) throws {
        let db = try writableConnection()
        try inject(.beforeOutboxDelivery)
        try db.execute("BEGIN IMMEDIATE")
        do {
            let rows = try db.rows(
                "SELECT claim_owner, delivered_at FROM projection_outbox WHERE idempotency_key = ?",
                [.text(idempotencyKey)]
            )
            guard let row = rows.first else { throw SQLiteStoreError.invariantViolation("unknown outbox item") }
            if row[1].integer != nil { try db.execute("COMMIT"); return }
            guard row[0].text == owner else { throw SQLiteStoreError.invariantViolation("outbox claim owner mismatch") }
            try db.execute(
                "UPDATE projection_outbox SET delivered_at = ?, claim_owner = NULL, claim_expires_at = NULL WHERE idempotency_key = ?",
                [.integer(deliveredAt.rawValue), .text(idempotencyKey)]
            )
            try inject(.afterOutboxDelivery)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Typed durable facts and recovery

    public func loadBudgetLedger(for runID: AgentRunID) async throws -> BudgetLedgerSnapshot? {
        guard let db = try existingConnection() else { return nil }
        return try budgetLedger(for: runID, db: db)
    }

    public func loadRunFacts(for runID: AgentRunID) async throws -> RuntimeRunFacts? {
        guard let db = try existingConnection() else { return nil }
        return try runFacts(for: runID, db: db)
    }

    public func loadCompiledManifests(for runID: AgentRunID) async throws -> [DurableCompiledManifest] {
        guard let db = try existingConnection() else { return [] }
        return try compiledManifests(for: runID, db: db)
    }

    public func loadApprovals(for runID: AgentRunID) async throws -> [DurableApproval] {
        guard let db = try existingConnection() else { return [] }
        return try approvals(for: runID, db: db)
    }

    public func loadInteractions(for runID: AgentRunID) async throws -> [DurableInteraction] {
        guard let db = try existingConnection() else { return [] }
        return try interactions(for: runID, db: db)
    }

    public func loadToolInvocations(for runID: AgentRunID) async throws -> [DurableToolInvocation] {
        guard let db = try existingConnection() else { return [] }
        return try toolInvocations(for: runID, db: db)
    }

    public func loadRecoveryFacts(for runID: AgentRunID) async throws -> RuntimeRecoveryFacts? {
        guard let db = try existingConnection() else { return nil }
        return try recoveryFacts(for: runID, db: db)
    }

    /// Classifies recovery solely from committed facts. It never appends, executes, or resumes work.
    public func recoveryDirective(for runID: AgentRunID) async throws -> RecoveryDirective? {
        try inject(.beforeRecovery)
        guard let db = try existingConnection(), let facts = try recoveryFacts(for: runID, db: db) else {
            return nil
        }
        return derivedRecoveryDirective(from: facts)
    }

    /// Compatibility-only surface. The transient hint is deliberately ignored so recovery cannot
    /// be weakened by a caller's stale in-memory operation classification.
    @available(*, deprecated, message: "Recovery is derived from durable repository facts")
    public func recoveryDirective(
        for runID: AgentRunID,
        interruptedOperation _: InterruptedOperationKind
    ) throws -> RecoveryDirective? {
        try inject(.beforeRecovery)
        guard let db = try existingConnection(), let facts = try recoveryFacts(for: runID, db: db) else {
            return nil
        }
        return derivedRecoveryDirective(from: facts)
    }

    public func createDeletionIntent(_ intent: DeletionIntent) throws {
        guard (intent.scope == .conversation) == (intent.conversationID != nil) else {
            throw SQLiteStoreError.invariantViolation("deletion intent scope mismatch")
        }
        let db = try writableConnection()
        try inject(.beforeDeletionIntent)
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute(
                "INSERT OR IGNORE INTO deletion_intents(intent_id, scope, conversation_id, created_at, completed_at) VALUES(?, ?, ?, ?, NULL)",
                [.text(intent.id), .text(intent.scope.rawValue), sqliteText(intent.conversationID?.description), .integer(intent.createdAt.rawValue)]
            )
            try inject(.afterDeletionIntent)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// Journal half of cross-store deletion. Intent remains durable until sidecars acknowledge.
    public func cascadeConversation(_ conversationID: ConversationID, intentID: String) throws {
        let db = try writableConnection()
        try inject(.beforeConversationCascade)
        try db.execute("BEGIN IMMEDIATE")
        do {
            guard try db.scalarInt(
                "SELECT COUNT(*) FROM deletion_intents WHERE intent_id = ? AND conversation_id = ? AND completed_at IS NULL",
                [.text(intentID), .text(conversationID.description)]
            ) == 1 else { throw SQLiteStoreError.invariantViolation("missing deletion intent") }
            try db.execute("DELETE FROM messages WHERE conversation_id = ?", [.text(conversationID.description)])
            try db.execute("DELETE FROM runs WHERE conversation_id = ?", [.text(conversationID.description)])
            try db.execute("DELETE FROM projection_outbox WHERE conversation_id = ?", [.text(conversationID.description)])
            try db.execute(
                "DELETE FROM artifact_metadata WHERE artifact_id NOT IN (SELECT artifact_id FROM artifact_refs)")
            try inject(.afterConversationCascade)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    public func completeDeletionIntent(id: String, at timestamp: AgentTimestamp) throws {
        let db = try writableConnection()
        try db.execute(
            "UPDATE deletion_intents SET completed_at = ? WHERE intent_id = ? AND completed_at IS NULL",
            [.integer(timestamp.rawValue), .text(id)]
        )
    }

    public func pendingDeletionIntents() throws -> [DeletionIntent] {
        guard let db = try existingConnection() else { return [] }
        return try db.rows(
            "SELECT intent_id, scope, conversation_id, created_at FROM deletion_intents WHERE completed_at IS NULL ORDER BY created_at"
        ).map { row in
            guard let id = row[0].text, let rawScope = row[1].text,
                  let scope = DeletionIntentScope(rawValue: rawScope), let created = row[3].integer
            else { throw SQLiteStoreError.corrupt }
            return DeletionIntent(
                id: id,
                scope: scope,
                conversationID: row[2].text.flatMap(ConversationID.init),
                createdAt: AgentTimestamp(rawValue: created)
            )
        }
    }

    /// Legacy fixture/migration helper. Production code must use `commit(_:)` so reservation and
    /// its causal event share one CAS transaction.
    @available(*, deprecated, message: "Use commit(_:) with a BudgetLedgerOperation")
    public func recordBudgetReservation(runID: AgentRunID, reservation: BudgetReservation) throws {
        let db = try writableConnection()
        let payload = try encoder.encode(reservation)
        try db.execute(
            """
            INSERT INTO budget_reservations(
                reservation_id, run_id, state, maximum_digest, payload_version, payload
            ) VALUES(?, ?, 'reserved', ?, 1, ?)
            """,
            [
                .text(reservation.id.description), .text(runID.description),
                .text(StableDigest.sha256(payload).rawValue), .blob(payload),
            ]
        )
    }

    public func recordExternalClaim(_ claim: ExternalClaimReference) throws {
        guard !claim.id.isEmpty, !claim.kind.isEmpty else {
            throw SQLiteStoreError.invariantViolation("invalid external claim")
        }
        let db = try writableConnection()
        try db.execute(
            "INSERT INTO external_claims(claim_id, run_id, invocation_id, claim_kind, payload_digest, payload_version) VALUES(?, ?, ?, ?, ?, 1)",
            [.text(claim.id), .text(claim.runID.description), sqliteText(claim.invocationID?.description), .text(claim.kind), .text(claim.payloadDigest.rawValue)]
        )
    }

    public func createArtifactDeletionIntent(id: String, artifactID: ArtifactID, at timestamp: AgentTimestamp) throws {
        guard !id.isEmpty else { throw SQLiteStoreError.invariantViolation("empty artifact deletion intent") }
        let db = try writableConnection()
        try db.execute(
            "INSERT OR IGNORE INTO artifact_deletion_intents(intent_id, artifact_id, created_at, completed_at) VALUES(?, ?, ?, NULL)",
            [.text(id), .text(artifactID.description), .integer(timestamp.rawValue)]
        )
    }

    public func rowCount(table: String) throws -> Int {
        let allowed = Set(Self.schemaTables)
        guard allowed.contains(table), let db = try existingConnection() else { return 0 }
        guard let count = try db.scalarInt("SELECT COUNT(*) FROM \(table)") else {
            throw SQLiteStoreError.corrupt
        }
        return Int(count)
    }

    private func mutate(
        request: RunJournalAppendRequest,
        projectionCommit: MessageProjectionCommit?,
        budgetOperations: [BudgetLedgerOperation] = [],
        initialLedger: BudgetLedgerSnapshot? = nil,
        submission: RuntimeSubmissionCommit? = nil
    ) throws -> MutationResult {
        guard initialLedger == nil || budgetOperations.isEmpty else {
            throw SQLiteStoreError.invariantViolation("initial ledger cannot also be mutated")
        }
        let db = try writableConnection()
        let fingerprint = try mutationFingerprint(
            request,
            projectionCommit: projectionCommit,
            budgetOperations: budgetOperations,
            initialLedger: initialLedger,
            submission: submission
        )
        let identity = mutationKey(request.mutationIdentity)
        try inject(.beforeTransaction)
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.execute("ROLLBACK") } }
        try inject(.afterTransactionBegin)

        if let existing = try db.rows(
            "SELECT fingerprint, event_ids, run_id, ledger_payload FROM mutation_receipts WHERE identity_kind = ? AND identity_id = ?",
            [.text(identity.kind), .text(identity.id)]
        ).first {
            guard let existingRunID = existing[2].text.flatMap(AgentRunID.init),
                  let projection = try projection(for: existingRunID, db: db)
            else {
                throw SQLiteStoreError.corrupt
            }
            if existing[0].text == fingerprint.rawValue, let eventData = existing[1].blob {
                let eventIDs = try AgentWireDecoder.decode([AgentEventID].self, from: eventData)
                let receiptLedger = try existing[3].blob.map {
                    try AgentWireDecoder.decode(BudgetLedgerSnapshot.self, from: $0)
                } ?? budgetLedger(for: existingRunID, db: db)
                try db.execute("COMMIT")
                committed = true
                return MutationResult(
                    receipt: try RunJournalAppendReceipt(
                        mutationIdentity: request.mutationIdentity,
                        disposition: .replayed,
                        projection: projection,
                        eventIDs: eventIDs
                    ),
                    ledger: receiptLedger
                )
            }
            try db.execute("COMMIT")
            committed = true
            return MutationResult(
                receipt: try RunJournalAppendReceipt(
                    mutationIdentity: request.mutationIdentity,
                    disposition: .rejected,
                    projection: projection,
                    diagnostic: .duplicateCommandConflict
                ),
                ledger: try budgetLedger(for: existingRunID, db: db)
            )
        }

        let prior = try projection(for: request.runID, db: db)
        if let prior {
            if prior.isTerminal {
                try db.execute("COMMIT"); committed = true
                return MutationResult(
                    receipt: try RunJournalAppendReceipt(
                        mutationIdentity: request.mutationIdentity,
                        disposition: .rejected,
                        projection: prior,
                        diagnostic: .terminalRunImmutable
                    ),
                    ledger: try budgetLedger(for: request.runID, db: db)
                )
            }
            if prior.stateVersion != request.expectedRunStateVersion {
                try db.execute("COMMIT"); committed = true
                return MutationResult(
                    receipt: try RunJournalAppendReceipt(
                        mutationIdentity: request.mutationIdentity,
                        disposition: .stale,
                        projection: prior,
                        diagnostic: .staleExpectedVersion
                    ),
                    ledger: try budgetLedger(for: request.runID, db: db)
                )
            }
        } else if request.expectedRunStateVersion != 1 {
            throw SQLiteStoreError.invariantViolation("new run must begin at state version one")
        }

        let projected: AgentRunProjection
        if let prior { projected = try prior.applying(request.events) }
        else {
            guard let created = try AgentRunProjection.replay(request.events) else {
                throw SQLiteStoreError.invariantViolation("empty initial projection")
            }
            projected = created
        }

        // Materialize the parent row before auxiliary event projections. Not every auxiliary
        // schema consumer can rely on deferred foreign-key enforcement.
        try inject(.beforeRunUpdate)
        try upsertRun(projected, conversationID: projectionCommit?.message.conversationID, db: db)
        try inject(.afterRunUpdate)
        try inject(.beforeEventInsert)
        let hasStableBoundary = request.events.contains { isStableBoundaryEvent($0.payload.event) }
        if hasStableBoundary { try inject(.beforeStableBoundaryProjection) }
        for envelope in request.events { try insert(envelope, db: db) }
        if hasStableBoundary { try inject(.afterStableBoundaryProjection) }
        try inject(.afterEventInsert)

        var resultingLedger: BudgetLedgerSnapshot?
        if let initialLedger {
            try inject(.beforeBudgetMutation)
            try insertInitialLedger(initialLedger, runID: request.runID, db: db)
            try inject(.afterBudgetMutation)
            resultingLedger = initialLedger
        } else if !budgetOperations.isEmpty {
            try inject(.beforeBudgetMutation)
            resultingLedger = try applyBudgetOperations(
                budgetOperations,
                runID: request.runID,
                db: db
            )
            try inject(.afterBudgetMutation)
        }
        if let resultingLedger,
           !usageIsEquivalent(resultingLedger.consumed, projected.cumulativeUsage)
        {
            throw SQLiteStoreError.invariantViolation(
                "budget ledger consumption differs from projected cumulative usage"
            )
        }

        if let projectionCommit {
            let message = projectionCommit.message
            try db.execute(
                "INSERT INTO messages(message_id, conversation_id, run_id, role, body_digest, body_artifact_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
                [.text(message.messageID.description), .text(message.conversationID.description), .text(message.runID.description), .text(message.role.rawValue), .text(message.bodyDigest.rawValue), .text(message.bodyArtifactID.description), .integer(message.createdAt.rawValue)]
            )
            try db.execute(
                "INSERT OR IGNORE INTO artifact_refs(artifact_id, owner_kind, owner_id) VALUES(?, 'message', ?)",
                [.text(message.bodyArtifactID.description), .text(message.messageID.description)]
            )
            try inject(.beforeOutboxInsert)
            try insertOutbox(projectionCommit.outbox, createdAt: message.createdAt, db: db)
            try inject(.afterOutboxInsert)
        }
        if let submission {
            try inject(.beforeSubmissionBoundary)
            try insertSubmission(submission, fingerprint: fingerprint, db: db)
            try inject(.afterSubmissionBoundary)
        }
        let eventIDs = request.events.map(\.payload.eventID)
        let receiptLedgerPayload = try resultingLedger.map(encoder.encode)
        try db.execute(
            """
            INSERT INTO mutation_receipts(
                identity_kind, identity_id, run_id, fingerprint, event_ids, ledger_payload
            ) VALUES(?, ?, ?, ?, ?, ?)
            """,
            [
                .text(identity.kind), .text(identity.id), .text(request.runID.description),
                .text(fingerprint.rawValue), .blob(try encoder.encode(eventIDs)),
                receiptLedgerPayload.map(SQLiteValue.blob) ?? .null,
            ]
        )
        try inject(.beforeCommit)
        try db.execute("COMMIT")
        committed = true
        try inject(.afterCommit)
        return MutationResult(
            receipt: try RunJournalAppendReceipt(
                mutationIdentity: request.mutationIdentity,
                disposition: .appended,
                projection: projected,
                eventIDs: eventIDs
            ),
            ledger: resultingLedger
        )
    }

    private func projection(for runID: AgentRunID, db: SQLiteConnection) throws -> AgentRunProjection? {
        let rows = try db.rows(
            "SELECT payload FROM events WHERE run_id = ? ORDER BY sequence",
            [.text(runID.description)]
        )
        let events = try rows.map { row -> AgentEventEnvelope in
            guard let data = row[0].blob else { throw SQLiteStoreError.corrupt }
            return try AgentEventEnvelope.decodeUntrusted(from: data)
        }
        return try AgentRunProjection.replay(events)
    }

    private func insert(_ envelope: AgentEventEnvelope, db: SQLiteConnection) throws {
        let record = envelope.payload
        try db.execute(
            """
            INSERT INTO events(event_id, run_id, sequence, state_version, timestamp, record_digest,
                               previous_digest, payload_version, payload, is_terminal)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(record.eventID.description), .text(record.runID.description), .integer(Int64(record.sequence)),
             .integer(Int64(record.runStateVersion)), .integer(record.timestamp.rawValue),
             .text(record.recordDigest.rawValue), sqliteText(record.previousRecordDigest?.rawValue),
             .integer(Int64(envelope.payloadVersion)), .blob(try encoder.encode(envelope)),
             .integer(record.event.isRunTerminal ? 1 : 0)]
        )
        let payload = try encoder.encode(record.event)
        switch record.event {
        case .runInputSnapshotCommitted(let reference):
            try db.execute(
                """
                INSERT INTO run_input_snapshots(
                    run_id, format_version, digest, artifact_id, payload_version, payload
                ) VALUES(?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(record.runID.description), .integer(Int64(reference.formatVersion)),
                    .text(reference.digest.rawValue), sqliteText(reference.artifactID?.description),
                    .integer(Int64(AgentStableBoundaryReference.currentPayloadVersion)),
                    .blob(try encoder.encode(reference)),
                ]
            )
        case .compiledManifestCommitted(let stepID, let reference):
            try db.execute("INSERT OR IGNORE INTO steps(step_id, run_id, payload_version, payload) VALUES(?, ?, 1, ?)", [.text(stepID.description), .text(record.runID.description), .blob(payload)])
            try db.execute(
                """
                INSERT INTO compiled_manifests(
                    manifest_id, run_id, step_id, digest, artifact_id, payload_version, payload
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(record.eventID.description), .text(record.runID.description),
                    .text(stepID.description), .text(reference.digest.rawValue),
                    sqliteText(reference.artifactID?.description),
                    .integer(Int64(AgentStableBoundaryReference.currentPayloadVersion)),
                    .blob(try encoder.encode(reference)),
                ]
            )
        case .validatedActionCommitted(let stepID, _):
            try db.execute("INSERT OR IGNORE INTO steps(step_id, run_id, payload_version, payload) VALUES(?, ?, 1, ?)", [.text(stepID.description), .text(record.runID.description), .blob(payload)])
        case .modelAttemptOutcome:
            try db.execute("INSERT INTO model_attempts(attempt_id, run_id, event_id, payload_version, payload) VALUES(?, ?, ?, 1, ?)", [.text(record.eventID.description), .text(record.runID.description), .text(record.eventID.description), .blob(payload)])
        case .toolIntentRecorded(let request):
            try db.execute("INSERT INTO external_intents(intent_id, run_id, invocation_id, idempotency, payload_version, payload) VALUES(?, ?, ?, ?, 1, ?)", [.text(record.eventID.description), .text(record.runID.description), sqliteText(request.invocationID?.description), .text(request.plan.idempotency.rawValue), .blob(payload)])
            if let invocationID = request.invocationID {
                try db.execute(
                    """
                    INSERT INTO tool_invocations(
                        invocation_id, run_id, state, payload_version, payload, intent_payload
                    ) VALUES(?, ?, 'prepared', 1, ?, ?)
                    """,
                    [
                        .text(invocationID.description), .text(record.runID.description),
                        .blob(payload), .blob(try encoder.encode(request)),
                    ]
                )
            }
        case .toolOutcomeRecorded(let invocationID, let outcome):
            try db.execute("INSERT INTO external_outcomes(outcome_id, run_id, invocation_id, payload_version, payload) VALUES(?, ?, ?, 1, ?)", [.text(record.eventID.description), .text(record.runID.description), .text(invocationID.description), .blob(payload)])
            guard try db.scalarInt(
                "SELECT COUNT(*) FROM tool_invocations WHERE invocation_id = ? AND run_id = ? AND state = 'prepared'",
                [.text(invocationID.description), .text(record.runID.description)]
            ) == 1 else {
                throw SQLiteStoreError.invariantViolation("tool outcome lacks prepared invocation")
            }
            try db.execute(
                "UPDATE tool_invocations SET state = 'completed', payload = ?, outcome_payload = ? WHERE invocation_id = ?",
                [.blob(payload), .blob(try encoder.encode(outcome)), .text(invocationID.description)]
            )
        case .approvalRequested(let request):
            try db.execute(
                "INSERT INTO approvals(approval_id, run_id, state, payload_version, payload, request_payload) VALUES(?, ?, 'requested', 1, ?, ?)",
                [.text(request.id.description), .text(record.runID.description), .blob(payload), .blob(try encoder.encode(request))]
            )
        case .approvalDecided(let receipt):
            guard try db.scalarInt(
                "SELECT COUNT(*) FROM approvals WHERE approval_id = ? AND run_id = ? AND state = 'requested'",
                [.text(receipt.id.description), .text(record.runID.description)]
            ) == 1 else {
                throw SQLiteStoreError.invariantViolation("approval decision lacks durable request")
            }
            try db.execute(
                "UPDATE approvals SET state = 'decided', payload = ?, receipt_payload = ? WHERE approval_id = ?",
                [.blob(payload), .blob(try encoder.encode(receipt)), .text(receipt.id.description)]
            )
        case .userInputRequested(let request):
            try db.execute(
                "INSERT INTO interactions(interaction_id, run_id, state, creation_state_version, payload_version, payload, request_payload) VALUES(?, ?, 'requested', ?, 1, ?, ?)",
                [.text(request.id.description), .text(record.runID.description), .integer(Int64(request.creationStateVersion)), .blob(payload), .blob(try encoder.encode(request))]
            )
        case .userInputResponseCommitted(let requestID, let reference):
            guard try db.scalarInt(
                "SELECT COUNT(*) FROM interactions WHERE interaction_id = ? AND run_id = ? AND state = 'requested'",
                [.text(requestID.description), .text(record.runID.description)]
            ) == 1 else {
                throw SQLiteStoreError.invariantViolation("interaction response lacks durable request")
            }
            try db.execute(
                "UPDATE interactions SET state = 'responded', payload = ?, response_payload = ? WHERE interaction_id = ?",
                [.blob(payload), .blob(try encoder.encode(reference)), .text(requestID.description)]
            )
        case .artifactCommitted(let artifact):
            try db.execute("INSERT OR REPLACE INTO artifact_metadata(artifact_id, run_id, content_digest, byte_count, mime_type, locator, retention, payload_version, payload) VALUES(?, ?, ?, ?, ?, ?, ?, 1, ?)", [.text(artifact.id.description), .text(record.runID.description), .text(artifact.contentDigest.rawValue), .integer(Int64(clamping: artifact.byteCount)), .text(artifact.mimeType), .text(artifact.locator.value), .text(artifact.retentionPolicy.rawValue), .blob(payload)])
            try db.execute("INSERT OR IGNORE INTO artifact_refs(artifact_id, owner_kind, owner_id) VALUES(?, 'run', ?)", [.text(artifact.id.description), .text(record.runID.description)])
        case .usageUpdated:
            try db.execute("INSERT INTO usage_ledger(entry_id, run_id, event_id, payload_version, payload) VALUES(?, ?, ?, 1, ?)", [.text(record.eventID.description), .text(record.runID.description), .text(record.eventID.description), .blob(payload)])
        default: break
        }
    }

    private func upsertRun(_ projection: AgentRunProjection, conversationID: ConversationID?, db: SQLiteConnection) throws {
        let last = projection.cursor
        try db.execute(
            """
            INSERT INTO runs(run_id, conversation_id, request_id, execution_handle_id, state, state_version,
                             next_sequence, terminal_event_id, last_digest, created_at, updated_at, deletion_blocked)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(run_id) DO UPDATE SET
                conversation_id = COALESCE(excluded.conversation_id, runs.conversation_id), state = excluded.state,
                state_version = excluded.state_version, next_sequence = excluded.next_sequence,
                terminal_event_id = excluded.terminal_event_id, last_digest = excluded.last_digest,
                updated_at = excluded.updated_at
            """,
            [.text(projection.runID.description), sqliteText(conversationID?.description),
             .text(projection.requestID.description), .text(projection.executionHandleID.description),
             .text(projection.state.rawValue), .integer(Int64(projection.stateVersion)),
             .integer(Int64(projection.eventCount + 1)), projection.isTerminal ? .text(last.eventID.description) : .null,
             .text(last.recordDigest.rawValue), .integer(last.timestamp.rawValue), .integer(last.timestamp.rawValue)]
        )
    }

    private func insertOutbox(_ item: ProjectionOutboxItem, createdAt: AgentTimestamp, db: SQLiteConnection) throws {
        try db.execute(
            """
            INSERT INTO projection_outbox(idempotency_key, conversation_id, run_id, message_id, kind,
                                          payload_digest, payload_artifact_id, created_at, attempt_count)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0)
            """,
            [.text(item.idempotencyKey), .text(item.conversationID.description), sqliteText(item.runID?.description),
             sqliteText(item.messageID?.description), .text(item.kind.rawValue),
             .text(item.payloadDigest.rawValue), sqliteText(item.payloadArtifactID?.description),
             .integer(createdAt.rawValue)]
        )
    }

    private func decodeOutbox(_ row: [SQLiteValue], incrementAttempt: Bool) throws -> ProjectionOutboxItem {
        guard let key = row[0].text, let conversation = row[1].text.flatMap(ConversationID.init),
              let rawKind = row[4].text, let kind = ProjectionOutboxItem.Kind(rawValue: rawKind),
              let digestText = row[5].text, let digest = try? StableDigest(rawValue: digestText),
              let attempts = row[7].integer
        else { throw SQLiteStoreError.corrupt }
        return ProjectionOutboxItem(
            idempotencyKey: key,
            conversationID: conversation,
            runID: row[2].text.flatMap(AgentRunID.init),
            messageID: row[3].text.flatMap(MessageID.init),
            kind: kind,
            payloadDigest: digest,
            payloadArtifactID: row[6].text.flatMap(ArtifactID.init),
            attemptCount: UInt32(clamping: attempts + (incrementAttempt ? 1 : 0))
        )
    }

    private func validate(_ submission: RuntimeSubmissionCommit) throws {
        let request = submission.request.payload
        let append = submission.initialAppend
        let firstRecord = append.events.first?.payload
        let snapshotEvents = append.events.compactMap { envelope -> AgentStableBoundaryReference? in
            guard case .runInputSnapshotCommitted(let reference) = envelope.payload.event else { return nil }
            return reference
        }
        guard request.runID == append.runID,
              request.runID == submission.userMessage.runID,
              request.conversationID == submission.userMessage.conversationID,
              submission.userMessage.role == .user,
              submission.commandID == mutationCommandID(append.mutationIdentity),
              append.expectedRunStateVersion == 1,
              firstRecord?.sequence == 1,
              firstRecord?.runStateVersion == 1,
              firstRecord?.runState == .created,
              firstRecord.map({ record in
                  guard case .runInputSnapshotCommitted(let reference) = record.event else {
                      return false
                  }
                  return reference == submission.inputSnapshot
              }) == true,
              append.events.allSatisfy({
                  $0.payload.requestID == request.id
                      && $0.payload.executionHandleID == submission.executionHandleID
                      && $0.payload.runID == request.runID
              }),
              snapshotEvents == [submission.inputSnapshot],
              submission.initialLedger.budget == request.budget,
              submission.initialLedger.consumed == .zero,
              submission.initialLedger.reservations.isEmpty,
              append.events.last?.payload.cumulativeUsage == .zero,
              submission.outbox.kind == .acceptedUserMessage,
              submission.outbox.runID == request.runID,
              submission.outbox.messageID == submission.userMessage.messageID,
              submission.outbox.conversationID == request.conversationID,
              submission.outbox.payloadDigest == submission.userMessage.bodyDigest,
              submission.outbox.payloadArtifactID == submission.userMessage.bodyArtifactID
        else {
            throw RuntimeRepositoryError.invalidSubmission("submission bindings are inconsistent")
        }
        if let sourceMessageID = request.provenance.sourceMessageID,
           sourceMessageID != submission.userMessage.messageID
        {
            throw RuntimeRepositoryError.invalidSubmission("request provenance message differs")
        }
        let requestPayload = try encoder.encode(submission.request)
        _ = try AgentRequestEnvelope.decodeUntrusted(from: requestPayload)
    }

    private func mutationFingerprint(
        _ request: RunJournalAppendRequest,
        projectionCommit: MessageProjectionCommit?,
        budgetOperations: [BudgetLedgerOperation],
        initialLedger: BudgetLedgerSnapshot?,
        submission: RuntimeSubmissionCommit?
    ) throws -> StableDigest {
        // Preserve the generation-one fingerprint for compatibility-only append/message APIs and
        // already durable version-two mutation receipts.
        if budgetOperations.isEmpty, initialLedger == nil, submission == nil {
            return StableDigest.fingerprint(
                domain: "sqlite-run-journal-mutation.v1",
                components: [
                    Data(request.runID.description.utf8),
                    Data(String(request.expectedRunStateVersion).utf8),
                    try encoder.encode(request.events),
                ]
            )
        }
        var components = [
            Data(request.runID.description.utf8),
            Data(String(request.expectedRunStateVersion).utf8),
            try encoder.encode(request.events),
            try encoder.encode(budgetOperations),
            try initialLedger.map(encoder.encode) ?? Data(),
        ]
        if let projectionCommit {
            components.append(try encoder.encode(projectionCommit.message))
            components.append(try encoder.encode(projectionCommit.outbox))
        } else {
            components.append(Data())
            components.append(Data())
        }
        if let submission {
            components.append(Data(submission.commandID.description.utf8))
            components.append(try encoder.encode(submission.request))
            components.append(Data(submission.executionHandleID.description.utf8))
            components.append(try encoder.encode(submission.inputSnapshot))
        }
        return StableDigest.fingerprint(
            domain: "sqlite-runtime-repository-mutation.v2",
            components: components
        )
    }

    private func mutationCommandID(_ identity: RunJournalMutationIdentity) -> AgentCommandID? {
        guard case .command(let id) = identity else { return nil }
        return id
    }

    private func usageIsEquivalent(_ lhs: AgentUsage, _ rhs: AgentUsage) -> Bool {
        lhs.quantities.isComponentwiseAtMost(rhs.quantities)
            && rhs.quantities.isComponentwiseAtMost(lhs.quantities)
    }

    private func insertSubmission(
        _ submission: RuntimeSubmissionCommit,
        fingerprint: StableDigest,
        db: SQLiteConnection
    ) throws {
        try db.execute(
            """
            INSERT INTO run_submissions(
                run_id, submission_command_id, request_id, execution_handle_id,
                request_payload_version, request_payload, input_snapshot_payload_version,
                input_snapshot_payload, fingerprint
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(submission.request.payload.runID.description),
                .text(submission.commandID.description),
                .text(submission.request.payload.id.description),
                .text(submission.executionHandleID.description),
                .integer(Int64(submission.request.payloadVersion)),
                .blob(try encoder.encode(submission.request)),
                .integer(Int64(AgentStableBoundaryReference.currentPayloadVersion)),
                .blob(try encoder.encode(submission.inputSnapshot)),
                .text(fingerprint.rawValue),
            ]
        )
    }

    private func insertInitialLedger(
        _ ledger: BudgetLedgerSnapshot,
        runID: AgentRunID,
        db: SQLiteConnection
    ) throws {
        guard ledger.reservations.isEmpty else {
            throw SQLiteStoreError.invariantViolation("initial ledger has reservations")
        }
        let payload = try encoder.encode(ledger)
        _ = try AgentWireDecoder.decode(BudgetLedgerSnapshot.self, from: payload)
        try db.execute(
            "INSERT INTO budget_ledgers(run_id, revision, payload_version, payload) VALUES(?, 1, 1, ?)",
            [.text(runID.description), .blob(payload)]
        )
    }

    private func applyBudgetOperations(
        _ operations: [BudgetLedgerOperation],
        runID: AgentRunID,
        db: SQLiteConnection
    ) throws -> BudgetLedgerSnapshot {
        guard var ledger = try budgetLedger(for: runID, db: db) else {
            throw RuntimeRepositoryError.budgetLedgerNotFound(runID)
        }
        var changed = false
        for operation in operations {
            switch operation {
            case .reserve(let reservation):
                let result = try reserve(reservation, runID: runID, ledger: ledger, db: db)
                ledger = result.ledger
                changed = changed || result.changed
            case .settle(let reservationID, let actualUsage):
                let result = try settle(
                    reservationID,
                    actualUsage: actualUsage,
                    runID: runID,
                    ledger: ledger,
                    db: db
                )
                ledger = result.ledger
                changed = changed || result.changed
            case .release(let reservationID):
                let result = try release(reservationID, runID: runID, ledger: ledger, db: db)
                ledger = result.ledger
                changed = changed || result.changed
            }
        }
        if changed {
            let payload = try encoder.encode(ledger)
            _ = try AgentWireDecoder.decode(BudgetLedgerSnapshot.self, from: payload)
            try db.execute(
                "UPDATE budget_ledgers SET revision = revision + 1, payload_version = 1, payload = ? WHERE run_id = ?",
                [.blob(payload), .text(runID.description)]
            )
        }
        return ledger
    }

    private func reserve(
        _ reservation: BudgetReservation,
        runID: AgentRunID,
        ledger: BudgetLedgerSnapshot,
        db: SQLiteConnection
    ) throws -> (ledger: BudgetLedgerSnapshot, changed: Bool) {
        let payload = try encoder.encode(reservation)
        if let row = try db.rows(
            "SELECT run_id, state, payload FROM budget_reservations WHERE reservation_id = ?",
            [.text(reservation.id.description)]
        ).first {
            guard row[0].text == runID.description,
                  row[1].text == "reserved",
                  row[2].blob == payload
            else { throw RuntimeRepositoryError.budgetOperationConflict(reservation.id) }
            return (try ledger.reserving(reservation), false)
        }
        let next = try ledger.reserving(reservation)
        try db.execute(
            """
            INSERT INTO budget_reservations(
                reservation_id, run_id, state, maximum_digest, payload_version, payload
            ) VALUES(?, ?, 'reserved', ?, 1, ?)
            """,
            [
                .text(reservation.id.description), .text(runID.description),
                .text(StableDigest.sha256(payload).rawValue), .blob(payload),
            ]
        )
        return (next, true)
    }

    private func settle(
        _ reservationID: BudgetReservationID,
        actualUsage: AgentUsage,
        runID: AgentRunID,
        ledger: BudgetLedgerSnapshot,
        db: SQLiteConnection
    ) throws -> (ledger: BudgetLedgerSnapshot, changed: Bool) {
        let actualPayload = try encoder.encode(actualUsage)
        guard let row = try db.rows(
            "SELECT run_id, state, actual_usage FROM budget_reservations WHERE reservation_id = ?",
            [.text(reservationID.description)]
        ).first else { throw RuntimeRepositoryError.budgetOperationConflict(reservationID) }
        guard row[0].text == runID.description else {
            throw RuntimeRepositoryError.budgetOperationConflict(reservationID)
        }
        switch row[1].text {
        case "settled":
            guard row[2].blob == actualPayload else {
                throw RuntimeRepositoryError.budgetOperationConflict(reservationID)
            }
            return (ledger, false)
        case "reserved":
            let next = try ledger.settling(reservationID: reservationID, actualUsage: actualUsage)
            try db.execute(
                "UPDATE budget_reservations SET state = 'settled', actual_usage = ? WHERE reservation_id = ?",
                [.blob(actualPayload), .text(reservationID.description)]
            )
            return (next, true)
        default:
            throw RuntimeRepositoryError.budgetOperationConflict(reservationID)
        }
    }

    private func release(
        _ reservationID: BudgetReservationID,
        runID: AgentRunID,
        ledger: BudgetLedgerSnapshot,
        db: SQLiteConnection
    ) throws -> (ledger: BudgetLedgerSnapshot, changed: Bool) {
        guard let row = try db.rows(
            "SELECT run_id, state FROM budget_reservations WHERE reservation_id = ?",
            [.text(reservationID.description)]
        ).first, row[0].text == runID.description else {
            throw RuntimeRepositoryError.budgetOperationConflict(reservationID)
        }
        switch row[1].text {
        case "released": return (ledger, false)
        case "reserved":
            let next = try ledger.releasing(reservationID: reservationID)
            try db.execute(
                "UPDATE budget_reservations SET state = 'released' WHERE reservation_id = ?",
                [.text(reservationID.description)]
            )
            return (next, true)
        default: throw RuntimeRepositoryError.budgetOperationConflict(reservationID)
        }
    }

    private func budgetLedger(for runID: AgentRunID, db: SQLiteConnection) throws -> BudgetLedgerSnapshot? {
        guard let payload = try db.rows(
            "SELECT payload FROM budget_ledgers WHERE run_id = ?",
            [.text(runID.description)]
        ).first?.first?.blob else { return nil }
        let ledger = try AgentWireDecoder.decode(BudgetLedgerSnapshot.self, from: payload)
        let reservations = try db.rows(
            "SELECT payload FROM budget_reservations WHERE run_id = ? AND state = 'reserved' ORDER BY reservation_id",
            [.text(runID.description)]
        ).map { row -> BudgetReservation in
            guard let payload = row[0].blob else {
                throw RuntimeRepositoryError.durableFactCorrupt("reservation payload is unavailable")
            }
            return try AgentWireDecoder.decode(BudgetReservation.self, from: payload)
        }
        guard reservations == ledger.reservations else {
            throw RuntimeRepositoryError.durableFactCorrupt("ledger and reservation rows disagree")
        }
        return ledger
    }

    private func loadBudgetLedgerFromConnection(for runID: AgentRunID) throws -> BudgetLedgerSnapshot? {
        guard let db = connection else { return nil }
        return try budgetLedger(for: runID, db: db)
    }

    private func boundedCommandPayload(_ envelope: AgentCommandEnvelope) throws -> Data {
        let data = try encoder.encode(envelope)
        let decoded = try AgentCommandEnvelope.decodeUntrusted(
            from: data,
            limits: Self.commandDecodingLimits
        )
        guard decoded == envelope else {
            throw RuntimeRepositoryError.durableFactCorrupt("command envelope is noncanonical")
        }
        return data
    }

    private func boundedCommandReceiptPayload(_ envelope: AgentCommandReceiptEnvelope) throws -> Data {
        let data = try encoder.encode(envelope)
        let decoded = try AgentCommandReceiptEnvelope.decodeUntrusted(
            from: data,
            limits: Self.commandDecodingLimits
        )
        guard decoded == envelope else {
            throw RuntimeRepositoryError.durableFactCorrupt("command receipt envelope is noncanonical")
        }
        return data
    }

    private func command(_ commandID: AgentCommandID, db: SQLiteConnection) throws -> DurableAgentCommand? {
        guard let row = try db.rows(
            """
            SELECT admission_sequence, fingerprint, state, admitted_at, claim_owner,
                   claim_expires_at, lease_token, lease_generation, attempt_count, payload,
                   receipt, completed_at
            FROM agent_commands WHERE command_id = ?
            """,
            [.text(commandID.description)]
        ).first else { return nil }
        guard let rawSequence = row[0].integer, rawSequence > 0,
              let rawFingerprint = row[1].text,
              let fingerprint = try? StableDigest(rawValue: rawFingerprint),
              let rawState = row[2].text,
              let state = DurableAgentCommandState(rawValue: rawState),
              let admittedAt = row[3].integer,
              let rawGeneration = row[7].integer, rawGeneration >= 0,
              let rawAttempts = row[8].integer, rawAttempts >= 0,
              rawAttempts <= Int64(UInt32.max),
              let payload = row[9].blob
        else { throw RuntimeRepositoryError.durableFactCorrupt("invalid command row") }
        let envelope = try AgentCommandEnvelope.decodeUntrusted(
            from: payload,
            limits: Self.commandDecodingLimits
        )
        guard envelope.payload.commandID == commandID else {
            throw RuntimeRepositoryError.durableFactCorrupt("command identity differs from payload")
        }
        let receipt = try row[10].blob.map {
            try AgentCommandReceiptEnvelope.decodeUntrusted(
                from: $0,
                limits: Self.commandDecodingLimits
            )
        }
        let claimOwner = row[4].text
        let claimExpiresAt = row[5].integer.map(AgentTimestamp.init(rawValue:))
        let leaseToken = row[6].text.flatMap(UUID.init(uuidString:))
        let completedAt = row[11].integer.map(AgentTimestamp.init(rawValue:))
        switch state {
        case .pending:
            guard claimOwner == nil, claimExpiresAt == nil, leaseToken == nil,
                  receipt == nil, completedAt == nil
            else {
                throw RuntimeRepositoryError.durableFactCorrupt("pending command has terminal fields")
            }
        case .claimed:
            guard claimOwner != nil, claimExpiresAt != nil, leaseToken != nil,
                  rawGeneration > 0, receipt == nil, completedAt == nil
            else {
                throw RuntimeRepositoryError.durableFactCorrupt("claimed command has invalid lease")
            }
        case .completed:
            guard claimOwner == nil, claimExpiresAt == nil, leaseToken == nil,
                  rawGeneration > 0, receipt != nil, completedAt != nil
            else {
                throw RuntimeRepositoryError.durableFactCorrupt("completed command lacks receipt")
            }
        }
        return DurableAgentCommand(
            admissionSequence: UInt64(rawSequence),
            envelope: envelope,
            fingerprint: fingerprint,
            state: state,
            admittedAt: AgentTimestamp(rawValue: admittedAt),
            claimOwner: claimOwner,
            claimExpiresAt: claimExpiresAt,
            leaseToken: leaseToken,
            leaseGeneration: UInt64(rawGeneration),
            attemptCount: UInt32(rawAttempts),
            receipt: receipt,
            completedAt: completedAt
        )
    }

    private func isValidLeaseOwner(_ owner: String) -> Bool {
        !owner.isEmpty && owner.utf8.count <= 128 && owner.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f
        }
    }

    private func runFacts(for runID: AgentRunID, db: SQLiteConnection) throws -> RuntimeRunFacts? {
        guard let projection = try projection(for: runID, db: db) else { return nil }
        let conversationID = try db.scalarText(
            "SELECT conversation_id FROM runs WHERE run_id = ?",
            [.text(runID.description)]
        ).flatMap(ConversationID.init)
        return RuntimeRunFacts(
            projection: projection,
            conversationID: conversationID,
            submission: try submission(for: runID, db: db),
            budgetLedger: try budgetLedger(for: runID, db: db)
        )
    }

    private func submission(for runID: AgentRunID, db: SQLiteConnection) throws -> RuntimeSubmissionRecord? {
        guard let row = try db.rows(
            """
            SELECT submission_command_id, request_payload, execution_handle_id,
                   input_snapshot_payload, fingerprint
            FROM run_submissions WHERE run_id = ?
            """,
            [.text(runID.description)]
        ).first else { return nil }
        guard let commandID = row[0].text.flatMap(AgentCommandID.init),
              let requestPayload = row[1].blob,
              let handleID = row[2].text.flatMap(AgentExecutionHandleID.init),
              let inputPayload = row[3].blob,
              let rawFingerprint = row[4].text,
              let fingerprint = try? StableDigest(rawValue: rawFingerprint)
        else { throw RuntimeRepositoryError.durableFactCorrupt("invalid submission row") }
        let request = try AgentRequestEnvelope.decodeUntrusted(from: requestPayload)
        let input = try AgentWireDecoder.decode(AgentStableBoundaryReference.self, from: inputPayload)
        guard request.payload.runID == runID else {
            throw RuntimeRepositoryError.durableFactCorrupt("submission request owns another run")
        }
        return RuntimeSubmissionRecord(
            commandID: commandID,
            request: request,
            executionHandleID: handleID,
            inputSnapshot: input,
            fingerprint: fingerprint
        )
    }

    private func compiledManifests(
        for runID: AgentRunID,
        db: SQLiteConnection
    ) throws -> [DurableCompiledManifest] {
        try db.rows(
            "SELECT manifest_id, step_id, payload FROM compiled_manifests WHERE run_id = ? ORDER BY rowid",
            [.text(runID.description)]
        ).map { row in
            guard let eventID = row[0].text.flatMap(AgentEventID.init),
                  let stepID = row[1].text.flatMap(AgentStepID.init),
                  let payload = row[2].blob
            else { throw RuntimeRepositoryError.durableFactCorrupt("invalid compiled manifest row") }
            return DurableCompiledManifest(
                eventID: eventID,
                runID: runID,
                stepID: stepID,
                reference: try AgentWireDecoder.decode(AgentStableBoundaryReference.self, from: payload)
            )
        }
    }

    private func approvals(for runID: AgentRunID, db: SQLiteConnection) throws -> [DurableApproval] {
        try db.rows(
            "SELECT state, request_payload, receipt_payload FROM approvals WHERE run_id = ? ORDER BY rowid",
            [.text(runID.description)]
        ).map { row in
            guard let rawState = row[0].text,
                  let state = DurableApprovalState(rawValue: rawState),
                  let requestPayload = row[1].blob
            else { throw RuntimeRepositoryError.durableFactCorrupt("invalid approval row") }
            let request = try AgentWireDecoder.decode(AgentApprovalRequest.self, from: requestPayload)
            let receipt = try row[2].blob.map {
                try AgentWireDecoder.decode(ApprovalReceipt.self, from: $0)
            }
            guard request.prepared.runID == runID,
                  (state == .decided) == (receipt != nil)
            else { throw RuntimeRepositoryError.durableFactCorrupt("approval state differs from payload") }
            return DurableApproval(runID: runID, state: state, request: request, receipt: receipt)
        }
    }

    private func interactions(for runID: AgentRunID, db: SQLiteConnection) throws -> [DurableInteraction] {
        try db.rows(
            "SELECT state, request_payload, response_payload FROM interactions WHERE run_id = ? ORDER BY rowid",
            [.text(runID.description)]
        ).map { row in
            guard let rawState = row[0].text,
                  let state = DurableInteractionState(rawValue: rawState),
                  let requestPayload = row[1].blob
            else { throw RuntimeRepositoryError.durableFactCorrupt("invalid interaction row") }
            let request = try AgentWireDecoder.decode(UserInputRequest.self, from: requestPayload)
            let response = try row[2].blob.map {
                try AgentWireDecoder.decode(AgentStableBoundaryReference.self, from: $0)
            }
            guard request.runID == runID,
                  (state == .responded) == (response != nil)
            else { throw RuntimeRepositoryError.durableFactCorrupt("interaction state differs from payload") }
            return DurableInteraction(runID: runID, state: state, request: request, response: response)
        }
    }

    private func toolInvocations(
        for runID: AgentRunID,
        db: SQLiteConnection
    ) throws -> [DurableToolInvocation] {
        try db.rows(
            "SELECT state, intent_payload, outcome_payload FROM tool_invocations WHERE run_id = ? ORDER BY rowid",
            [.text(runID.description)]
        ).map { row in
            guard let rawState = row[0].text,
                  let state = DurableToolInvocationState(rawValue: rawState),
                  let requestPayload = row[1].blob
            else { throw RuntimeRepositoryError.durableFactCorrupt("invalid tool invocation row") }
            let request = try AgentWireDecoder.decode(PreparedExternalOperationRequest.self, from: requestPayload)
            let outcome = try row[2].blob.map {
                try AgentWireDecoder.decode(AgentToolInvocationOutcome.self, from: $0)
            }
            guard request.runID == runID,
                  request.invocationID != nil,
                  (state == .completed) == (outcome != nil)
            else { throw RuntimeRepositoryError.durableFactCorrupt("tool state differs from payload") }
            return DurableToolInvocation(runID: runID, state: state, request: request, outcome: outcome)
        }
    }

    private func recoveryFacts(for runID: AgentRunID, db: SQLiteConnection) throws -> RuntimeRecoveryFacts? {
        guard let run = try runFacts(for: runID, db: db) else { return nil }
        let tools = try toolInvocations(for: runID, db: db)
        let approvalFacts = try approvals(for: runID, db: db)
        let interactionFacts = try interactions(for: runID, db: db)
        return RuntimeRecoveryFacts(
            run: run,
            outstandingReservations: run.budgetLedger?.reservations ?? [],
            toolInvocations: tools,
            pendingApprovalIDs: approvalFacts.compactMap { $0.state == .requested ? $0.request.id : nil },
            pendingInteractionIDs: interactionFacts.compactMap { $0.state == .requested ? $0.request.id : nil },
            hasIncompleteModelAttempt: run.projection.state == .generating
                || run.projection.state == .synthesizing
        )
    }

    private func derivedRecoveryDirective(from facts: RuntimeRecoveryFacts) -> RecoveryDirective {
        let disposition: RecoveryDisposition
        if facts.run.projection.isTerminal {
            disposition = .alreadyStable
        } else if facts.toolInvocations.contains(where: { invocation in
            guard case .uncertain? = invocation.outcome else { return false }
            return true
        }) {
            disposition = .waitingForReconciliation
        } else if let pending = facts.toolInvocations.first(where: { $0.state == .prepared }) {
            disposition = switch pending.request.plan.idempotency {
            case .pureRead: .retryPureRead
            case .idempotencyKeyRequired: .retryIdempotentWrite
            case .reconciliationAvailable, .nonIdempotent: .waitingForReconciliation
            }
        } else if facts.hasIncompleteModelAttempt {
            disposition = .discardIncompleteModelAttempt
        } else if facts.run.projection.state == .executingTools {
            // Executing without a surviving prepared fact cannot be proven effect-free.
            disposition = .waitingForReconciliation
        } else {
            disposition = .alreadyStable
        }
        return RecoveryDirective(
            runID: facts.run.projection.runID,
            disposition: disposition,
            stableSequence: facts.run.projection.eventCount,
            requiresExplicitResume: true
        )
    }

    private func isStableBoundaryEvent(_ event: AgentEvent) -> Bool {
        switch event {
        case .runInputSnapshotCommitted, .compiledManifestCommitted, .validatedActionCommitted,
             .userInputResponseCommitted, .modelAttemptOutcome, .toolIntentRecorded,
             .toolOutcomeRecorded, .approvalRequested, .approvalDecided,
             .userInputRequested, .artifactCommitted, .usageUpdated, .terminal:
            true
        case .statusChanged, .diagnostic:
            false
        }
    }

    private func mutationKey(_ identity: RunJournalMutationIdentity) -> (kind: String, id: String) {
        switch identity {
        case .command(let id): ("command", id.description)
        case .outcome(let id): ("outcome", id.description)
        }
    }

    private func existingConnection() throws -> SQLiteConnection? {
        if let connection { return connection }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let walExists = FileManager.default.fileExists(atPath: databaseURL.path + "-wal")
        let shmExists = FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
        guard walExists == shmExists else {
            throw SQLiteStoreError.unavailable("incomplete WAL sidecars require explicit open-for-write recovery")
        }
        let db = try SQLiteConnection(url: databaseURL, create: false, readOnly: true, immutable: !walExists)
        try configureReadOnly(db)
        try validateSchema(db)
        connection = db
        connectionIsWritable = false
        return db
    }

    private func writableConnection() throws -> SQLiteConnection {
        if let connection, connectionIsWritable { return connection }
        if let connection {
            connection.close()
            self.connection = nil
            connectionIsWritable = false
        }
        try inject(.beforeOpenForWrite)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existed = FileManager.default.fileExists(atPath: databaseURL.path)
        let db = try SQLiteConnection(url: databaseURL, create: true)
        do {
            guard let rawVersion = try db.scalarInt("PRAGMA user_version") else {
                throw SQLiteStoreError.corrupt
            }
            let version = Int32(rawVersion)
            if version > Self.schemaVersion { throw SQLiteStoreError.unsupportedSchema(version) }
            if existed, version > 0, version < Self.schemaVersion {
                let backup = databaseURL.deletingPathExtension().appendingPathExtension("migration-v\(version).sqlite3")
                try db.consistentBackup(to: backup)
                lastMigrationBackupURL = backup
                try inject(.afterMigrationBackup)
            }
            try configure(db)
            try migrate(db, from: version)
            try secureStoreFiles()
            connection = db
            connectionIsWritable = true
            return db
        } catch {
            db.close()
            if existed, let backup = lastMigrationBackupURL {
                throw SQLiteStoreError.migrationFailed(backup: backup, message: String(describing: error))
            }
            throw error
        }
    }

    private func configure(_ db: SQLiteConnection) throws {
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = FULL")
        try db.execute("PRAGMA secure_delete = ON")
        try db.execute("PRAGMA trusted_schema = OFF")
        try db.execute("PRAGMA writable_schema = OFF")
        try db.execute("PRAGMA cell_size_check = ON")
        try db.execute("PRAGMA busy_timeout = 5000")
        guard try db.scalarInt("PRAGMA writable_schema") == 0,
              try db.scalarInt("PRAGMA cell_size_check") == 1
        else { throw SQLiteStoreError.unavailable("SQLite defensive PRAGMAs unavailable") }
        guard try db.scalarText("PRAGMA quick_check") == "ok" else { throw SQLiteStoreError.corrupt }
    }

    private func configureReadOnly(_ db: SQLiteConnection) throws {
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA trusted_schema = OFF")
        try db.execute("PRAGMA writable_schema = OFF")
        try db.execute("PRAGMA cell_size_check = ON")
        try db.execute("PRAGMA busy_timeout = 5000")
        guard try db.scalarText("PRAGMA quick_check") == "ok" else { throw SQLiteStoreError.corrupt }
    }

    private func secureStoreFiles() throws {
        for url in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
            where FileManager.default.fileExists(atPath: url.path)
        {
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            #endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            do { try mutableURL.setResourceValues(values) }
            catch { throw SQLiteStoreError.dataProtectionUnavailable(String(describing: error)) }
        }
    }

    private func validateSchema(_ db: SQLiteConnection) throws {
        guard let rawVersion = try db.scalarInt("PRAGMA user_version") else {
            throw SQLiteStoreError.corrupt
        }
        let version = Int32(rawVersion)
        guard version == Self.schemaVersion else { throw SQLiteStoreError.unsupportedSchema(version) }
    }

    private func migrate(_ db: SQLiteConnection, from version: Int32) throws {
        guard version < Self.schemaVersion else { return }
        try db.execute("BEGIN EXCLUSIVE")
        do {
            for sql in Self.schemaStatements { try db.execute(sql) }
            try addVersionThreeColumnsIfNeeded(db)
            try backfillVersionThreeTypedFacts(db)
            guard try db.rows("PRAGMA foreign_key_check").isEmpty,
                  try db.scalarText("PRAGMA quick_check") == "ok"
            else { throw SQLiteStoreError.corrupt }
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private func addVersionThreeColumnsIfNeeded(_ db: SQLiteConnection) throws {
        let additions: [(table: String, column: String, declaration: String)] = [
            ("mutation_receipts", "ledger_payload", "BLOB"),
            ("compiled_manifests", "payload", "BLOB"),
            ("tool_invocations", "intent_payload", "BLOB"),
            ("tool_invocations", "outcome_payload", "BLOB"),
            ("approvals", "request_payload", "BLOB"),
            ("approvals", "receipt_payload", "BLOB"),
            ("interactions", "request_payload", "BLOB"),
            ("interactions", "response_payload", "BLOB"),
            ("budget_reservations", "payload", "BLOB"),
            ("budget_reservations", "actual_usage", "BLOB"),
        ]
        for addition in additions {
            if try !hasColumn(addition.column, in: addition.table, db: db) {
                try db.execute(
                    "ALTER TABLE \(addition.table) ADD COLUMN \(addition.column) \(addition.declaration)"
                )
            }
        }
    }

    private func hasColumn(_ column: String, in table: String, db: SQLiteConnection) throws -> Bool {
        try db.rows("PRAGMA table_info(\(table))").contains { row in
            row.count > 1 && row[1].text == column
        }
    }

    /// Version two already contains canonical event envelopes, so typed current-state columns can
    /// be rebuilt without trusting the lossy legacy materialized payload column.
    private func backfillVersionThreeTypedFacts(_ db: SQLiteConnection) throws {
        let rows = try db.rows("SELECT payload FROM events ORDER BY run_id, sequence")
        for row in rows {
            guard let payload = row[0].blob else { throw SQLiteStoreError.corrupt }
            let envelope = try AgentEventEnvelope.decodeUntrusted(from: payload)
            let record = envelope.payload
            switch record.event {
            case .runInputSnapshotCommitted(let reference):
                try db.execute(
                    """
                    INSERT OR REPLACE INTO run_input_snapshots(
                        run_id, format_version, digest, artifact_id, payload_version, payload
                    ) VALUES(?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(record.runID.description), .integer(Int64(reference.formatVersion)),
                        .text(reference.digest.rawValue), sqliteText(reference.artifactID?.description),
                        .integer(Int64(AgentStableBoundaryReference.currentPayloadVersion)),
                        .blob(try encoder.encode(reference)),
                    ]
                )
            case .compiledManifestCommitted(_, let reference):
                try db.execute(
                    "UPDATE compiled_manifests SET payload = ? WHERE manifest_id = ?",
                    [.blob(try encoder.encode(reference)), .text(record.eventID.description)]
                )
            case .toolIntentRecorded(let request):
                if let invocationID = request.invocationID {
                    try db.execute(
                        "UPDATE tool_invocations SET intent_payload = ? WHERE invocation_id = ?",
                        [.blob(try encoder.encode(request)), .text(invocationID.description)]
                    )
                }
            case .toolOutcomeRecorded(let invocationID, let outcome):
                try db.execute(
                    "UPDATE tool_invocations SET outcome_payload = ? WHERE invocation_id = ?",
                    [.blob(try encoder.encode(outcome)), .text(invocationID.description)]
                )
            case .approvalRequested(let request):
                try db.execute(
                    "UPDATE approvals SET request_payload = ? WHERE approval_id = ?",
                    [.blob(try encoder.encode(request)), .text(request.id.description)]
                )
            case .approvalDecided(let receipt):
                try db.execute(
                    "UPDATE approvals SET receipt_payload = ? WHERE approval_id = ?",
                    [.blob(try encoder.encode(receipt)), .text(receipt.id.description)]
                )
            case .userInputRequested(let request):
                try db.execute(
                    "UPDATE interactions SET request_payload = ? WHERE interaction_id = ?",
                    [.blob(try encoder.encode(request)), .text(request.id.description)]
                )
            case .userInputResponseCommitted(let requestID, let reference):
                try db.execute(
                    "UPDATE interactions SET response_payload = ? WHERE interaction_id = ?",
                    [.blob(try encoder.encode(reference)), .text(requestID.description)]
                )
            default:
                break
            }
        }
    }

    private func inject(_ point: SQLiteJournalFaultPoint) throws {
        do { try faultInjector?(point) }
        catch let error as SQLiteStoreError { throw error }
        catch { throw SQLiteStoreError.injected(point) }
    }

    private func sqliteText(_ value: String?) -> SQLiteValue {
        guard let value else { return .null }
        return .text(value)
    }

    private struct MessageProjectionCommit {
        let message: JournalMessageReference
        let outbox: ProjectionOutboxItem
    }

    private struct MutationResult {
        let receipt: RunJournalAppendReceipt
        let ledger: BudgetLedgerSnapshot?
    }

    private static let schemaTables = [
        "runs", "events", "mutation_receipts", "messages", "projection_outbox", "steps",
        "model_attempts", "compiled_manifests", "tool_invocations", "approvals", "interactions",
        "budget_reservations", "usage_ledger", "external_claims", "external_intents",
        "external_outcomes", "artifact_metadata", "artifact_refs", "artifact_deletion_intents",
        "deletion_intents", "run_submissions", "run_input_snapshots", "budget_ledgers",
        "agent_commands",
    ]

    private static let schemaStatements: [String] = [
        "CREATE TABLE IF NOT EXISTS runs(run_id TEXT PRIMARY KEY, conversation_id TEXT, request_id TEXT NOT NULL UNIQUE, execution_handle_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL, state_version INTEGER NOT NULL CHECK(state_version > 0), next_sequence INTEGER NOT NULL CHECK(next_sequence > 0), terminal_event_id TEXT UNIQUE, last_digest TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deletion_blocked INTEGER NOT NULL DEFAULT 0 CHECK(deletion_blocked IN (0,1))) STRICT",
        "CREATE TABLE IF NOT EXISTS events(event_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, sequence INTEGER NOT NULL CHECK(sequence > 0), state_version INTEGER NOT NULL CHECK(state_version > 0), timestamp INTEGER NOT NULL, record_digest TEXT NOT NULL UNIQUE, previous_digest TEXT, payload_version INTEGER NOT NULL CHECK(payload_version > 0), payload BLOB NOT NULL, is_terminal INTEGER NOT NULL CHECK(is_terminal IN (0,1)), UNIQUE(run_id, sequence)) STRICT",
        "CREATE UNIQUE INDEX IF NOT EXISTS one_terminal_event_per_run ON events(run_id) WHERE is_terminal = 1",
        "CREATE TABLE IF NOT EXISTS mutation_receipts(identity_kind TEXT NOT NULL, identity_id TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, fingerprint TEXT NOT NULL, event_ids BLOB NOT NULL, ledger_payload BLOB, PRIMARY KEY(identity_kind, identity_id)) STRICT",
        "CREATE TABLE IF NOT EXISTS messages(message_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, role TEXT NOT NULL, body_digest TEXT NOT NULL, body_artifact_id TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(run_id, role)) STRICT",
        "CREATE TABLE IF NOT EXISTS projection_outbox(idempotency_key TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, run_id TEXT, message_id TEXT, kind TEXT NOT NULL, payload_digest TEXT NOT NULL, payload_artifact_id TEXT, created_at INTEGER NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0, claim_owner TEXT, claim_expires_at INTEGER, delivered_at INTEGER) STRICT",
        "CREATE TABLE IF NOT EXISTS steps(step_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS model_attempts(attempt_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, event_id TEXT NOT NULL UNIQUE, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS compiled_manifests(manifest_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, step_id TEXT NOT NULL, digest TEXT NOT NULL, artifact_id TEXT, payload_version INTEGER NOT NULL, payload BLOB) STRICT",
        "CREATE TABLE IF NOT EXISTS tool_invocations(invocation_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, state TEXT NOT NULL CHECK(state IN ('prepared','completed')), payload_version INTEGER NOT NULL, payload BLOB NOT NULL, intent_payload BLOB, outcome_payload BLOB) STRICT",
        "CREATE TABLE IF NOT EXISTS approvals(approval_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, state TEXT NOT NULL CHECK(state IN ('requested','decided')), payload_version INTEGER NOT NULL, payload BLOB NOT NULL, request_payload BLOB, receipt_payload BLOB) STRICT",
        "CREATE TABLE IF NOT EXISTS interactions(interaction_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, state TEXT NOT NULL CHECK(state IN ('requested','responded')), creation_state_version INTEGER NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL, request_payload BLOB, response_payload BLOB) STRICT",
        "CREATE TABLE IF NOT EXISTS budget_reservations(reservation_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, state TEXT NOT NULL CHECK(state IN ('reserved','settled','released')), maximum_digest TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB, actual_usage BLOB) STRICT",
        "CREATE TABLE IF NOT EXISTS usage_ledger(entry_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, event_id TEXT NOT NULL UNIQUE, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS external_claims(claim_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, invocation_id TEXT, claim_kind TEXT NOT NULL, payload_digest TEXT NOT NULL, payload_version INTEGER NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS external_intents(intent_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, invocation_id TEXT, idempotency TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS external_outcomes(outcome_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, invocation_id TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS artifact_metadata(artifact_id TEXT PRIMARY KEY, run_id TEXT REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, content_digest TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count >= 0), mime_type TEXT NOT NULL, locator TEXT NOT NULL, retention TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS artifact_refs(artifact_id TEXT NOT NULL, owner_kind TEXT NOT NULL, owner_id TEXT NOT NULL, PRIMARY KEY(artifact_id, owner_kind, owner_id)) STRICT",
        "CREATE TABLE IF NOT EXISTS artifact_deletion_intents(intent_id TEXT PRIMARY KEY, artifact_id TEXT NOT NULL, created_at INTEGER NOT NULL, completed_at INTEGER) STRICT",
        "CREATE TABLE IF NOT EXISTS deletion_intents(intent_id TEXT PRIMARY KEY, scope TEXT NOT NULL, conversation_id TEXT, created_at INTEGER NOT NULL, completed_at INTEGER) STRICT",
        "CREATE TABLE IF NOT EXISTS run_submissions(run_id TEXT PRIMARY KEY REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, submission_command_id TEXT NOT NULL UNIQUE, request_id TEXT NOT NULL UNIQUE, execution_handle_id TEXT NOT NULL UNIQUE, request_payload_version INTEGER NOT NULL CHECK(request_payload_version > 0), request_payload BLOB NOT NULL, input_snapshot_payload_version INTEGER NOT NULL CHECK(input_snapshot_payload_version > 0), input_snapshot_payload BLOB NOT NULL, fingerprint TEXT NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS run_input_snapshots(run_id TEXT PRIMARY KEY REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, format_version INTEGER NOT NULL CHECK(format_version > 0), digest TEXT NOT NULL, artifact_id TEXT, payload_version INTEGER NOT NULL CHECK(payload_version > 0), payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS budget_ledgers(run_id TEXT PRIMARY KEY REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, revision INTEGER NOT NULL CHECK(revision > 0), payload_version INTEGER NOT NULL CHECK(payload_version > 0), payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS agent_commands(admission_sequence INTEGER PRIMARY KEY AUTOINCREMENT, command_id TEXT NOT NULL UNIQUE, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, fingerprint TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','claimed','completed')), payload_version INTEGER NOT NULL CHECK(payload_version > 0), payload BLOB NOT NULL CHECK(length(payload) <= 262144), admitted_at INTEGER NOT NULL, claim_owner TEXT, claim_expires_at INTEGER, lease_token TEXT, lease_generation INTEGER NOT NULL DEFAULT 0 CHECK(lease_generation >= 0), attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count >= 0), receipt_payload_version INTEGER, receipt BLOB CHECK(receipt IS NULL OR length(receipt) <= 262144), completed_at INTEGER, CHECK((state = 'pending' AND claim_owner IS NULL AND claim_expires_at IS NULL AND lease_token IS NULL AND receipt IS NULL AND completed_at IS NULL) OR (state = 'claimed' AND claim_owner IS NOT NULL AND claim_expires_at IS NOT NULL AND lease_token IS NOT NULL AND lease_generation > 0 AND receipt IS NULL AND completed_at IS NULL) OR (state = 'completed' AND claim_owner IS NULL AND claim_expires_at IS NULL AND lease_token IS NULL AND lease_generation > 0 AND receipt IS NOT NULL AND receipt_payload_version IS NOT NULL AND completed_at IS NOT NULL))) STRICT",
        "CREATE INDEX IF NOT EXISTS agent_commands_fair_claim ON agent_commands(state, admission_sequence)",
        "CREATE INDEX IF NOT EXISTS agent_commands_lease_expiry ON agent_commands(claim_expires_at, admission_sequence) WHERE state = 'claimed'",
        "CREATE UNIQUE INDEX IF NOT EXISTS one_claimed_command_per_run ON agent_commands(run_id) WHERE state = 'claimed'",
    ]
}
