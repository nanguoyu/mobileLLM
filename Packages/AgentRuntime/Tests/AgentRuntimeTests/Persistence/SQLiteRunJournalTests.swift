// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation
import SQLite3
@testable import AgentRuntime
import XCTest

final class SQLiteRunJournalTests: XCTestCase {
    func testLaunchProbeIsLazyAndPragmasAndSchemaAreHardened() async throws {
        let url = temporaryDatabaseURL()
        let store = SQLiteRunJournal(databaseURL: url)
        XCTAssertFalse(store.databaseExists())
        let launchProjection = try await store.loadProjection(for: RuntimeTestFixtures.Stream().runID)
        XCTAssertNil(launchProjection)
        XCTAssertFalse(store.databaseExists())

        let report = try await store.openForWrite()
        XCTAssertEqual(report.currentVersion, SQLiteRunJournal.schemaVersion)
        XCTAssertTrue(store.databaseExists())
        let optionalPragmas = try await store.pragmaReport()
        let pragmas = try XCTUnwrap(optionalPragmas)
        XCTAssertEqual(pragmas.journalMode.lowercased(), "wal")
        XCTAssertEqual(pragmas.synchronous, 2)
        XCTAssertTrue(pragmas.foreignKeys)
        XCTAssertTrue(pragmas.secureDelete)
        XCTAssertFalse(pragmas.trustedSchema)
        XCTAssertEqual(pragmas.busyTimeoutMilliseconds, 5_000)
        XCTAssertTrue(pragmas.defensive)
        let runCount = try await store.rowCount(table: "runs")
        XCTAssertEqual(runCount, 0)
    }

    func testAppendReopenReadAndProcessWALRoundTrip() async throws {
        let url = temporaryDatabaseURL()
        let stream = RuntimeTestFixtures.Stream()
        let e1 = try initialEvent(stream: stream, number: 300)
        let request = try appendRequest(event: e1, command: 300)
        let first = try await SQLiteRunJournal(databaseURL: url).append(request)
        XCTAssertEqual(first.disposition, .appended)

        let reopened = SQLiteRunJournal(databaseURL: url)
        let loadedProjection = try await reopened.loadProjection(for: stream.runID)
        let projection = try XCTUnwrap(loadedProjection)
        XCTAssertEqual(projection.eventCount, 1)
        let page = try await reopened.readEvents(try RunJournalReadRequest(runID: stream.runID))
        XCTAssertEqual(page.events, [e1])
        XCTAssertTrue(page.reachedEnd)
    }

    func testReadOnlyExistingStoreDoesNotCreateWALOrSHMSidecars() async throws {
        let url = temporaryDatabaseURL()
        let writer = SQLiteRunJournal(databaseURL: url)
        _ = try await writer.openForWrite()
        try await writer.checkpointWAL()
        await writer.close()
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let reader = SQLiteRunJournal(databaseURL: url)
        let missingProjection = try await reader.loadProjection(for: RuntimeTestFixtures.Stream(offset: 999).runID)
        XCTAssertNil(missingProjection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        let newAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(originalAttributes[.size] as? NSNumber, newAttributes[.size] as? NSNumber)
        XCTAssertEqual(originalAttributes[.modificationDate] as? Date, newAttributes[.modificationDate] as? Date)
    }

    func testDuplicateConflictStaleCASRaceAndTerminalReplayOrdering() async throws {
        let url = temporaryDatabaseURL()
        let store = SQLiteRunJournal(databaseURL: url)
        let stream = RuntimeTestFixtures.Stream()
        let e1 = try initialEvent(stream: stream, number: 310)
        let initial = try appendRequest(event: e1, command: 310)
        let initialDisposition = try await store.append(initial).disposition
        let replayDisposition = try await store.append(initial).disposition
        XCTAssertEqual(initialDisposition, .appended)
        XCTAssertEqual(replayDisposition, .replayed)

        let conflictingEvent = try initialEvent(stream: stream, number: 311)
        let conflict = try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(310)),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            events: [conflictingEvent]
        )
        let conflictReceipt = try await store.append(conflict)
        XCTAssertEqual(conflictReceipt.disposition, .rejected)
        XCTAssertEqual(conflictReceipt.diagnostic, .duplicateCommandConflict)

