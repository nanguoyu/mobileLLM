// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import SQLite3

/// Single-actor, single-connection canonical journal. Construction is side-effect free; the file is
/// created only by `openForWrite` or a mutation.
public actor SQLiteRunJournal: RunJournal {
    public static let schemaVersion: Int32 = 2

    private let databaseURL: URL
    private let faultInjector: SQLiteJournalFaultInjector?
    private var connection: SQLiteConnection?
    private var connectionIsWritable = false
    private var lastMigrationBackupURL: URL?
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

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
            return try decoder.decode(AgentEventEnvelope.self, from: data)
        }
        return try RunJournalEventPage(
            events: events,
            nextCursor: events.last?.payload.cursor,
            reachedEnd: reachedEnd
        )
    }

    public func append(_ request: RunJournalAppendRequest) async throws -> RunJournalAppendReceipt {
        try mutate(request: request, projectionCommit: nil)
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
        )
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

    /// Explicit-only recovery classification. This method never appends, executes, or resumes work.
    public func recoveryDirective(
        for runID: AgentRunID,
        interruptedOperation: InterruptedOperationKind
    ) throws -> RecoveryDirective? {
        try inject(.beforeRecovery)
        guard let db = try existingConnection(), let projection = try projection(for: runID, db: db) else {
            return nil
        }
        let disposition: RecoveryDisposition = switch interruptedOperation {
        case .modelAttempt: .discardIncompleteModelAttempt
        case .pureRead: .retryPureRead
        case .idempotentWrite: .retryIdempotentWrite
        case .nonIdempotentWrite: .waitingForReconciliation
        case .stable: .alreadyStable
        }
        return RecoveryDirective(
            runID: runID,
            disposition: disposition,
            stableSequence: projection.eventCount,
            requiresExplicitResume: true
        )
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

    public func recordBudgetReservation(runID: AgentRunID, reservation: BudgetReservation) throws {
        let db = try writableConnection()
        let payload = try encoder.encode(reservation)
        try db.execute(
            "INSERT INTO budget_reservations(reservation_id, run_id, state, maximum_digest, payload_version) VALUES(?, ?, 'reserved', ?, 1)",
            [.text(reservation.id.description), .text(runID.description), .text(StableDigest.sha256(payload).rawValue)]
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
        projectionCommit: MessageProjectionCommit?
    ) throws -> RunJournalAppendReceipt {
        let db = try writableConnection()
        let fingerprint = try mutationFingerprint(request)
        let identity = mutationKey(request.mutationIdentity)
        try inject(.beforeTransaction)
        try db.execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.execute("ROLLBACK") } }
        try inject(.afterTransactionBegin)

        if let existing = try db.rows(
            "SELECT fingerprint, event_ids FROM mutation_receipts WHERE identity_kind = ? AND identity_id = ?",
            [.text(identity.kind), .text(identity.id)]
        ).first {
            guard let projection = try projection(for: request.runID, db: db) else {
                throw SQLiteStoreError.corrupt
            }
            if existing[0].text == fingerprint.rawValue, let eventData = existing[1].blob {
                let eventIDs = try decoder.decode([AgentEventID].self, from: eventData)
                try db.execute("COMMIT")
                committed = true
                return try RunJournalAppendReceipt(
                    mutationIdentity: request.mutationIdentity,
                    disposition: .replayed,
                    projection: projection,
                    eventIDs: eventIDs
                )
            }
            try db.execute("COMMIT")
            committed = true
            return try RunJournalAppendReceipt(
                mutationIdentity: request.mutationIdentity,
                disposition: .rejected,
                projection: projection,
                diagnostic: .duplicateCommandConflict
            )
        }

        let prior = try projection(for: request.runID, db: db)
        if let prior {
            if prior.isTerminal {
                try db.execute("COMMIT"); committed = true
                return try RunJournalAppendReceipt(
                    mutationIdentity: request.mutationIdentity,
                    disposition: .rejected,
                    projection: prior,
                    diagnostic: .terminalRunImmutable
                )
            }
            if prior.stateVersion != request.expectedRunStateVersion {
                try db.execute("COMMIT"); committed = true
                return try RunJournalAppendReceipt(
                    mutationIdentity: request.mutationIdentity,
                    disposition: .stale,
                    projection: prior,
                    diagnostic: .staleExpectedVersion
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
        for envelope in request.events { try insert(envelope, db: db) }
        try inject(.afterEventInsert)

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
        let eventIDs = request.events.map(\.payload.eventID)
        try db.execute(
            "INSERT INTO mutation_receipts(identity_kind, identity_id, run_id, fingerprint, event_ids) VALUES(?, ?, ?, ?, ?)",
            [.text(identity.kind), .text(identity.id), .text(request.runID.description), .text(fingerprint.rawValue), .blob(try encoder.encode(eventIDs))]
        )
        try inject(.beforeCommit)
        try db.execute("COMMIT")
        committed = true
        try inject(.afterCommit)
        return try RunJournalAppendReceipt(
            mutationIdentity: request.mutationIdentity,
            disposition: .appended,
            projection: projected,
            eventIDs: eventIDs
        )
    }

    private func projection(for runID: AgentRunID, db: SQLiteConnection) throws -> AgentRunProjection? {
        let rows = try db.rows(
            "SELECT payload FROM events WHERE run_id = ? ORDER BY sequence",
            [.text(runID.description)]
        )
        let events = try rows.map { row -> AgentEventEnvelope in
            guard let data = row[0].blob else { throw SQLiteStoreError.corrupt }
            return try decoder.decode(AgentEventEnvelope.self, from: data)
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
        case .compiledManifestCommitted(let stepID, let reference):
            try db.execute("INSERT OR IGNORE INTO steps(step_id, run_id, payload_version, payload) VALUES(?, ?, 1, ?)", [.text(stepID.description), .text(record.runID.description), .blob(payload)])
            try db.execute("INSERT OR IGNORE INTO compiled_manifests(manifest_id, run_id, step_id, digest, artifact_id, payload_version) VALUES(?, ?, ?, ?, ?, 1)", [.text(record.eventID.description), .text(record.runID.description), .text(stepID.description), .text(reference.digest.rawValue), sqliteText(reference.artifactID?.description)])
        case .validatedActionCommitted(let stepID, _):
            try db.execute("INSERT OR IGNORE INTO steps(step_id, run_id, payload_version, payload) VALUES(?, ?, 1, ?)", [.text(stepID.description), .text(record.runID.description), .blob(payload)])
        case .modelAttemptOutcome:
            try db.execute("INSERT INTO model_attempts(attempt_id, run_id, event_id, payload_version, payload) VALUES(?, ?, ?, 1, ?)", [.text(record.eventID.description), .text(record.runID.description), .text(record.eventID.description), .blob(payload)])
        case .toolIntentRecorded(let request):
            try db.execute("INSERT INTO external_intents(intent_id, run_id, invocation_id, idempotency, payload_version, payload) VALUES(?, ?, ?, ?, 1, ?)", [.text(record.eventID.description), .text(record.runID.description), sqliteText(request.invocationID?.description), .text(request.plan.idempotency.rawValue), .blob(payload)])
            if let invocationID = request.invocationID {
                try db.execute("INSERT OR REPLACE INTO tool_invocations(invocation_id, run_id, state, payload_version, payload) VALUES(?, ?, 'prepared', 1, ?)", [.text(invocationID.description), .text(record.runID.description), .blob(payload)])
            }
        case .toolOutcomeRecorded(let invocationID, _):
            try db.execute("INSERT INTO external_outcomes(outcome_id, run_id, invocation_id, payload_version, payload) VALUES(?, ?, ?, 1, ?)", [.text(record.eventID.description), .text(record.runID.description), .text(invocationID.description), .blob(payload)])
            try db.execute("UPDATE tool_invocations SET state = 'completed', payload = ? WHERE invocation_id = ?", [.blob(payload), .text(invocationID.description)])
        case .approvalRequested(let request):
            try db.execute("INSERT INTO approvals(approval_id, run_id, state, payload_version, payload) VALUES(?, ?, 'requested', 1, ?)", [.text(request.id.description), .text(record.runID.description), .blob(payload)])
        case .approvalDecided(let receipt):
            try db.execute("INSERT OR REPLACE INTO approvals(approval_id, run_id, state, payload_version, payload) VALUES(?, ?, 'decided', 1, ?)", [.text(receipt.id.description), .text(record.runID.description), .blob(payload)])
        case .userInputRequested(let request):
            try db.execute("INSERT INTO interactions(interaction_id, run_id, state, creation_state_version, payload_version, payload) VALUES(?, ?, 'requested', ?, 1, ?)", [.text(request.id.description), .text(record.runID.description), .integer(Int64(request.creationStateVersion)), .blob(payload)])
        case .userInputResponseCommitted(let requestID, _):
            try db.execute("UPDATE interactions SET state = 'responded', payload = ? WHERE interaction_id = ?", [.blob(payload), .text(requestID.description)])
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

    private func mutationFingerprint(_ request: RunJournalAppendRequest) throws -> StableDigest {
        StableDigest.fingerprint(
            domain: "sqlite-run-journal-mutation.v1",
            components: [
                Data(request.runID.description.utf8),
                Data(String(request.expectedRunStateVersion).utf8),
                try encoder.encode(request.events),
            ]
        )
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
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
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

    private static let schemaTables = [
        "runs", "events", "mutation_receipts", "messages", "projection_outbox", "steps",
        "model_attempts", "compiled_manifests", "tool_invocations", "approvals", "interactions",
        "budget_reservations", "usage_ledger", "external_claims", "external_intents",
        "external_outcomes", "artifact_metadata", "artifact_refs", "artifact_deletion_intents",
        "deletion_intents",
    ]

    private static let schemaStatements: [String] = [
        "CREATE TABLE IF NOT EXISTS runs(run_id TEXT PRIMARY KEY, conversation_id TEXT, request_id TEXT NOT NULL UNIQUE, execution_handle_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL, state_version INTEGER NOT NULL CHECK(state_version > 0), next_sequence INTEGER NOT NULL CHECK(next_sequence > 0), terminal_event_id TEXT UNIQUE, last_digest TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deletion_blocked INTEGER NOT NULL DEFAULT 0 CHECK(deletion_blocked IN (0,1))) STRICT",
        "CREATE TABLE IF NOT EXISTS events(event_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, sequence INTEGER NOT NULL CHECK(sequence > 0), state_version INTEGER NOT NULL CHECK(state_version > 0), timestamp INTEGER NOT NULL, record_digest TEXT NOT NULL UNIQUE, previous_digest TEXT, payload_version INTEGER NOT NULL CHECK(payload_version > 0), payload BLOB NOT NULL, is_terminal INTEGER NOT NULL CHECK(is_terminal IN (0,1)), UNIQUE(run_id, sequence)) STRICT",
        "CREATE UNIQUE INDEX IF NOT EXISTS one_terminal_event_per_run ON events(run_id) WHERE is_terminal = 1",
        "CREATE TABLE IF NOT EXISTS mutation_receipts(identity_kind TEXT NOT NULL, identity_id TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, fingerprint TEXT NOT NULL, event_ids BLOB NOT NULL, PRIMARY KEY(identity_kind, identity_id)) STRICT",
        "CREATE TABLE IF NOT EXISTS messages(message_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, role TEXT NOT NULL, body_digest TEXT NOT NULL, body_artifact_id TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(run_id, role)) STRICT",
        "CREATE TABLE IF NOT EXISTS projection_outbox(idempotency_key TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, run_id TEXT, message_id TEXT, kind TEXT NOT NULL, payload_digest TEXT NOT NULL, payload_artifact_id TEXT, created_at INTEGER NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0, claim_owner TEXT, claim_expires_at INTEGER, delivered_at INTEGER) STRICT",
        "CREATE TABLE IF NOT EXISTS steps(step_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS model_attempts(attempt_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, event_id TEXT NOT NULL UNIQUE, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS compiled_manifests(manifest_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, step_id TEXT NOT NULL, digest TEXT NOT NULL, artifact_id TEXT, payload_version INTEGER NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS tool_invocations(invocation_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, state TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS approvals(approval_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, state TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS interactions(interaction_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, state TEXT NOT NULL, creation_state_version INTEGER NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS budget_reservations(reservation_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, state TEXT NOT NULL, maximum_digest TEXT NOT NULL, payload_version INTEGER NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS usage_ledger(entry_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, event_id TEXT NOT NULL UNIQUE, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS external_claims(claim_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, invocation_id TEXT, claim_kind TEXT NOT NULL, payload_digest TEXT NOT NULL, payload_version INTEGER NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS external_intents(intent_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, invocation_id TEXT, idempotency TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS external_outcomes(outcome_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, invocation_id TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS artifact_metadata(artifact_id TEXT PRIMARY KEY, run_id TEXT REFERENCES runs(run_id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, content_digest TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count >= 0), mime_type TEXT NOT NULL, locator TEXT NOT NULL, retention TEXT NOT NULL, payload_version INTEGER NOT NULL, payload BLOB NOT NULL) STRICT",
        "CREATE TABLE IF NOT EXISTS artifact_refs(artifact_id TEXT NOT NULL, owner_kind TEXT NOT NULL, owner_id TEXT NOT NULL, PRIMARY KEY(artifact_id, owner_kind, owner_id)) STRICT",
        "CREATE TABLE IF NOT EXISTS artifact_deletion_intents(intent_id TEXT PRIMARY KEY, artifact_id TEXT NOT NULL, created_at INTEGER NOT NULL, completed_at INTEGER) STRICT",
        "CREATE TABLE IF NOT EXISTS deletion_intents(intent_id TEXT PRIMARY KEY, scope TEXT NOT NULL, conversation_id TEXT, created_at INTEGER NOT NULL, completed_at INTEGER) STRICT",
    ]
}
