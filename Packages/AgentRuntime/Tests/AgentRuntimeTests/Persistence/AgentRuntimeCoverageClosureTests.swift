// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation
@testable import AgentRuntime
import XCTest

final class AgentRuntimeCoverageClosureTests: XCTestCase {
    func testReadOnlyAndPublicValidationPathsRemainLazyAndFailClosed() async throws {
        let url = temporaryDatabaseURL()
        let store = SQLiteRunJournal(databaseURL: url)

        XCTAssertEqual(store.location, url)
        let absentPragmas = try await store.pragmaReport()
        XCTAssertNil(absentPragmas)
        let absentRecovery = try await store.recoveryDirective(
            for: RuntimeTestFixtures.Stream(offset: 2_000).runID
        )
        XCTAssertNil(absentRecovery)
        let absentDeletionIntents = try await store.pendingDeletionIntents()
        let disallowedTableCount = try await store.rowCount(table: "not-a-schema-table")
        XCTAssertEqual(absentDeletionIntents, [])
        XCTAssertEqual(disallowedTableCount, 0)

        let emptyPage = try await store.readEvents(try RunJournalReadRequest(
            runID: RuntimeTestFixtures.Stream(offset: 2_001).runID,
            limit: 1
        ))
        XCTAssertEqual(emptyPage.events, [])
        XCTAssertTrue(emptyPage.reachedEnd)
        XCTAssertFalse(store.databaseExists(), "read-only probes must not materialize persistence")

        let stream = RuntimeTestFixtures.Stream(offset: 2_002)
        let event = try event(
            stream: stream,
            number: 2_002,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            previousDigest: nil,
            payload: .diagnostic(RuntimeTestFixtures.failure())
        )
        let request = try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(2_002)),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            events: [event]
        )
        let conversation = ConversationID(rawValue: RuntimeTestFixtures.uuid(2_003))
        let user = message(stream: stream, conversation: conversation, role: .user, number: 2_004)
        let accepted = outbox(message: user, kind: .acceptedUserMessage)

        await assertThrows(SQLiteStoreError.self) {
            _ = try await store.acceptUserMessage(
                message(stream: stream, conversation: conversation, role: .assistant, number: 2_005),
                initialAppend: request,
                outbox: accepted
            )
        }
        await assertThrows(SQLiteStoreError.self) {
            _ = try await store.commitFinalAnswer(user, terminalAppend: request, outbox: accepted)
        }
        for invalid in [
            ("", Int64(1), Int64(2), 1),
            ("worker", Int64(2), Int64(2), 1),
            ("worker", Int64(1), Int64(2), 0),
            ("worker", Int64(1), Int64(2), 257),
        ] {
            await assertThrows(SQLiteStoreError.self) {
                _ = try await store.claimOutbox(
                    owner: invalid.0,
                    now: .init(rawValue: invalid.1),
                    leaseUntil: .init(rawValue: invalid.2),
                    limit: invalid.3
                )
            }
        }

        await assertThrows(SQLiteStoreError.self) {
            try await store.createDeletionIntent(.init(
                id: "mismatched-conversation",
                scope: .conversation,
                conversationID: nil,
                createdAt: .init(rawValue: 1)
            ))
        }
        await assertThrows(SQLiteStoreError.self) {
            try await store.createDeletionIntent(.init(
                id: "mismatched-delete-all",
                scope: .deleteAll,
                conversationID: conversation,
                createdAt: .init(rawValue: 1)
            ))
        }
        await assertThrows(SQLiteStoreError.self) {
            try await store.recordExternalClaim(.init(
                id: "",
                runID: stream.runID,
                invocationID: nil,
                kind: "provider",
                payloadDigest: digest("invalid-claim")
            ))
        }
        await assertThrows(SQLiteStoreError.self) {
            try await store.createArtifactDeletionIntent(
                id: "",
                artifactID: ArtifactID(rawValue: RuntimeTestFixtures.uuid(2_006)),
                at: .init(rawValue: 1)
            )
        }

        XCTAssertFalse(store.databaseExists(), "validation failures must precede opening the store")
    }

    func testCursorTerminalCASAndOutboxNegativePathsAreDeterministic() async throws {
        let url = temporaryDatabaseURL()
        let store = SQLiteRunJournal(databaseURL: url)
        let stream = RuntimeTestFixtures.Stream(offset: 2_100)
        let first = try event(
            stream: stream,
            number: 2_100,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            previousDigest: nil,
            payload: .diagnostic(RuntimeTestFixtures.failure())
        )
        let second = try event(
            stream: stream,
            number: 2_101,
            sequence: 2,
            stateVersion: 1,
            state: .created,
            previousDigest: first.payload.recordDigest,
            payload: .runInputSnapshotCommitted(try boundary("cursor-page"))
        )
        let initial = try RunJournalAppendRequest(
            mutationIdentity: .outcome(first.payload.eventID),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            events: [first, second]
        )
        let initialReceipt = try await store.append(initial)
        XCTAssertEqual(initialReceipt.disposition, .appended)

        let firstPage = try await store.readEvents(try RunJournalReadRequest(runID: stream.runID, limit: 1))
        XCTAssertEqual(firstPage.events, [first])
        XCTAssertFalse(firstPage.reachedEnd)
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        let secondPage = try await store.readEvents(try RunJournalReadRequest(
            runID: stream.runID,
            after: cursor,
            limit: 1
        ))
        XCTAssertEqual(secondPage.events, [second])
        XCTAssertTrue(secondPage.reachedEnd)

        let otherStream = RuntimeTestFixtures.Stream(offset: 2_102)
        await assertThrows(SQLiteStoreError.self) {
            _ = try await store.readEvents(try RunJournalReadRequest(
                runID: otherStream.runID,
                after: cursor,
                limit: 1
            ))
        }

        let impossibleNewRun = RuntimeTestFixtures.Stream(offset: 2_103)
        let versionTwo = try event(
            stream: impossibleNewRun,
            number: 2_103,
            sequence: 1,
            stateVersion: 2,
            state: .created,
            previousDigest: nil,
            payload: .diagnostic(RuntimeTestFixtures.failure())
        )
        let invalidInitialCAS = try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(2_103)),
            runID: impossibleNewRun.runID,
            expectedRunStateVersion: 2,
            events: [versionTwo]
        )
        await assertThrows(SQLiteStoreError.self) {
            _ = try await store.append(invalidInitialCAS)
        }

        let terminalStream = RuntimeTestFixtures.Stream(offset: 2_110)
        let terminal = try terminalBatch(stream: terminalStream, base: 2_110)
        let terminalReceipt = try await store.append(terminal)
        XCTAssertEqual(terminalReceipt.disposition, .appended)
        let postTerminal = try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(2_120)),
            runID: terminalStream.runID,
            expectedRunStateVersion: 6,
            events: [try event(
                stream: terminalStream,
                number: 2_120,
                sequence: 7,
                stateVersion: 6,
                state: .validatingAction,
                previousDigest: terminal.events.last?.payload.recordDigest,
                payload: .diagnostic(RuntimeTestFixtures.failure())
            )]
        )
        let immutable = try await store.append(postTerminal)
        XCTAssertEqual(immutable.disposition, .rejected)
        XCTAssertEqual(immutable.diagnostic, .terminalRunImmutable)

        let seeded = try await seedAcceptedOutbox(at: url, offset: 2_200)
        let claim = try await seeded.store.claimOutbox(
            owner: "owner-a",
            now: .init(rawValue: 10),
            leaseUntil: .init(rawValue: 20)
        )
        let key = try XCTUnwrap(claim.items.first?.idempotencyKey)
        await assertThrows(SQLiteStoreError.self) {
            try await seeded.store.markOutboxDelivered(
                idempotencyKey: key,
                owner: "wrong-owner",
                deliveredAt: .init(rawValue: 11)
            )
        }
        await assertThrows(SQLiteStoreError.self) {
            try await seeded.store.markOutboxDelivered(
                idempotencyKey: "missing",
                owner: "owner-a",
                deliveredAt: .init(rawValue: 11)
            )
        }
        await assertThrows(SQLiteStoreError.self) {
            try await seeded.store.cascadeConversation(seeded.conversation, intentID: "missing")
        }
    }

    func testEveryAuxiliaryEventFamilyIsMaterializedAndOptionalBindingsRoundTrip() async throws {
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        let stream = RuntimeTestFixtures.Stream(offset: 2_300)
        let artifactID = ArtifactID(rawValue: RuntimeTestFixtures.uuid(2_301))
        let compiledWithoutArtifact = try boundary("manifest-without-artifact")
        let compiledWithArtifact = try AgentStableBoundaryReference(
            digest: digest("manifest-with-artifact"),
            artifactID: artifactID
        )
        let preparedWithInvocation = try preparedRequest(stream: stream, number: 2_310, includeInvocation: true)
        let preparedWithoutInvocation = try preparedRequest(stream: stream, number: 2_320, includeInvocation: false)
        let approval = try AgentApprovalRequest(
            id: ApprovalID(rawValue: RuntimeTestFixtures.uuid(2_330)),
            prepared: preparedWithInvocation,
            policyVersion: 1,
            createdAt: .init(rawValue: 100)
        )
        let receipt = try ApprovalReceipt(
            request: approval,
            decision: .approved,
            scope: .exactInvocation,
            decidedAt: .init(rawValue: 101)
        )
        let interaction = try UserInputRequest(
            id: InteractionRequestID(rawValue: RuntimeTestFixtures.uuid(2_331)),
            runID: stream.runID,
            prompt: "Clarify the durable input",
            creationStateVersion: 1
        )
        let artifact = try artifactReference(runID: stream.runID, id: artifactID)
        let invocationID = try XCTUnwrap(preparedWithInvocation.invocationID)
        let failure = try RuntimeTestFixtures.failure()
        let usage = RuntimeTestFixtures.usage(7)
        let payloads: [(AgentEvent, AgentUsage)] = [
            (.compiledManifestCommitted(stepID: preparedWithInvocation.stepID, reference: compiledWithoutArtifact), .zero),
            (.compiledManifestCommitted(stepID: preparedWithoutInvocation.stepID, reference: compiledWithArtifact), .zero),
            (.validatedActionCommitted(stepID: AgentStepID(rawValue: RuntimeTestFixtures.uuid(2_332)), reference: try boundary("validated-action")), .zero),
            (.modelAttemptOutcome(.interrupted(nil)), .zero),
            (.toolIntentRecorded(preparedWithInvocation), .zero),
            (.toolIntentRecorded(preparedWithoutInvocation), .zero),
            (.toolOutcomeRecorded(invocationID: invocationID, outcome: .failed(failure)), .zero),
            (.approvalRequested(approval), .zero),
            (.approvalDecided(receipt), .zero),
            (.userInputRequested(interaction), .zero),
            (.userInputResponseCommitted(requestID: interaction.id, reference: try boundary("interaction-response")), .zero),
            (.artifactCommitted(artifact), .zero),
            (.usageUpdated(usage), usage),
        ]

        var envelopes: [AgentEventEnvelope] = []
        for (index, pair) in payloads.enumerated() {
            let envelope = try event(
                stream: stream,
                number: 2_400 + index,
                sequence: UInt64(index + 1),
                stateVersion: 1,
                state: .created,
                timestamp: Int64(index + 1),
                usage: pair.1,
                previousDigest: envelopes.last?.payload.recordDigest,
                payload: pair.0
            )
            envelopes.append(envelope)
        }
        let request = try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(2_300)),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            events: envelopes
        )
        let appendReceipt = try await store.append(request)
        XCTAssertEqual(appendReceipt.disposition, .appended)

        let expectedCounts: [String: Int] = [
            "steps": 3,
            "model_attempts": 1,
            "compiled_manifests": 2,
            "tool_invocations": 1,
            "approvals": 1,
            "interactions": 1,
            "usage_ledger": 1,
            "external_intents": 2,
            "external_outcomes": 1,
            "artifact_metadata": 1,
            "artifact_refs": 1,
        ]
        for (table, expected) in expectedCounts {
            let count = try await store.rowCount(table: table)
            XCTAssertEqual(count, expected, table)
        }

        try await store.recordExternalClaim(.init(
            id: "claim-with-invocation",
            runID: stream.runID,
            invocationID: invocationID,
            kind: "tool.reconciliation",
            payloadDigest: digest("claim")
        ))
        let claimCount = try await store.rowCount(table: "external_claims")
        XCTAssertEqual(claimCount, 1)

        let deleteAll = DeletionIntent(
            id: "delete-all",
            scope: .deleteAll,
            conversationID: nil,
            createdAt: .init(rawValue: 200)
        )
        try await store.createDeletionIntent(deleteAll)
        let pendingDeletionIntents = try await store.pendingDeletionIntents()
        XCTAssertEqual(pendingDeletionIntents, [deleteAll])
    }

    func testSQLiteFailuresSchemaVersionAndCorruptRowsMapToStableErrors() async throws {
        let directoryURL = temporaryDatabaseURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SQLiteConnection(url: directoryURL, create: false)) { error in
            guard case .unavailable = error as? SQLiteStoreError else {
                return XCTFail("expected stable unavailable error, got \(error)")
            }
        }

        let rawURL = temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = try SQLiteConnection(url: rawURL, create: true)
        XCTAssertThrowsError(try raw.execute("definitely not valid SQL")) { error in
            guard case .unavailable = error as? SQLiteStoreError else {
                return XCTFail("expected stable SQL error, got \(error)")
            }
        }
        try raw.execute("CREATE TABLE scalar_values(text_value TEXT, null_value TEXT) STRICT")
        try raw.execute("INSERT INTO scalar_values VALUES('value', NULL)")
        XCTAssertNil(try raw.scalarInt("SELECT text_value FROM scalar_values"))
        XCTAssertNil(try raw.scalarInt("SELECT 1 WHERE 0"))
        XCTAssertNil(try raw.scalarText("SELECT null_value FROM scalar_values"))
        let zeroBlob = try raw.rows("SELECT zeroblob(0)")
        XCTAssertEqual(zeroBlob.first?.first?.blob, Data())
        XCTAssertThrowsError(try raw.consistentBackup(to: rawURL.deletingLastPathComponent()))
        raw.close()
        XCTAssertThrowsError(try raw.execute("SELECT 1"))
        XCTAssertThrowsError(try raw.rows("SELECT 1"))
        XCTAssertThrowsError(try raw.consistentBackup(to: rawURL.appendingPathExtension("backup")))

        let futureURL = temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: futureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = try SQLiteConnection(url: futureURL, create: true)
        try future.execute("PRAGMA user_version = \(SQLiteRunJournal.schemaVersion + 1)")
        future.close()
        await assertThrows(SQLiteStoreError.self) {
            _ = try await SQLiteRunJournal(databaseURL: futureURL).openForWrite()
        }

        let sidecarURL = temporaryDatabaseURL()
        let sidecarStore = SQLiteRunJournal(databaseURL: sidecarURL)
        _ = try await sidecarStore.openForWrite()
        try await sidecarStore.checkpointWAL()
        await sidecarStore.close()
        let strayWAL = URL(fileURLWithPath: sidecarURL.path + "-wal")
        let straySHM = URL(fileURLWithPath: sidecarURL.path + "-shm")
        if FileManager.default.fileExists(atPath: straySHM.path) {
            try FileManager.default.removeItem(at: straySHM)
        }
        try Data().write(to: strayWAL)
        await assertThrows(SQLiteStoreError.self) {
            _ = try await SQLiteRunJournal(databaseURL: sidecarURL).loadProjection(
                for: RuntimeTestFixtures.Stream(offset: 2_500).runID
            )
        }

        let corruptURL = temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = try SQLiteConnection(url: corruptURL, create: true)
        try corrupt.execute("CREATE TABLE runs(run_id TEXT PRIMARY KEY, execution_handle_id TEXT) STRICT")
        try corrupt.execute("CREATE TABLE events(run_id TEXT, sequence INTEGER, payload BLOB) STRICT")
        let corruptStream = RuntimeTestFixtures.Stream(offset: 2_501)
        try corrupt.execute(
            "INSERT INTO runs(run_id, execution_handle_id) VALUES(?, ?)",
            [.text(corruptStream.runID.description), .text(corruptStream.executionHandleID.description)]
        )
        try corrupt.execute(
            "INSERT INTO events(run_id, sequence, payload) VALUES(?, 1, ?)",
            [.text(corruptStream.runID.description), .blob(Data("not-json".utf8))]
        )
        try corrupt.execute("PRAGMA user_version = \(SQLiteRunJournal.schemaVersion)")
        corrupt.close()
        await assertThrows(DecodingError.self) {
            _ = try await SQLiteRunJournal(databaseURL: corruptURL).readEvents(
                try RunJournalReadRequest(runID: corruptStream.runID)
            )
        }
    }

    func testPausingSelfTransitionExecutesSecondRegisteredPredicate() throws {
        let stream = RuntimeTestFixtures.Stream(offset: 2_600)
        let first = try event(
            stream: stream,
            number: 2_600,
            sequence: 1,
            stateVersion: 1,
            state: .pausing,
            previousDigest: nil,
            payload: .diagnostic(RuntimeTestFixtures.failure())
        )
        let second = try event(
            stream: stream,
            number: 2_601,
            sequence: 2,
            stateVersion: 2,
            state: .pausing,
            previousDigest: first.payload.recordDigest,
            payload: .diagnostic(RuntimeTestFixtures.failure())
        )
        XCTAssertNoThrow(try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(2_600)),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            events: [first, second]
        ))
    }

    private func preparedRequest(
        stream: RuntimeTestFixtures.Stream,
        number: Int,
        includeInvocation: Bool
    ) throws -> PreparedExternalOperationRequest {
        let destination = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://example.invalid/runtime-\(number)"
        )
        let category = try AgentDataCategory(rawValue: "user.query")
        let authority = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            destinations: [destination],
            dataCategories: [category]
        )
        let ceiling = RunCapabilityCeiling(authority: authority)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: authority)
        let canonical = try CanonicalJSON(.object(["query": .string("coverage")]))
        let sanitized = try SanitizedCanonicalJSON(
            value: canonical,
            redaction: RuntimeTestFixtures.redaction(),
            policyRevision: 1,
            attestationDigest: digest("attestation-\(number)")
        )
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: "test.runtime.read.\(number)",
            destination: destination,
            dataCategories: [category],
            payloadDigest: canonical.fingerprint,
            effects: [AgentEffect.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            maximumRequestBytes: 4_096,
            maximumResponseBytes: 8_192,
            timeoutMilliseconds: 5_000,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: "Read bounded test data",
            descriptorID: "test.runtime.read@1"
        )
        return try PreparedExternalOperationRequest(
            requestID: stream.requestID,
            runID: stream.runID,
            conversationID: ConversationID(rawValue: RuntimeTestFixtures.uuid(number + 1)),
            stepID: AgentStepID(rawValue: RuntimeTestFixtures.uuid(number + 2)),
            invocationID: includeInvocation
                ? ToolInvocationID(rawValue: RuntimeTestFixtures.uuid(number + 3))
                : nil,
            plan: plan,
            payload: sanitized,
            capabilityGrant: grant
        )
    }

    private func artifactReference(runID: AgentRunID, id: ArtifactID) throws -> ArtifactReference {
        try ArtifactReference(
            id: id,
            contentDigest: digest("artifact-content"),
            byteCount: 12,
            mimeType: "text/plain",
            semanticType: "test-output",
            provenance: ArtifactProvenance(runID: runID),
            createdAt: .init(rawValue: 1),
            retentionPolicy: .run,
            locator: ArtifactLocator(kind: .managedRelativePath, value: "runs/output.txt"),
            sensitivity: .publicMetadata,
            integrityStatus: .verified
        )
    }

    private func boundary(_ label: String) throws -> AgentStableBoundaryReference {
        try AgentStableBoundaryReference(digest: digest(label))
    }

    private func digest(_ label: String) -> StableDigest {
        StableDigest.sha256(Data(label.utf8))
    }

    private func event(
        stream: RuntimeTestFixtures.Stream,
        number: Int,
        sequence: UInt64,
        stateVersion: UInt64,
        state: AgentRunState,
        timestamp: Int64? = nil,
        usage: AgentUsage = .zero,
        previousDigest: StableDigest?,
        payload: AgentEvent
    ) throws -> AgentEventEnvelope {
        try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: number,
            sequence: sequence,
            stateVersion: stateVersion,
            state: state,
            timestamp: timestamp ?? Int64(sequence),
            usage: usage,
            previousDigest: previousDigest,
            event: payload
        )
    }

    private func terminalBatch(
        stream: RuntimeTestFixtures.Stream,
        base: Int
    ) throws -> RunJournalAppendRequest {
        var events: [AgentEventEnvelope] = []
        let states: [AgentRunState] = [.created, .preparing, .waitingForModel, .generating, .validatingAction]
        for (index, state) in states.enumerated() {
            events.append(try event(
                stream: stream,
                number: base + index,
                sequence: UInt64(index + 1),
                stateVersion: UInt64(index + 1),
                state: state,
                previousDigest: events.last?.payload.recordDigest,
                payload: .diagnostic(RuntimeTestFixtures.failure())
            ))
        }
        events.append(try RuntimeTestFixtures.completedEnvelope(
            stream: stream,
            eventNumber: base + states.count,
            sequence: UInt64(states.count + 1),
            stateVersion: UInt64(states.count + 1),
            timestamp: Int64(states.count + 1),
            usage: .zero,
            previousDigest: events.last?.payload.recordDigest
        ))
        return try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(base)),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            events: events
        )
    }

    private func message(
        stream: RuntimeTestFixtures.Stream,
        conversation: ConversationID,
        role: JournalMessageReference.Role,
        number: Int
    ) -> JournalMessageReference {
        JournalMessageReference(
            messageID: MessageID(rawValue: RuntimeTestFixtures.uuid(number)),
            conversationID: conversation,
            runID: stream.runID,
            role: role,
            bodyDigest: digest("message-\(number)"),
            bodyArtifactID: ArtifactID(rawValue: RuntimeTestFixtures.uuid(number + 1)),
            createdAt: .init(rawValue: Int64(number))
        )
    }

    private func outbox(
        message: JournalMessageReference,
        kind: ProjectionOutboxItem.Kind
    ) -> ProjectionOutboxItem {
        ProjectionOutboxItem(
            idempotencyKey: "\(kind.rawValue):\(message.messageID)",
            conversationID: message.conversationID,
            runID: message.runID,
            messageID: message.messageID,
            kind: kind,
            payloadDigest: message.bodyDigest,
            payloadArtifactID: message.bodyArtifactID
        )
    }

    private func seedAcceptedOutbox(
        at url: URL,
        offset: Int
    ) async throws -> (store: SQLiteRunJournal, conversation: ConversationID) {
        let store = SQLiteRunJournal(databaseURL: url)
        let stream = RuntimeTestFixtures.Stream(offset: offset)
        let conversation = ConversationID(rawValue: RuntimeTestFixtures.uuid(offset + 10))
        let user = message(stream: stream, conversation: conversation, role: .user, number: offset + 20)
        let first = try event(
            stream: stream,
            number: offset + 30,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            previousDigest: nil,
            payload: .diagnostic(RuntimeTestFixtures.failure())
        )
        let request = try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(offset + 40)),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            events: [first]
        )
        _ = try await store.acceptUserMessage(
            user,
            initialAppend: request,
            outbox: outbox(message: user, kind: .acceptedUserMessage)
        )
        return (store, conversation)
    }

    private func temporaryDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentRuntimeCoverageClosureTests-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal.sqlite3")
    }

    private func assertThrows<E: Error>(
        _ expectedType: E.Type,
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expectedType)", file: file, line: line)
        } catch {
            XCTAssertTrue(error is E, "Unexpected error: \(error)", file: file, line: line)
        }
    }
}