        let e2a = try RuntimeTestFixtures.envelope(
            stream: stream, eventNumber: 312, sequence: 2, stateVersion: 2,
            state: .preparing, timestamp: 2, previousDigest: e1.payload.recordDigest
        )
        let e2b = try RuntimeTestFixtures.envelope(
            stream: stream, eventNumber: 313, sequence: 2, stateVersion: 2,
            state: .preparing, timestamp: 2, previousDigest: e1.payload.recordDigest
        )
        let r1 = try RunJournalAppendRequest(mutationIdentity: .command(RuntimeTestFixtures.commandID(311)), runID: stream.runID, expectedRunStateVersion: 1, events: [e2a])
        let r2 = try RunJournalAppendRequest(mutationIdentity: .command(RuntimeTestFixtures.commandID(312)), runID: stream.runID, expectedRunStateVersion: 1, events: [e2b])
        async let a = store.append(r1)
        async let b = store.append(r2)
        let dispositions = try await [a.disposition, b.disposition]
        XCTAssertEqual(Set(dispositions), Set([.appended, .stale]))

        let terminalStore = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        let terminalRequest = try terminalBatch(stream: RuntimeTestFixtures.Stream(offset: 50))
        let terminalInitialDisposition = try await terminalStore.append(terminalRequest).disposition
        let terminalReplayDisposition = try await terminalStore.append(terminalRequest).disposition
        XCTAssertEqual(terminalInitialDisposition, .appended)
        XCTAssertEqual(terminalReplayDisposition, .replayed)
        let terminalConflict = try RunJournalAppendRequest(
            mutationIdentity: terminalRequest.mutationIdentity,
            runID: terminalRequest.runID,
            expectedRunStateVersion: 1,
            events: Array(terminalRequest.events.dropLast())
        )
        let receipt = try await terminalStore.append(terminalConflict)
        XCTAssertEqual(receipt.diagnostic, .duplicateCommandConflict)
    }

    func testSendAndFinalOutboxFaultsAreAtomicAndPostCommitRetryIsReplay() async throws {
        let stream = RuntimeTestFixtures.Stream(offset: 100)
        let conversation = ConversationID(rawValue: RuntimeTestFixtures.uuid(500))
        let message = messageReference(stream: stream, conversation: conversation, role: .user, id: 501)
        let outbox = outboxItem(message: message, kind: .acceptedUserMessage)
        let request = try appendRequest(event: initialEvent(stream: stream, number: 320), command: 320)

        let rollbackURL = temporaryDatabaseURL()
        let rollbackStore = SQLiteRunJournal(databaseURL: rollbackURL) { point in
            if point == .beforeOutboxInsert { throw SQLiteStoreError.diskFull }
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await rollbackStore.acceptUserMessage(message, initialAppend: request, outbox: outbox)
        }
        let clean = SQLiteRunJournal(databaseURL: rollbackURL)
        let rolledBackProjection = try await clean.loadProjection(for: stream.runID)
        let rolledBackMessages = try await clean.rowCount(table: "messages")
        let rolledBackOutbox = try await clean.rowCount(table: "projection_outbox")
        XCTAssertNil(rolledBackProjection)
        XCTAssertEqual(rolledBackMessages, 0)
        XCTAssertEqual(rolledBackOutbox, 0)

        let uncertainURL = temporaryDatabaseURL()
        let uncertain = SQLiteRunJournal(databaseURL: uncertainURL) { point in
            if point == .afterCommit { throw SQLiteStoreError.injected(point) }
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await uncertain.acceptUserMessage(message, initialAppend: request, outbox: outbox)
        }
        let retry = SQLiteRunJournal(databaseURL: uncertainURL)
        let retryDisposition = try await retry.acceptUserMessage(message, initialAppend: request, outbox: outbox).disposition
        let retryMessages = try await retry.rowCount(table: "messages")
        let retryOutbox = try await retry.rowCount(table: "projection_outbox")
        XCTAssertEqual(retryDisposition, .replayed)
        XCTAssertEqual(retryMessages, 1)
        XCTAssertEqual(retryOutbox, 1)
    }

    func testOutboxLeaseCrashRetryAndDeliveryAreIdempotent() async throws {
        let url = temporaryDatabaseURL()
        let store = SQLiteRunJournal(databaseURL: url)
        let stream = RuntimeTestFixtures.Stream(offset: 200)
        let conversation = ConversationID(rawValue: RuntimeTestFixtures.uuid(600))
        let message = messageReference(stream: stream, conversation: conversation, role: .user, id: 601)
        _ = try await store.acceptUserMessage(
            message,
            initialAppend: appendRequest(event: initialEvent(stream: stream, number: 330), command: 330),
            outbox: outboxItem(message: message, kind: .acceptedUserMessage)
        )
        let claim = try await store.claimOutbox(owner: "worker-a", now: .init(rawValue: 10), leaseUntil: .init(rawValue: 20))
        XCTAssertEqual(claim.items.count, 1)
        let blockedClaim = try await store.claimOutbox(owner: "worker-b", now: .init(rawValue: 11), leaseUntil: .init(rawValue: 19))
        XCTAssertTrue(blockedClaim.items.isEmpty)
        let retryClaim = try await store.claimOutbox(owner: "worker-b", now: .init(rawValue: 21), leaseUntil: .init(rawValue: 30))
        XCTAssertEqual(retryClaim.items.first?.attemptCount, 2)
        let key = try XCTUnwrap(retryClaim.items.first?.idempotencyKey)
        try await store.markOutboxDelivered(idempotencyKey: key, owner: "worker-b", deliveredAt: .init(rawValue: 22))
        try await store.markOutboxDelivered(idempotencyKey: key, owner: "worker-b", deliveredAt: .init(rawValue: 23))
        let deliveredClaim = try await store.claimOutbox(owner: "worker-c", now: .init(rawValue: 40), leaseUntil: .init(rawValue: 50))
        XCTAssertTrue(deliveredClaim.items.isEmpty)
    }

    func testFinalAnswerAndTerminalOutboxRollbackTogether() async throws {
        let url = temporaryDatabaseURL()
        let stream = RuntimeTestFixtures.Stream(offset: 250)
        let conversation = ConversationID(rawValue: RuntimeTestFixtures.uuid(650))
        let user = messageReference(stream: stream, conversation: conversation, role: .user, id: 651)
        let initial = try initialEvent(stream: stream, number: 370)
        let setup = SQLiteRunJournal(databaseURL: url)
        _ = try await setup.acceptUserMessage(user, initialAppend: appendRequest(event: initial, command: 370), outbox: outboxItem(message: user, kind: .acceptedUserMessage))
        await setup.close()

        let terminal = try terminalTail(stream: stream, first: initial)
        let assistant = messageReference(stream: stream, conversation: conversation, role: .assistant, id: 653)
        let finalOutbox = outboxItem(message: assistant, kind: .finalAnswer)
        let faulting = SQLiteRunJournal(databaseURL: url) { point in
            if point == .afterOutboxInsert { throw SQLiteStoreError.diskFull }
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await faulting.commitFinalAnswer(assistant, terminalAppend: terminal, outbox: finalOutbox)
        }
        await faulting.close()
        let reopened = SQLiteRunJournal(databaseURL: url)
        let optionalRolledBack = try await reopened.loadProjection(for: stream.runID)
        let rolledBack = try XCTUnwrap(optionalRolledBack)
        XCTAssertEqual(rolledBack.state, .created)
        let rolledBackMessageCount = try await reopened.rowCount(table: "messages")
        XCTAssertEqual(rolledBackMessageCount, 1)
        let finalReceipt = try await reopened.commitFinalAnswer(assistant, terminalAppend: terminal, outbox: finalOutbox)
        XCTAssertEqual(finalReceipt.disposition, .appended)
        XCTAssertTrue(finalReceipt.projection.isTerminal)
        let finalMessageCount = try await reopened.rowCount(table: "messages")
        let finalOutboxCount = try await reopened.rowCount(table: "projection_outbox")
        XCTAssertEqual(finalMessageCount, 2)
        XCTAssertEqual(finalOutboxCount, 2)
    }

    func testRecoveryNeverAutoResumesAndUsesOnlyDurableFacts() async throws {
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        let stream = RuntimeTestFixtures.Stream(offset: 300)
        _ = try await store.append(appendRequest(event: initialEvent(stream: stream, number: 340), command: 340))
        let loaded = try await store.recoveryDirective(for: stream.runID)
        let directive = try XCTUnwrap(loaded)
        XCTAssertEqual(directive.disposition, .alreadyStable)
        XCTAssertTrue(directive.requiresExplicitResume)
        XCTAssertEqual(directive.stableSequence, 1)
    }

    func testMigrationMakesConsistentBackupAndCorruptionBlocksMutation() async throws {
        let url = temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = try SQLiteConnection(url: url, create: true)
        try fixture.execute("CREATE TABLE legacy(value TEXT) STRICT")
        try fixture.execute("INSERT INTO legacy(value) VALUES('preserved')")
        try fixture.execute("PRAGMA user_version = 1")
        fixture.close()
        let report = try await SQLiteRunJournal(databaseURL: url).openForWrite()
        let backup = try XCTUnwrap(report.migrationBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let backupDB = try SQLiteConnection(url: backup, create: false)
        XCTAssertEqual(try backupDB.scalarText("SELECT value FROM legacy"), "preserved")

        let corruptURL = temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-a-sqlite-database".utf8).write(to: corruptURL)
        await XCTAssertThrowsErrorAsync { _ = try await SQLiteRunJournal(databaseURL: corruptURL).openForWrite() }
    }

    func testConversationCascadeKeepsDurableMarkerAndRemovesOwnedRows() async throws {
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        let stream = RuntimeTestFixtures.Stream(offset: 400)
        let conversation = ConversationID(rawValue: RuntimeTestFixtures.uuid(700))
        let message = messageReference(stream: stream, conversation: conversation, role: .user, id: 701)
        _ = try await store.acceptUserMessage(message, initialAppend: appendRequest(event: initialEvent(stream: stream, number: 350), command: 350), outbox: outboxItem(message: message, kind: .acceptedUserMessage))
        let intent = DeletionIntent(id: "delete-conversation-1", scope: .conversation, conversationID: conversation, createdAt: .init(rawValue: 50))
        try await store.createDeletionIntent(intent)
        try await store.cascadeConversation(conversation, intentID: intent.id)
        let runCount = try await store.rowCount(table: "runs")
        let eventCount = try await store.rowCount(table: "events")
        let messageCount = try await store.rowCount(table: "messages")
        let outboxCount = try await store.rowCount(table: "projection_outbox")
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(eventCount, 0)
        XCTAssertEqual(messageCount, 0)
        XCTAssertEqual(outboxCount, 0)
        let pending = try await store.pendingDeletionIntents()
        XCTAssertEqual(pending, [intent])
        try await store.completeDeletionIntent(id: intent.id, at: .init(rawValue: 60))
        let completedPending = try await store.pendingDeletionIntents()
        XCTAssertTrue(completedPending.isEmpty)
    }

    func testDeleteAllMarkerAndFaultRegistryAreVersionedAndComplete() throws {
        let root = temporaryDatabaseURL().deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let marker = DeleteAllMarker(applicationSupportURL: root)
        XCTAssertFalse(marker.blocksStoreOpening)
        try marker.create()
        XCTAssertTrue(marker.blocksStoreOpening)
        try marker.removeLast()
        XCTAssertFalse(marker.blocksStoreOpening)
        XCTAssertEqual(SQLiteJournalFaultPoint.registryVersion, 2)
        XCTAssertEqual(Set(SQLiteJournalFaultPoint.allCases.map(\.rawValue)).count, SQLiteJournalFaultPoint.allCases.count)
        let coveredFaults: Set<SQLiteJournalFaultPoint> = [
            .beforeOpenForWrite, .afterMigrationBackup, .beforeTransaction, .afterTransactionBegin,
            .beforeEventInsert, .afterEventInsert, .beforeRunUpdate, .afterRunUpdate,
            .beforeOutboxInsert, .afterOutboxInsert, .beforeCommit, .afterCommit,
            .beforeOutboxClaim, .afterOutboxClaim, .beforeOutboxDelivery, .afterOutboxDelivery,
            .beforeRecovery, .beforeDeletionIntent, .afterDeletionIntent,
            .beforeConversationCascade, .afterConversationCascade,
            .beforeCommandAdmission, .afterCommandAdmission,
            .beforeCommandClaim, .afterCommandClaim,
            .beforeCommandCompletion, .afterCommandCompletion,
            .beforeBudgetMutation, .afterBudgetMutation,
            .beforeSubmissionBoundary, .afterSubmissionBoundary,
            .beforeStableBoundaryProjection, .afterStableBoundaryProjection,
        ]
        XCTAssertEqual(coveredFaults, Set(SQLiteJournalFaultPoint.allCases))
    }

    func testConcurrentProcessWriterIsBusyThenCASAppendSucceeds() async throws {
        let url = temporaryDatabaseURL()
        let store = SQLiteRunJournal(databaseURL: url)
        _ = try await store.openForWrite()
        let blocker = try SQLiteConnection(url: url, create: false)
        try blocker.execute("PRAGMA busy_timeout = 0")
        try blocker.execute("BEGIN IMMEDIATE")
        let stream = RuntimeTestFixtures.Stream(offset: 500)
        let request = try appendRequest(event: initialEvent(stream: stream, number: 380), command: 380)
        await XCTAssertThrowsErrorAsync { _ = try await store.append(request) }
        try blocker.execute("ROLLBACK")
        let disposition = try await store.append(request).disposition
        XCTAssertEqual(disposition, .appended)
    }

    func testDeviceLockAndDiskFullFaultsBlockWithoutPartialMutation() async throws {
        let lockedURL = temporaryDatabaseURL()
        let locked = SQLiteRunJournal(databaseURL: lockedURL) { point in
            if point == .beforeOpenForWrite {
                throw SQLiteStoreError.dataProtectionUnavailable("device locked")
            }
        }
        let stream = RuntimeTestFixtures.Stream(offset: 600)
        let request = try appendRequest(event: initialEvent(stream: stream, number: 390), command: 390)
        await XCTAssertThrowsErrorAsync { _ = try await locked.append(request) }
        XCTAssertFalse(locked.databaseExists())

        let fullURL = temporaryDatabaseURL()
        let full = SQLiteRunJournal(databaseURL: fullURL) { point in
            if point == .beforeCommit { throw SQLiteStoreError.diskFull }
        }
        await XCTAssertThrowsErrorAsync { _ = try await full.append(request) }
        let projection = try await SQLiteRunJournal(databaseURL: fullURL).loadProjection(for: stream.runID)
        XCTAssertNil(projection)
    }

    func testMinimumExternalClaimAndArtifactDeletionIntentTables() async throws {
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        let stream = RuntimeTestFixtures.Stream(offset: 700)
        _ = try await store.append(appendRequest(event: initialEvent(stream: stream, number: 400), command: 400))
        try await store.recordExternalClaim(
            ExternalClaimReference(
                id: "claim-1", runID: stream.runID, invocationID: nil, kind: "provider.reconciliation",
                payloadDigest: StableDigest.sha256(Data("claim".utf8))
            )
        )
        try await store.createArtifactDeletionIntent(
            id: "artifact-delete-1",
            artifactID: ArtifactID(rawValue: RuntimeTestFixtures.uuid(801)),
            at: .init(rawValue: 10)
        )
        let claimCount = try await store.rowCount(table: "external_claims")
        let deletionCount = try await store.rowCount(table: "artifact_deletion_intents")
        XCTAssertEqual(claimCount, 1)
        XCTAssertEqual(deletionCount, 1)
    }

    func testEveryAppendTransactionFaultPointHasAtomicReopenEvidence() async throws {
        let rollbackPoints: [SQLiteJournalFaultPoint] = [
            .beforeTransaction, .afterTransactionBegin, .beforeEventInsert, .afterEventInsert,
            .beforeRunUpdate, .afterRunUpdate, .beforeCommit,
        ]
        for (offset, target) in rollbackPoints.enumerated() {
            let url = temporaryDatabaseURL()
            let store = SQLiteRunJournal(databaseURL: url) { point in
                if point == target { throw SQLiteStoreError.injected(point) }
            }
            let stream = RuntimeTestFixtures.Stream(offset: 900 + offset)
            let request = try appendRequest(event: initialEvent(stream: stream, number: 900 + offset), command: 900 + offset)
            await XCTAssertThrowsErrorAsync { _ = try await store.append(request) }
            await store.close()
            let projection = try await SQLiteRunJournal(databaseURL: url).loadProjection(for: stream.runID)
            XCTAssertNil(projection, "\(target) must roll back")
        }

        let url = temporaryDatabaseURL()
        let stream = RuntimeTestFixtures.Stream(offset: 950)
        let request = try appendRequest(event: initialEvent(stream: stream, number: 950), command: 950)
        let store = SQLiteRunJournal(databaseURL: url) { point in
            if point == .afterCommit { throw SQLiteStoreError.injected(point) }
        }
        await XCTAssertThrowsErrorAsync { _ = try await store.append(request) }
        await store.close()
        let reopened = SQLiteRunJournal(databaseURL: url)
        let committedProjection = try await reopened.loadProjection(for: stream.runID)
        XCTAssertNotNil(committedProjection)
        let replay = try await reopened.append(request)
        XCTAssertEqual(replay.disposition, .replayed)
    }

    func testEveryClaimDeliveryRecoveryAndDeletionFaultPointHasReopenEvidence() async throws {
        for target in [SQLiteJournalFaultPoint.beforeOutboxClaim, .afterOutboxClaim] {
            let url = temporaryDatabaseURL()
            let seeded = try await seedAcceptedOutbox(at: url, offset: target == .beforeOutboxClaim ? 1_000 : 1_010)
            await seeded.store.close()
            let faulting = SQLiteRunJournal(databaseURL: url) { point in
                if point == target { throw SQLiteStoreError.injected(point) }
            }
            await XCTAssertThrowsErrorAsync {
                _ = try await faulting.claimOutbox(owner: "fault", now: .init(rawValue: 1), leaseUntil: .init(rawValue: 2))
            }
            await faulting.close()
            let reopened = SQLiteRunJournal(databaseURL: url)
            let claim = try await reopened.claimOutbox(owner: "retry", now: .init(rawValue: 3), leaseUntil: .init(rawValue: 4))
            XCTAssertEqual(claim.items.count, 1, "\(target) must roll back the lease")
        }

        for target in [SQLiteJournalFaultPoint.beforeOutboxDelivery, .afterOutboxDelivery] {
            let url = temporaryDatabaseURL()
            let seeded = try await seedAcceptedOutbox(at: url, offset: target == .beforeOutboxDelivery ? 1_020 : 1_030)
            let claim = try await seeded.store.claimOutbox(owner: "worker", now: .init(rawValue: 1), leaseUntil: .init(rawValue: 10))
            let key = try XCTUnwrap(claim.items.first?.idempotencyKey)
            await seeded.store.close()
            let faulting = SQLiteRunJournal(databaseURL: url) { point in
                if point == target { throw SQLiteStoreError.injected(point) }
            }
            await XCTAssertThrowsErrorAsync {
                try await faulting.markOutboxDelivered(idempotencyKey: key, owner: "worker", deliveredAt: .init(rawValue: 2))
            }
            await faulting.close()
            let reopened = SQLiteRunJournal(databaseURL: url)
            try await reopened.markOutboxDelivered(idempotencyKey: key, owner: "worker", deliveredAt: .init(rawValue: 3))
            let empty = try await reopened.claimOutbox(owner: "next", now: .init(rawValue: 20), leaseUntil: .init(rawValue: 30))
            XCTAssertTrue(empty.items.isEmpty)
        }

        let recoveryURL = temporaryDatabaseURL()
        let recoverySeed = try await seedAcceptedOutbox(at: recoveryURL, offset: 1_040)
        await recoverySeed.store.close()
        let recoveryFault = SQLiteRunJournal(databaseURL: recoveryURL) { point in
            if point == .beforeRecovery { throw SQLiteStoreError.injected(point) }
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await recoveryFault.recoveryDirective(for: recoverySeed.stream.runID)
        }
        await recoveryFault.close()
        let recoveredProjection = try await SQLiteRunJournal(databaseURL: recoveryURL).loadProjection(for: recoverySeed.stream.runID)
        XCTAssertNotNil(recoveredProjection)

        for target in [SQLiteJournalFaultPoint.beforeDeletionIntent, .afterDeletionIntent] {
            let url = temporaryDatabaseURL()
            let seed = try await seedAcceptedOutbox(at: url, offset: target == .beforeDeletionIntent ? 1_050 : 1_060)
            await seed.store.close()
            let intent = DeletionIntent(id: "fault-\(target.rawValue)", scope: .conversation, conversationID: seed.conversation, createdAt: .init(rawValue: 1))
            let faulting = SQLiteRunJournal(databaseURL: url) { point in
                if point == target { throw SQLiteStoreError.injected(point) }
            }
            await XCTAssertThrowsErrorAsync { try await faulting.createDeletionIntent(intent) }
            await faulting.close()
            let pending = try await SQLiteRunJournal(databaseURL: url).pendingDeletionIntents()
            XCTAssertTrue(pending.isEmpty, "\(target) must leave no partial intent")
        }

        for target in [SQLiteJournalFaultPoint.beforeConversationCascade, .afterConversationCascade] {
            let url = temporaryDatabaseURL()
            let seed = try await seedAcceptedOutbox(at: url, offset: target == .beforeConversationCascade ? 1_070 : 1_080)
            let intent = DeletionIntent(id: "cascade-\(target.rawValue)", scope: .conversation, conversationID: seed.conversation, createdAt: .init(rawValue: 1))
            try await seed.store.createDeletionIntent(intent)
            await seed.store.close()
            let faulting = SQLiteRunJournal(databaseURL: url) { point in
                if point == target { throw SQLiteStoreError.injected(point) }
            }
            await XCTAssertThrowsErrorAsync { try await faulting.cascadeConversation(seed.conversation, intentID: intent.id) }
            await faulting.close()
            let cascadeProjection = try await SQLiteRunJournal(databaseURL: url).loadProjection(for: seed.stream.runID)
            XCTAssertNotNil(cascadeProjection, "\(target) must roll back cascade")
        }
    }

    func testMigrationFaultPreservesOriginalBlocksMutationAndKeepsBackup() async throws {
        let url = temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = try SQLiteConnection(url: url, create: true)
        try fixture.execute("CREATE TABLE legacy(value TEXT) STRICT")
        try fixture.execute("INSERT INTO legacy(value) VALUES('original')")
        try fixture.execute("PRAGMA user_version = 1")
        fixture.close()
        let faulting = SQLiteRunJournal(databaseURL: url) { point in
            if point == .afterMigrationBackup { throw SQLiteStoreError.injected(point) }
        }
        await XCTAssertThrowsErrorAsync { _ = try await faulting.openForWrite() }
        await XCTAssertThrowsErrorAsync { _ = try await faulting.openForWrite() }
        let original = try SQLiteConnection(url: url, create: false, readOnly: true)
        XCTAssertEqual(try original.scalarInt("PRAGMA user_version"), 1)
        XCTAssertEqual(try original.scalarText("SELECT value FROM legacy"), "original")
        let backup = url.deletingPathExtension().appendingPathExtension("migration-v1.sqlite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    private func temporaryDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentRuntimePersistenceTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal.sqlite3")
    }

    private func initialEvent(stream: RuntimeTestFixtures.Stream, number: Int) throws -> AgentEventEnvelope {
        try RuntimeTestFixtures.envelope(stream: stream, eventNumber: number, sequence: 1, stateVersion: 1, state: .created, timestamp: 1, previousDigest: nil)
    }

    private func appendRequest(event: AgentEventEnvelope, command: Int) throws -> RunJournalAppendRequest {
        try RunJournalAppendRequest(mutationIdentity: .command(RuntimeTestFixtures.commandID(command)), runID: event.payload.runID, expectedRunStateVersion: 1, events: [event])
    }

    private func messageReference(stream: RuntimeTestFixtures.Stream, conversation: ConversationID, role: JournalMessageReference.Role, id: Int) -> JournalMessageReference {
        let artifactID = ArtifactID(rawValue: RuntimeTestFixtures.uuid(id + 1))
        return JournalMessageReference(messageID: MessageID(rawValue: RuntimeTestFixtures.uuid(id)), conversationID: conversation, runID: stream.runID, role: role, bodyDigest: StableDigest.sha256(Data("body-\(id)".utf8)), bodyArtifactID: artifactID, createdAt: .init(rawValue: Int64(id)))
    }

    private func outboxItem(message: JournalMessageReference, kind: ProjectionOutboxItem.Kind) -> ProjectionOutboxItem {
        ProjectionOutboxItem(idempotencyKey: "\(kind.rawValue):\(message.messageID)", conversationID: message.conversationID, runID: message.runID, messageID: message.messageID, kind: kind, payloadDigest: message.bodyDigest, payloadArtifactID: message.bodyArtifactID)
    }

    private func seedAcceptedOutbox(
        at url: URL,
        offset: Int
    ) async throws -> (store: SQLiteRunJournal, stream: RuntimeTestFixtures.Stream, conversation: ConversationID) {
        let store = SQLiteRunJournal(databaseURL: url)
        let stream = RuntimeTestFixtures.Stream(offset: offset)
        let conversation = ConversationID(rawValue: RuntimeTestFixtures.uuid(2_000 + offset))
        let message = messageReference(stream: stream, conversation: conversation, role: .user, id: 3_000 + offset)
        let initial = try initialEvent(stream: stream, number: 2_000 + offset)
        _ = try await store.acceptUserMessage(
            message,
            initialAppend: appendRequest(event: initial, command: 2_000 + offset),
            outbox: outboxItem(message: message, kind: .acceptedUserMessage)
        )
        return (store, stream, conversation)
    }

    private func terminalBatch(stream: RuntimeTestFixtures.Stream) throws -> RunJournalAppendRequest {
        let e1 = try initialEvent(stream: stream, number: 360)
        let e2 = try RuntimeTestFixtures.envelope(stream: stream, eventNumber: 361, sequence: 2, stateVersion: 2, state: .preparing, timestamp: 2, previousDigest: e1.payload.recordDigest)
        let e3 = try RuntimeTestFixtures.envelope(stream: stream, eventNumber: 362, sequence: 3, stateVersion: 3, state: .waitingForModel, timestamp: 3, previousDigest: e2.payload.recordDigest)
        let e4 = try RuntimeTestFixtures.envelope(stream: stream, eventNumber: 363, sequence: 4, stateVersion: 4, state: .generating, timestamp: 4, previousDigest: e3.payload.recordDigest)
        let e5 = try RuntimeTestFixtures.envelope(stream: stream, eventNumber: 364, sequence: 5, stateVersion: 5, state: .validatingAction, timestamp: 5, previousDigest: e4.payload.recordDigest)
        let e6 = try RuntimeTestFixtures.completedEnvelope(stream: stream, eventNumber: 365, sequence: 6, stateVersion: 6, timestamp: 6, usage: .zero, previousDigest: e5.payload.recordDigest)
        return try RunJournalAppendRequest(mutationIdentity: .command(RuntimeTestFixtures.commandID(360)), runID: stream.runID, expectedRunStateVersion: 1, events: [e1, e2, e3, e4, e5, e6])
    }

    private func terminalTail(stream: RuntimeTestFixtures.Stream, first e1: AgentEventEnvelope) throws -> RunJournalAppendRequest {
        let e2 = try RuntimeTestFixtures.envelope(stream: stream, eventNumber: 371, sequence: 2, stateVersion: 2, state: .preparing, timestamp: 2, previousDigest: e1.payload.recordDigest)
        let e3 = try RuntimeTestFixtures.envelope(stream: stream, eventNumber: 372, sequence: 3, stateVersion: 3, state: .waitingForModel, timestamp: 3, previousDigest: e2.payload.recordDigest)
        let e4 = try RuntimeTestFixtures.envelope(stream: stream, eventNumber: 373, sequence: 4, stateVersion: 4, state: .generating, timestamp: 4, previousDigest: e3.payload.recordDigest)
        let e5 = try RuntimeTestFixtures.envelope(stream: stream, eventNumber: 374, sequence: 5, stateVersion: 5, state: .validatingAction, timestamp: 5, previousDigest: e4.payload.recordDigest)
        let e6 = try RuntimeTestFixtures.completedEnvelope(stream: stream, eventNumber: 375, sequence: 6, stateVersion: 6, timestamp: 6, usage: .zero, previousDigest: e5.payload.recordDigest)
        return try RunJournalAppendRequest(mutationIdentity: .command(RuntimeTestFixtures.commandID(371)), runID: stream.runID, expectedRunStateVersion: 1, events: [e2, e3, e4, e5, e6])
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
