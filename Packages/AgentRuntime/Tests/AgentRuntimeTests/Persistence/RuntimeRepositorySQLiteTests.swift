// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime

final class RuntimeRepositorySQLiteTests: XCTestCase {
    func testSubmissionCommitsEveryBoundaryReopensAndRejectsConflictingReplay() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 10)
        let store = SQLiteRunJournal(databaseURL: url)
        let first = try await store.commitSubmission(fixture.commit)
        XCTAssertEqual(first.executionHandleID, fixture.stream.executionHandleID)
        XCTAssertEqual(first.appendReceipt.disposition, .appended)
        XCTAssertEqual(first.budgetLedger, fixture.commit.initialLedger)
        let submissionCount = try await store.rowCount(table: "run_submissions")
        let snapshotCount = try await store.rowCount(table: "run_input_snapshots")
        let ledgerCount = try await store.rowCount(table: "budget_ledgers")
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(ledgerCount, 1)

        let loadedFacts = try await store.loadRunFacts(for: fixture.stream.runID)
        let facts = try XCTUnwrap(loadedFacts)
        XCTAssertEqual(facts.submission?.commandID, fixture.commit.commandID)
        XCTAssertEqual(facts.submission?.request, fixture.commit.request)
        XCTAssertEqual(facts.submission?.executionHandleID, fixture.stream.executionHandleID)
        XCTAssertEqual(facts.submission?.inputSnapshot, fixture.commit.inputSnapshot)
        XCTAssertEqual(facts.conversationID, fixture.commit.request.payload.conversationID)
        XCTAssertEqual(facts.budgetLedger, fixture.commit.initialLedger)
        let loadedHandleFacts = try await store.loadRunFacts(for: fixture.stream.executionHandleID)
        let handleFacts = try XCTUnwrap(loadedHandleFacts)
        XCTAssertEqual(handleFacts.projection, facts.projection)
        XCTAssertEqual(handleFacts.submission?.request, fixture.commit.request)

        await store.close()
        let reopened = SQLiteRunJournal(databaseURL: url)
        let replay = try await reopened.commitSubmission(fixture.commit)
        XCTAssertEqual(replay.appendReceipt.disposition, .replayed)
        XCTAssertEqual(replay.executionHandleID, fixture.stream.executionHandleID)
        let messageCount = try await reopened.rowCount(table: "messages")
        let outboxCount = try await reopened.rowCount(table: "projection_outbox")
        XCTAssertEqual(messageCount, 1)
        XCTAssertEqual(outboxCount, 1)

        let loadedReopenedHandleFacts = try await reopened.loadRunFacts(
            for: fixture.stream.executionHandleID
        )
        let reopenedHandleFacts = try XCTUnwrap(loadedReopenedHandleFacts)
        XCTAssertEqual(reopenedHandleFacts.submission?.executionHandleID, fixture.stream.executionHandleID)

        let divergentOutbox = ProjectionOutboxItem(
            idempotencyKey: "divergent:\(fixture.commit.userMessage.messageID)",
            conversationID: fixture.commit.outbox.conversationID,
            runID: fixture.commit.outbox.runID,
            messageID: fixture.commit.outbox.messageID,
            kind: fixture.commit.outbox.kind,
            payloadDigest: fixture.commit.outbox.payloadDigest,
            payloadArtifactID: fixture.commit.outbox.payloadArtifactID
        )
        let conflict = RuntimeSubmissionCommit(
            commandID: fixture.commit.commandID,
            request: fixture.commit.request,
            executionHandleID: fixture.commit.executionHandleID,
            userMessage: fixture.commit.userMessage,
            inputSnapshot: fixture.commit.inputSnapshot,
            initialAppend: fixture.commit.initialAppend,
            initialLedger: fixture.commit.initialLedger,
            outbox: divergentOutbox
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await reopened.commitSubmission(conflict)
        }
    }

    func testExternalBoundaryClaimIsAtomicIdempotentAndDurableAcrossReopen() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 18_000)
        let store = SQLiteRunJournal(databaseURL: url)
        _ = try await store.commitSubmission(fixture.commit)
        let loadedCreated = try await store.loadProjection(for: fixture.stream.runID)
        let created = try XCTUnwrap(loadedCreated)
        _ = try await store.append(try transitionAppend(
            stream: fixture.stream,
            projection: created,
            commandNumber: 18_050,
            baseEventNumber: 18_051,
            states: [.preparing, .waitingForModel, .generating],
            finalEvent: nil
        ))
        let claimScope = try RuntimeBoundaryClaimScope(
            runID: fixture.stream.runID,
            expectedState: .generating,
            expectedStateVersion: 4
        )
        let prepared = try preparedRequest(
            stream: fixture.stream,
            number: 18_100,
            idempotency: .pureRead
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        let hop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: prepared.plan.destination
        )
        let approvalID = ApprovalID(rawValue: RuntimeTestFixtures.uuid(18_200))

        async let first = store.claimBoundaryHop(
            scope: claimScope,
            approvalID: approvalID,
            preparedRequestFingerprint: prepared.fingerprint,
            attempt: attempt,
            hop: hop
        )
        async let racingDuplicate = store.claimBoundaryHop(
            scope: claimScope,
            approvalID: approvalID,
            preparedRequestFingerprint: prepared.fingerprint,
            attempt: attempt,
            hop: hop
        )
        let results = try await [first, racingDuplicate]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let initialEvidence = try await store.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: prepared,
            attempt: attempt
        )
        XCTAssertEqual(initialEvidence, .exact)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.boundaryClaimEvidence(
                approvalID: ApprovalID(rawValue: RuntimeTestFixtures.uuid(18_201)),
                prepared: prepared,
                attempt: attempt
            )
        }
        let replayed = try await store.claimBoundaryHop(
            scope: claimScope,
            approvalID: approvalID,
            preparedRequestFingerprint: prepared.fingerprint,
            attempt: attempt,
            hop: hop
        )
        XCTAssertFalse(replayed)

        await store.close()
        let reopened = SQLiteRunJournal(databaseURL: url)
        let reopenedReplay = try await reopened.claimBoundaryHop(
            scope: claimScope,
            approvalID: approvalID,
            preparedRequestFingerprint: prepared.fingerprint,
            attempt: attempt,
            hop: hop
        )
        XCTAssertFalse(reopenedReplay)
        let reopenedEvidence = try await reopened.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: prepared,
            attempt: attempt
        )
        XCTAssertEqual(reopenedEvidence, .exact)
        await reopened.close()

        let raw = try SQLiteConnection(url: url, create: false)
        let original = try XCTUnwrap(raw.rows(
            "SELECT run_id, claim_kind, payload_digest, approval_id, prepared_fingerprint, attempt_fingerprint, hop_fingerprint FROM external_claims"
        ).first)
        raw.close()
        XCTAssertEqual(original.count, 7)

        func mutate(_ sql: String, _ values: [SQLiteValue] = []) throws {
            let connection = try SQLiteConnection(url: url, create: false)
            defer { connection.close() }
            try connection.execute(sql, values)
        }
        func evidence() async throws -> RuntimeBoundaryClaimEvidence {
            let probe = SQLiteRunJournal(databaseURL: url)
            defer { Task { await probe.close() } }
            return try await probe.boundaryClaimEvidence(
                approvalID: approvalID,
                prepared: prepared,
                attempt: attempt
            )
        }
        func assertCorruptEvidence(
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await evidence()
                XCTFail("tampered exact claim must fail closed", file: file, line: line)
            } catch let error as RuntimeRepositoryError {
                guard case .durableFactCorrupt = error else {
                    return XCTFail("unexpected repository error: \(error)", file: file, line: line)
                }
            } catch {
                XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }

        try mutate("UPDATE external_claims SET claim_kind = 'tampered-kind'")
        await assertCorruptEvidence()
        try mutate("UPDATE external_claims SET claim_kind = ?", [original[1]])

        try mutate("UPDATE external_claims SET payload_digest = ?", [.text(digest("tampered").rawValue)])
        await assertCorruptEvidence()
        try mutate("UPDATE external_claims SET payload_digest = ?", [original[2]])

        let forgedApprovalID = ApprovalID(rawValue: RuntimeTestFixtures.uuid(18_202))
        let forgedDigest = StableDigest.fingerprint(
            domain: "external-boundary-hop-claim.v1",
            components: [
                Data(forgedApprovalID.description.utf8),
                Data(prepared.fingerprint.rawValue.utf8),
                Data(attempt.fingerprint.rawValue.utf8),
                Data(hop.fingerprint.rawValue.utf8),
            ]
        )
        try mutate(
            "UPDATE external_claims SET approval_id = ?, payload_digest = ?",
            [.text(forgedApprovalID.description), .text(forgedDigest.rawValue)]
        )
        await assertCorruptEvidence()
        try mutate(
            "UPDATE external_claims SET approval_id = ?, payload_digest = ?",
            [original[3], original[2]]
        )

        try mutate(
            "UPDATE external_claims SET run_id = ?",
            [.text(AgentRunID(rawValue: RuntimeTestFixtures.uuid(18_203)).description)]
        )
        await assertCorruptEvidence()
        try mutate("UPDATE external_claims SET run_id = ?", [original[0]])

        try mutate("UPDATE external_claims SET approval_id = NULL")
        await assertCorruptEvidence()
        try mutate("UPDATE external_claims SET approval_id = ?", [original[3]])

        try mutate(
            "UPDATE external_claims SET approval_id = NULL, prepared_fingerprint = NULL, attempt_fingerprint = NULL, hop_fingerprint = NULL"
        )
        let legacyEvidence = try await evidence()
        XCTAssertEqual(legacyEvidence, .legacyConservative)
    }

    func testBoundaryEvidenceSearchesEveryPreparedRedirectAndFallbackHop() async throws {
        let fixture = try submission(offset: 18_500)
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await store.commitSubmission(fixture.commit)
        let loadedCreated = try await store.loadProjection(for: fixture.stream.runID)
        let created = try XCTUnwrap(loadedCreated)
        _ = try await store.append(try transitionAppend(
            stream: fixture.stream,
            projection: created,
            commandNumber: 18_501,
            baseEventNumber: 18_502,
            states: [.preparing, .waitingForModel, .generating],
            finalEvent: nil
        ))
        let redirect = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://redirect.example.invalid:443"
        )
        let fallback = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://fallback.example.invalid:443"
        )
        let prepared = try preparedRequest(
            stream: fixture.stream,
            number: 18_510,
            idempotency: .pureRead,
            allowedRedirects: [redirect],
            allowedFallbacks: [fallback]
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        let approvalID = ApprovalID(rawValue: RuntimeTestFixtures.uuid(18_511))

        let initialEvidence = try await store.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: prepared,
            attempt: attempt
        )
        XCTAssertEqual(initialEvidence, .none)

        let claimed = try await store.claimBoundaryHop(
            scope: RuntimeBoundaryClaimScope(
                runID: fixture.stream.runID,
                expectedState: .generating,
                expectedStateVersion: 4
            ),
            approvalID: approvalID,
            preparedRequestFingerprint: prepared.fingerprint,
            attempt: attempt,
            hop: ExternalOperationBoundaryHop(
                prepared: prepared,
                attempt: attempt,
                destination: fallback
            )
        )
        XCTAssertTrue(claimed)
        let claimedEvidence = try await store.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: prepared,
            attempt: attempt
        )
        XCTAssertEqual(claimedEvidence, .exact)
    }

    func testSubmissionValidationAndEveryNewAtomicBoundaryFaultRollBack() async throws {
        let invalidFixture = try submission(offset: 100)
        let wrongBoundary = try AgentStableBoundaryReference(digest: digest("wrong-boundary"))
        let invalid = RuntimeSubmissionCommit(
            commandID: invalidFixture.commit.commandID,
            request: invalidFixture.commit.request,
            executionHandleID: invalidFixture.commit.executionHandleID,
            userMessage: invalidFixture.commit.userMessage,
            inputSnapshot: wrongBoundary,
            initialAppend: invalidFixture.commit.initialAppend,
            initialLedger: invalidFixture.commit.initialLedger,
            outbox: invalidFixture.commit.outbox
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await SQLiteRunJournal(databaseURL: self.temporaryDatabaseURL()).commitSubmission(invalid)
        }

        let rollbackPoints: [SQLiteJournalFaultPoint] = [
            .beforeStableBoundaryProjection, .afterStableBoundaryProjection,
            .beforeBudgetMutation, .afterBudgetMutation,
            .beforeSubmissionBoundary, .afterSubmissionBoundary,
        ]
        for (index, point) in rollbackPoints.enumerated() {
            let url = temporaryDatabaseURL()
            let fixture = try submission(offset: 200 + index * 20)
            let faulting = SQLiteRunJournal(databaseURL: url) { encountered in
                if encountered == point { throw SQLiteStoreError.injected(point) }
            }
            await assertThrows(SQLiteStoreError.self) {
                _ = try await faulting.commitSubmission(fixture.commit)
            }
            await faulting.close()
            let reopened = SQLiteRunJournal(databaseURL: url)
            let facts = try await reopened.loadRunFacts(for: fixture.stream.runID)
            let messageCount = try await reopened.rowCount(table: "messages")
            let ledgerCount = try await reopened.rowCount(table: "budget_ledgers")
            XCTAssertNil(facts, "\(point)")
            XCTAssertEqual(messageCount, 0, "\(point)")
            XCTAssertEqual(ledgerCount, 0, "\(point)")
        }

        let uncertainURL = temporaryDatabaseURL()
        let uncertainFixture = try submission(offset: 400)
        let uncertain = SQLiteRunJournal(databaseURL: uncertainURL) { point in
            if point == .afterCommit { throw SQLiteStoreError.injected(point) }
        }
        await assertThrows(SQLiteStoreError.self) {
            _ = try await uncertain.commitSubmission(uncertainFixture.commit)
        }
        await uncertain.close()
        let retried = try await SQLiteRunJournal(databaseURL: uncertainURL)
            .commitSubmission(uncertainFixture.commit)
        XCTAssertEqual(retried.appendReceipt.disposition, .replayed)
    }

    func testCommandInboxMonotonicFairLeasedAndExactReceiptReplay() async throws {
        let url = temporaryDatabaseURL()
        let store = SQLiteRunJournal(databaseURL: url)
        let firstRun = try submission(offset: 500)
        let secondRun = try submission(offset: 600)
        _ = try await store.commitSubmission(firstRun.commit)
        _ = try await store.commitSubmission(secondRun.commit)

        let first = try command(stream: firstRun.stream, number: 1, action: .resume)
        let second = try command(stream: firstRun.stream, number: 2, action: .cancel)
        let third = try command(stream: secondRun.stream, number: 3, action: .resume)
        let admitted1 = try await store.enqueueCommand(first)
        let admitted2 = try await store.enqueueCommand(second)
        let admitted3 = try await store.enqueueCommand(third)
        XCTAssertEqual([admitted1.command.admissionSequence, admitted2.command.admissionSequence, admitted3.command.admissionSequence], [1, 2, 3])
        let firstReplay = try await store.enqueueCommand(first)
        XCTAssertEqual(firstReplay.disposition, .replayed)

        let conflictingPayload = try AgentCommand(
            commandID: first.payload.commandID,
            runID: first.payload.runID,
            expectedRunStateVersion: 1,
            action: .cancel,
            issuedAt: first.payload.issuedAt
        )
        let conflict = try await store.enqueueCommand(AgentCommandEnvelope(payload: conflictingPayload))
        XCTAssertEqual(conflict.disposition, .conflict)
        XCTAssertEqual(conflict.command.envelope, first)

        await store.close()
        let reopened = SQLiteRunJournal(databaseURL: url)
        let reopenedFirst = try await reopened.loadCommand(first.payload.commandID)
        XCTAssertEqual(reopenedFirst?.state, .pending)
        let claim = try await reopened.claimCommands(
            owner: "worker-a",
            now: .init(rawValue: 10),
            leaseUntil: .init(rawValue: 20),
            limit: 10
        )
        XCTAssertEqual(claim.commands.map(\.commandID), [first.payload.commandID, third.payload.commandID])
        XCTAssertEqual(claim.commands.map(\.leaseGeneration), [1, 1])

        let firstLease = try XCTUnwrap(claim.commands[0].lease)
        let receipt = try commandReceipt(for: first, state: .created, version: 1)
        let completed = try await reopened.completeCommand(
            commandID: first.payload.commandID,
            lease: firstLease,
            receipt: receipt,
            completedAt: .init(rawValue: 11)
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.receipt, receipt)
        let exactReplay = try await reopened.completeCommand(
            commandID: first.payload.commandID,
            lease: firstLease,
            receipt: receipt,
            completedAt: .init(rawValue: 99)
        )
        XCTAssertEqual(exactReplay, completed)

        let differentReceipt = try commandReceipt(for: first, state: .preparing, version: 2)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await reopened.completeCommand(
                commandID: first.payload.commandID,
                lease: firstLease,
                receipt: differentReceipt,
                completedAt: .init(rawValue: 12)
            )
        }
        let completedAdmission = try await reopened.enqueueCommand(first)
        XCTAssertEqual(completedAdmission.disposition, .replayed)
        XCTAssertEqual(completedAdmission.command.receipt, receipt)

        let secondClaim = try await reopened.claimCommands(
            owner: "worker-a",
            now: .init(rawValue: 12),
            leaseUntil: .init(rawValue: 20),
            limit: 10
        )
        XCTAssertEqual(secondClaim.commands.map(\.commandID), [second.payload.commandID])
    }

    func testCompatibilityCommandCompletionUsesCurrentOwnedLeaseAndRejectsWrongOwner() async throws {
        let fixture = try submission(offset: 650)
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await store.commitSubmission(fixture.commit)
        let envelope = try command(stream: fixture.stream, number: 8, action: .resume)
        _ = try await store.enqueueCommand(envelope)
        let claim = try await store.claimCommands(
            owner: "compatibility-worker",
            now: .init(rawValue: 1),
            leaseUntil: .init(rawValue: 20),
            limit: 1
        )
        XCTAssertEqual(claim.commands.map(\.commandID), [envelope.payload.commandID])
        let receipt = try commandReceipt(for: envelope, state: .created, version: 1)

        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.completeCommand(
                commandID: envelope.payload.commandID,
                owner: "different-worker",
                receipt: receipt,
                completedAt: .init(rawValue: 2)
            )
        }
        let completed = try await store.completeCommand(
            commandID: envelope.payload.commandID,
            owner: "compatibility-worker",
            receipt: receipt,
            completedAt: .init(rawValue: 2)
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.receipt, receipt)
    }

    func testCommandLeaseExpiryIsABASafeAndDualClaimantsCannotBothOwnCommand() async throws {
        let url = temporaryDatabaseURL()
        let seed = SQLiteRunJournal(databaseURL: url)
        let fixture = try submission(offset: 700)
        _ = try await seed.commitSubmission(fixture.commit)
        let envelope = try command(stream: fixture.stream, number: 10, action: .cancel)
        _ = try await seed.enqueueCommand(envelope)
        await seed.close()

        let firstStore = SQLiteRunJournal(databaseURL: url)
        let secondStore = SQLiteRunJournal(databaseURL: url)
        async let left = firstStore.claimCommands(
            owner: "left", now: .init(rawValue: 1), leaseUntil: .init(rawValue: 10), limit: 1
        )
        async let right = secondStore.claimCommands(
            owner: "right", now: .init(rawValue: 1), leaseUntil: .init(rawValue: 10), limit: 1
        )
        let claims = try await [left, right]
        XCTAssertEqual(claims.reduce(0) { $0 + $1.commands.count }, 1)
        let original = try XCTUnwrap(claims.flatMap(\.commands).first)
        let originalLease = try XCTUnwrap(original.lease)

        let beforeExpiry = try await firstStore.claimCommands(
            owner: "early", now: .init(rawValue: 9), leaseUntil: .init(rawValue: 12), limit: 1
        )
        XCTAssertTrue(beforeExpiry.commands.isEmpty)
        let reclaimed = try await secondStore.claimCommands(
            owner: "reclaimer", now: .init(rawValue: 11), leaseUntil: .init(rawValue: 20), limit: 1
        )
        let reclaimedCommand = try XCTUnwrap(reclaimed.commands.first)
        let newLease = try XCTUnwrap(reclaimedCommand.lease)
        XCTAssertNotEqual(newLease.token, originalLease.token)
        XCTAssertEqual(newLease.generation, originalLease.generation + 1)

        let receipt = try commandReceipt(for: envelope, state: .created, version: 1)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await firstStore.completeCommand(
                commandID: envelope.payload.commandID,
                lease: originalLease,
                receipt: receipt,
                completedAt: .init(rawValue: 12)
            )
        }
        _ = try await secondStore.completeCommand(
            commandID: envelope.payload.commandID,
            lease: newLease,
            receipt: receipt,
            completedAt: .init(rawValue: 12)
        )
    }

    func testCommandPayloadBoundCancellationIndependenceAndFaultRollback() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 800)
        let store = SQLiteRunJournal(databaseURL: url)
        _ = try await store.commitSubmission(fixture.commit)
        let cancelledEnvelope = try command(stream: fixture.stream, number: 20, action: .resume)
        let detached = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.enqueueCommand(cancelledEnvelope)
        }
        let detachedAdmission = try await detached.value
        XCTAssertEqual(detachedAdmission.disposition, .admitted)

        let oversizedResponse = try UserInputResponse(
            requestID: InteractionRequestID(rawValue: RuntimeTestFixtures.uuid(900)),
            expectedRunStateVersion: 1,
            value: .string(String(repeating: "x", count: SQLiteRunJournal.maximumCommandPayloadBytes))
        )
        let oversized = try AgentCommandEnvelope(payload: AgentCommand(
            commandID: RuntimeTestFixtures.commandID(901),
            runID: fixture.stream.runID,
            expectedRunStateVersion: 1,
            action: .respond(oversizedResponse),
            issuedAt: .init(rawValue: 2)
        ))
        await assertThrows(AgentContractError.self) {
            _ = try await store.enqueueCommand(oversized)
        }

        for (index, point) in [SQLiteJournalFaultPoint.beforeCommandAdmission, .afterCommandAdmission].enumerated() {
            let faultURL = temporaryDatabaseURL()
            let faultFixture = try submission(offset: 900 + index * 20)
            let seed = SQLiteRunJournal(databaseURL: faultURL)
            _ = try await seed.commitSubmission(faultFixture.commit)
            await seed.close()
            let command = try command(stream: faultFixture.stream, number: 30 + index, action: .cancel)
            let faulting = SQLiteRunJournal(databaseURL: faultURL) { encountered in
                if encountered == point { throw SQLiteStoreError.diskFull }
            }
            await assertThrows(SQLiteStoreError.self) { _ = try await faulting.enqueueCommand(command) }
            await faulting.close()
            let loaded = try await SQLiteRunJournal(databaseURL: faultURL)
                .loadCommand(command.payload.commandID)
            XCTAssertNil(loaded)
        }

        for (index, point) in [SQLiteJournalFaultPoint.beforeCommandClaim, .afterCommandClaim].enumerated() {
            let faultURL = temporaryDatabaseURL()
            let faultFixture = try submission(offset: 2_200 + index * 20)
            let seed = SQLiteRunJournal(databaseURL: faultURL)
            _ = try await seed.commitSubmission(faultFixture.commit)
            let command = try command(stream: faultFixture.stream, number: 50 + index, action: .cancel)
            _ = try await seed.enqueueCommand(command)
            await seed.close()
            let faulting = SQLiteRunJournal(databaseURL: faultURL) { encountered in
                if encountered == point { throw SQLiteStoreError.injected(point) }
            }
            await assertThrows(SQLiteStoreError.self) {
                _ = try await faulting.claimCommands(
                    owner: "fault", now: .init(rawValue: 1), leaseUntil: .init(rawValue: 5), limit: 1
                )
            }
            await faulting.close()
            let loaded = try await SQLiteRunJournal(databaseURL: faultURL)
                .loadCommand(command.payload.commandID)
            XCTAssertEqual(loaded?.state, .pending)
        }

        for (index, point) in [SQLiteJournalFaultPoint.beforeCommandCompletion, .afterCommandCompletion].enumerated() {
            let faultURL = temporaryDatabaseURL()
            let faultFixture = try submission(offset: 2_300 + index * 20)
            let seed = SQLiteRunJournal(databaseURL: faultURL)
            _ = try await seed.commitSubmission(faultFixture.commit)
            let command = try command(stream: faultFixture.stream, number: 60 + index, action: .cancel)
            _ = try await seed.enqueueCommand(command)
            let claim = try await seed.claimCommands(
                owner: "worker", now: .init(rawValue: 1), leaseUntil: .init(rawValue: 10), limit: 1
            )
            let lease = try XCTUnwrap(claim.commands.first?.lease)
            let receipt = try commandReceipt(for: command, state: .created, version: 1)
            await seed.close()
            let faulting = SQLiteRunJournal(databaseURL: faultURL) { encountered in
                if encountered == point { throw SQLiteStoreError.injected(point) }
            }
            await assertThrows(SQLiteStoreError.self) {
                _ = try await faulting.completeCommand(
                    commandID: command.payload.commandID,
                    lease: lease,
                    receipt: receipt,
                    completedAt: .init(rawValue: 2)
                )
            }
            await faulting.close()
            let reopened = SQLiteRunJournal(databaseURL: faultURL)
            let loaded = try await reopened.loadCommand(command.payload.commandID)
            XCTAssertEqual(loaded?.state, .claimed)
            _ = try await reopened.completeCommand(
                commandID: command.payload.commandID,
                lease: lease,
                receipt: receipt,
                completedAt: .init(rawValue: 3)
            )
        }
    }

    func testCancelAndApprovalCommandsRemainFIFOAndReplayTheirExactOutcomes() async throws {
        let fixture = try submission(offset: 2_400)
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await store.commitSubmission(fixture.commit)
        let cancel = try command(stream: fixture.stream, number: 70, action: .cancel)
        let approvalID = ApprovalID(rawValue: RuntimeTestFixtures.uuid(2_401))
        let approve = try command(
            stream: fixture.stream,
            number: 71,
            action: .decideApproval(
                approvalID: approvalID,
                decision: .approved,
                approvedScope: .exactInvocation
            )
        )
        _ = try await store.enqueueCommand(cancel)
        _ = try await store.enqueueCommand(approve)
        let firstClaim = try await store.claimCommands(
            owner: "executor", now: .init(rawValue: 1), leaseUntil: .init(rawValue: 10), limit: 10
        )
        XCTAssertEqual(firstClaim.commands.map(\.commandID), [cancel.payload.commandID])
        let cancelledStatus = try AgentRunStatus(
            state: .cancelled,
            stateVersion: 2,
            terminalReason: .cancelledByUser
        )
        let cancelReceipt = try AgentCommandReceiptEnvelope(payload: AgentCommandReceipt(
            commandID: cancel.payload.commandID,
            runID: cancel.payload.runID,
            disposition: .accepted,
            currentStatus: cancelledStatus
        ))
        _ = try await store.completeCommand(
            commandID: cancel.payload.commandID,
            lease: try XCTUnwrap(firstClaim.commands.first?.lease),
            receipt: cancelReceipt,
            completedAt: .init(rawValue: 2)
        )

        let secondClaim = try await store.claimCommands(
            owner: "executor", now: .init(rawValue: 3), leaseUntil: .init(rawValue: 10), limit: 10
        )
        XCTAssertEqual(secondClaim.commands.map(\.commandID), [approve.payload.commandID])
        let staleReceipt = try AgentCommandReceiptEnvelope(payload: AgentCommandReceipt(
            commandID: approve.payload.commandID,
            runID: approve.payload.runID,
            disposition: .stale,
            currentStatus: cancelledStatus,
            failure: RuntimeTestFixtures.failure()
        ))
        _ = try await store.completeCommand(
            commandID: approve.payload.commandID,
            lease: try XCTUnwrap(secondClaim.commands.first?.lease),
            receipt: staleReceipt,
            completedAt: .init(rawValue: 4)
        )
        let replayed = try await store.enqueueCommand(approve)
        XCTAssertEqual(replayed.command.receipt, staleReceipt)
    }

    func testBudgetReserveSettleReleaseLimitsDuplicatesAndConservativeReopen() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 1_000, budgetLimit: 10)
        let store = SQLiteRunJournal(databaseURL: url)
        _ = try await store.commitSubmission(fixture.commit)
        let initialProjection = try await store.loadProjection(for: fixture.stream.runID)
        var cursor = try XCTUnwrap(initialProjection)
        let reservation = try budgetReservation(number: 1_010, inputTokens: 10)

        let reserve = try mutation(
            stream: fixture.stream,
            projection: cursor,
            commandNumber: 4_011,
            eventNumber: 3_012,
            usage: .zero,
            operations: [.reserve(reservation)]
        )
        let reserved = try await store.commit(reserve)
        XCTAssertEqual(reserved.budgetLedger.reservations, [reservation])
        cursor = reserved.appendReceipt.projection

        let duplicateReserve = try mutation(
            stream: fixture.stream,
            projection: cursor,
            commandNumber: 4_013,
            eventNumber: 3_014,
            usage: .zero,
            operations: [.reserve(reservation)]
        )
        let duplicateReserved = try await store.commit(duplicateReserve)
        XCTAssertEqual(duplicateReserved.budgetLedger.reservations, [reservation])
        cursor = duplicateReserved.appendReceipt.projection

        let actual = RuntimeTestFixtures.usage(7)
        let settle = try mutation(
            stream: fixture.stream,
            projection: cursor,
            commandNumber: 4_015,
            eventNumber: 3_016,
            usage: actual,
            operations: [.settle(reservationID: reservation.id, actualUsage: actual)]
        )
        let settled = try await store.commit(settle)
        XCTAssertEqual(settled.budgetLedger.consumed.quantities[.inputTokens], 7)
        XCTAssertTrue(settled.budgetLedger.reservations.isEmpty)
        cursor = settled.appendReceipt.projection

        let duplicateSettle = try mutation(
            stream: fixture.stream,
            projection: cursor,
            commandNumber: 4_017,
            eventNumber: 3_018,
            usage: actual,
            operations: [.settle(reservationID: reservation.id, actualUsage: actual)]
        )
        cursor = try await store.commit(duplicateSettle).appendReceipt.projection
        let beforeConflictCount = cursor.eventCount
        let conflictingSettle = try mutation(
            stream: fixture.stream,
            projection: cursor,
            commandNumber: 4_019,
            eventNumber: 3_020,
            usage: actual,
            operations: [.settle(reservationID: reservation.id, actualUsage: RuntimeTestFixtures.usage(6))]
        )
        await assertThrows(RuntimeRepositoryError.self) { _ = try await store.commit(conflictingSettle) }
        let afterConflict = try await store.loadProjection(for: fixture.stream.runID)
        XCTAssertEqual(afterConflict?.eventCount, beforeConflictCount)

        let remaining = try budgetReservation(number: 1_021, inputTokens: 3)
        let reserveRemaining = try mutation(
            stream: fixture.stream,
            projection: cursor,
            commandNumber: 4_022,
            eventNumber: 3_023,
            usage: actual,
            operations: [.reserve(remaining)]
        )
        let atLimit = try await store.commit(reserveRemaining)
        XCTAssertEqual(atLimit.budgetLedger.reservations, [remaining])
        cursor = atLimit.appendReceipt.projection
        await store.close()

        let reopened = SQLiteRunJournal(databaseURL: url)
        let loadedLedger = try await reopened.loadBudgetLedger(for: fixture.stream.runID)
        let durableLedger = try XCTUnwrap(loadedLedger)
        XCTAssertEqual(durableLedger.reservations, [remaining])
        let loadedRecovery = try await reopened.loadRecoveryFacts(for: fixture.stream.runID)
        let recovery = try XCTUnwrap(loadedRecovery)
        XCTAssertEqual(recovery.outstandingReservations, [remaining])

        let over = try budgetReservation(number: 1_024, inputTokens: 4)
        let overMutation = try mutation(
            stream: fixture.stream,
            projection: cursor,
            commandNumber: 4_025,
            eventNumber: 3_026,
            usage: actual,
            operations: [.reserve(over)]
        )
        await assertThrows(AgentContractError.self) { _ = try await reopened.commit(overMutation) }
        let projectionAfterOver = try await reopened.loadProjection(for: fixture.stream.runID)
        XCTAssertEqual(projectionAfterOver?.eventCount, cursor.eventCount)

        let release = try mutation(
            stream: fixture.stream,
            projection: cursor,
            commandNumber: 4_027,
            eventNumber: 3_028,
            usage: actual,
            operations: [.release(reservationID: remaining.id)]
        )
        let released = try await reopened.commit(release)
        XCTAssertTrue(released.budgetLedger.reservations.isEmpty)
        let duplicateRelease = try mutation(
            stream: fixture.stream,
            projection: released.appendReceipt.projection,
            commandNumber: 4_029,
            eventNumber: 3_030,
            usage: actual,
            operations: [.release(reservationID: remaining.id)]
        )
        let duplicateReleased = try await reopened.commit(duplicateRelease)
        XCTAssertTrue(duplicateReleased.budgetLedger.reservations.isEmpty)
    }

    func testBudgetAndEventFaultsAreOneAtomicUnitAndPostCommitRetryReplaysLedger() async throws {
        for (index, point) in [SQLiteJournalFaultPoint.beforeBudgetMutation, .afterBudgetMutation, .beforeCommit].enumerated() {
            let url = temporaryDatabaseURL()
            let fixture = try submission(offset: 1_100 + index * 30, budgetLimit: 10)
            let seed = SQLiteRunJournal(databaseURL: url)
            _ = try await seed.commitSubmission(fixture.commit)
            let loadedProjection = try await seed.loadProjection(for: fixture.stream.runID)
            let projection = try XCTUnwrap(loadedProjection)
            await seed.close()
            let reservation = try budgetReservation(number: 1_200 + index, inputTokens: 2)
            let change = try mutation(
                stream: fixture.stream,
                projection: projection,
                commandNumber: 1_210 + index,
                eventNumber: 1_220 + index,
                usage: .zero,
                operations: [.reserve(reservation)]
            )
            let faulting = SQLiteRunJournal(databaseURL: url) { encountered in
                if encountered == point { throw SQLiteStoreError.injected(point) }
            }
            await assertThrows(SQLiteStoreError.self) { _ = try await faulting.commit(change) }
            await faulting.close()
            let reopened = SQLiteRunJournal(databaseURL: url)
            let projectionAfterFault = try await reopened.loadProjection(for: fixture.stream.runID)
            let ledgerAfterFault = try await reopened.loadBudgetLedger(for: fixture.stream.runID)
            XCTAssertEqual(projectionAfterFault?.eventCount, 1)
            XCTAssertTrue(try XCTUnwrap(ledgerAfterFault).reservations.isEmpty)
        }

        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 1_300, budgetLimit: 10)
        let seed = SQLiteRunJournal(databaseURL: url)
        _ = try await seed.commitSubmission(fixture.commit)
        let loadedProjection = try await seed.loadProjection(for: fixture.stream.runID)
        let projection = try XCTUnwrap(loadedProjection)
        await seed.close()
        let reservation = try budgetReservation(number: 1_301, inputTokens: 2)
        let change = try mutation(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 1_302,
            eventNumber: 1_303,
            usage: .zero,
            operations: [.reserve(reservation)]
        )
        let uncertain = SQLiteRunJournal(databaseURL: url) { point in
            if point == .afterCommit { throw SQLiteStoreError.injected(point) }
        }
        await assertThrows(SQLiteStoreError.self) { _ = try await uncertain.commit(change) }
        await uncertain.close()
        let reopened = SQLiteRunJournal(databaseURL: url)
        let replay = try await reopened.commit(change)
        XCTAssertEqual(replay.appendReceipt.disposition, .replayed)
        XCTAssertEqual(replay.budgetLedger.reservations, [reservation])
        let reservationCount = try await reopened.rowCount(table: "budget_reservations")
        XCTAssertEqual(reservationCount, 1)
    }

    func testTypedLoadersPreserveBothSidesOfEveryDurableFact() async throws {
        let fixture = try submission(offset: 1_400)
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await store.commitSubmission(fixture.commit)
        let loadedProjection = try await store.loadProjection(for: fixture.stream.runID)
        let projection = try XCTUnwrap(loadedProjection)
        let prepared = try preparedRequest(stream: fixture.stream, number: 1_410, idempotency: .pureRead)
        let invocationID = try XCTUnwrap(prepared.invocationID)
        let approval = try AgentApprovalRequest(
            id: ApprovalID(rawValue: RuntimeTestFixtures.uuid(1_411)),
            prepared: prepared,
            policyVersion: 1,
            createdAt: .init(rawValue: 10)
        )
        let approvalReceipt = try ApprovalReceipt(
            request: approval,
            decision: .approved,
            scope: .exactInvocation,
            decidedAt: .init(rawValue: 11)
        )
        let interaction = try UserInputRequest(
            id: InteractionRequestID(rawValue: RuntimeTestFixtures.uuid(1_412)),
            runID: fixture.stream.runID,
            prompt: "Choose a durable option",
            creationStateVersion: 1
        )
        let manifest = try AgentStableBoundaryReference(digest: digest("typed-manifest"))
        let response = try AgentStableBoundaryReference(digest: digest("typed-response"))
        let failedOutcome = AgentToolInvocationOutcome.failed(try RuntimeTestFixtures.failure())
        let events: [AgentEvent] = [
            .compiledManifestCommitted(stepID: prepared.stepID, reference: manifest),
            .toolIntentRecorded(prepared),
            .toolOutcomeRecorded(invocationID: invocationID, outcome: failedOutcome),
            .approvalRequested(approval),
            .approvalDecided(approvalReceipt),
            .userInputRequested(interaction),
            .userInputResponseCommitted(requestID: interaction.id, reference: response),
        ]
        let append = try appendSameStateEvents(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 1_420,
            baseEventNumber: 1_430,
            events: events
        )
        _ = try await store.append(append)

        let manifests = try await store.loadCompiledManifests(for: fixture.stream.runID)
        XCTAssertEqual(manifests.map(\.reference), [manifest])
        XCTAssertEqual(manifests.map(\.stepID), [prepared.stepID])
        let tools = try await store.loadToolInvocations(for: fixture.stream.runID)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].request, prepared)
        XCTAssertEqual(tools[0].outcome, failedOutcome)
        XCTAssertEqual(tools[0].state, .completed)
        let approvals = try await store.loadApprovals(for: fixture.stream.runID)
        XCTAssertEqual(approvals.map(\.request), [approval])
        XCTAssertEqual(approvals.map(\.receipt), [approvalReceipt])
        let interactions = try await store.loadInteractions(for: fixture.stream.runID)
        XCTAssertEqual(interactions.map(\.request), [interaction])
        XCTAssertEqual(interactions.map(\.response), [response])
        let loadedRecovery = try await store.loadRecoveryFacts(for: fixture.stream.runID)
        let recovery = try XCTUnwrap(loadedRecovery)
        XCTAssertTrue(recovery.pendingApprovalIDs.isEmpty)
        XCTAssertTrue(recovery.pendingInteractionIDs.isEmpty)
        let stableDirective = try await store.recoveryDirective(for: fixture.stream.runID)
        XCTAssertEqual(stableDirective?.disposition, .alreadyStable)
    }

    func testRecoveryClassificationComesOnlyFromDurableModelAndToolFacts() async throws {
        let modelFixture = try submission(offset: 1_500)
        let modelStore = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await modelStore.commitSubmission(modelFixture.commit)
        let loadedModelInitial = try await modelStore.loadProjection(for: modelFixture.stream.runID)
        let modelInitial = try XCTUnwrap(loadedModelInitial)
        let modelAppend = try transitionAppend(
            stream: modelFixture.stream,
            projection: modelInitial,
            commandNumber: 1_501,
            baseEventNumber: 1_510,
            states: [.preparing, .waitingForModel, .generating],
            finalEvent: nil
        )
        _ = try await modelStore.append(modelAppend)
        let modelDirective = try await modelStore.recoveryDirective(for: modelFixture.stream.runID)
        XCTAssertEqual(modelDirective?.disposition, .discardIncompleteModelAttempt)

        for (index, pair) in [
            (ExternalIdempotency.pureRead, RecoveryDisposition.retryPureRead),
            (.idempotencyKeyRequired, .retryIdempotentWrite),
            (.reconciliationAvailable, .waitingForReconciliation),
            (.nonIdempotent, .waitingForReconciliation),
        ].enumerated() {
            let fixture = try submission(offset: 1_600 + index * 100)
            let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
            _ = try await store.commitSubmission(fixture.commit)
            let loadedInitial = try await store.loadProjection(for: fixture.stream.runID)
            let initial = try XCTUnwrap(loadedInitial)
            let prepared = try preparedRequest(
                stream: fixture.stream,
                number: 1_650 + index,
                idempotency: pair.0
            )
            let append = try transitionAppend(
                stream: fixture.stream,
                projection: initial,
                commandNumber: 1_660 + index,
                baseEventNumber: 1_670 + index * 10,
                states: [.preparing, .waitingForModel, .generating, .validatingAction, .executingTools],
                finalEvent: .toolIntentRecorded(prepared)
            )
            _ = try await store.append(append)
            let loadedDirective = try await store.recoveryDirective(for: fixture.stream.runID)
            let directive = try XCTUnwrap(loadedDirective)
            XCTAssertEqual(directive.disposition, pair.1)
            XCTAssertTrue(directive.requiresExplicitResume)
        }
    }

    func testCompatibilityRecoveryHintIsIgnoredAndLegacyReservationRemainsDurable() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 1_950, budgetLimit: 10)
        let store = SQLiteRunJournal(databaseURL: url)
        _ = try await store.commitSubmission(fixture.commit)

        let asyncDirective = try await store.recoveryDirective(for: fixture.stream.runID)
        let compatibilityDirective = try await store.recoveryDirective(
            for: fixture.stream.runID,
            interruptedOperation: .nonIdempotentWrite
        )
        XCTAssertEqual(compatibilityDirective, asyncDirective)
        XCTAssertEqual(compatibilityDirective?.disposition, .alreadyStable)

        let reservation = try budgetReservation(number: 1_951, inputTokens: 3)
        try await store.recordBudgetReservation(
            runID: fixture.stream.runID,
            reservation: reservation
        )
        let reservationCount = try await store.rowCount(table: "budget_reservations")
        XCTAssertEqual(reservationCount, 1)
        await store.close()

        let reopened = SQLiteRunJournal(databaseURL: url)
        let reopenedReservationCount = try await reopened.rowCount(table: "budget_reservations")
        XCTAssertEqual(reopenedReservationCount, 1)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await reopened.loadRecoveryFacts(for: fixture.stream.runID)
        }
    }

    func testEmptyRepositorySurfacesStayLazyAndCommandLeaseValidationFailsClosed() async throws {
        let url = temporaryDatabaseURL()
        let store = SQLiteRunJournal(databaseURL: url)
        let stream = RuntimeTestFixtures.Stream(offset: 20_000)
        let unknownCommand = try command(stream: stream, number: 20_001, action: .resume)
        let prepared = try preparedRequest(
            stream: stream,
            number: 20_002,
            idempotency: .pureRead
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)

        let absentCommand = try await store.loadCommand(unknownCommand.payload.commandID)
        let absentLedger = try await store.loadBudgetLedger(for: stream.runID)
        let absentRunFacts = try await store.loadRunFacts(for: stream.runID)
        let absentHandleFacts = try await store.loadRunFacts(for: stream.executionHandleID)
        let absentRunSnapshot = try await store.loadRunSnapshot(for: stream.runID)
        let absentHandleSnapshot = try await store.loadRunSnapshot(for: stream.executionHandleID)
        let absentManifests = try await store.loadCompiledManifests(for: stream.runID)
        let absentApprovals = try await store.loadApprovals(for: stream.runID)
        let absentInteractions = try await store.loadInteractions(for: stream.runID)
        let absentTools = try await store.loadToolInvocations(for: stream.runID)
        let absentRecoveryFacts = try await store.loadRecoveryFacts(for: stream.runID)
        let absentDirective = try await store.recoveryDirective(for: stream.runID)
        let absentBoundaryEvidence = try await store.boundaryClaimEvidence(
            approvalID: ApprovalID(rawValue: RuntimeTestFixtures.uuid(20_003)),
            prepared: prepared,
            attempt: attempt
        )
        let absentRunCount = try await store.rowCount(table: "runs")
        XCTAssertNil(absentCommand)
        XCTAssertNil(absentLedger)
        XCTAssertNil(absentRunFacts)
        XCTAssertNil(absentHandleFacts)
        XCTAssertNil(absentRunSnapshot)
        XCTAssertNil(absentHandleSnapshot)
        XCTAssertEqual(absentManifests, [])
        XCTAssertEqual(absentApprovals, [])
        XCTAssertEqual(absentInteractions, [])
        XCTAssertEqual(absentTools, [])
        XCTAssertNil(absentRecoveryFacts)
        XCTAssertNil(absentDirective)
        XCTAssertEqual(absentBoundaryEvidence, .none)
        XCTAssertEqual(absentRunCount, 0)
        XCTAssertFalse(store.databaseExists())

        for invalid in [
            ("", Int64(1), Int64(2), 1),
            ("worker", Int64(2), Int64(2), 1),
            ("worker", Int64(1), Int64(2), 0),
            ("worker", Int64(1), Int64(2), 257),
            ("worker\u{7f}", Int64(1), Int64(2), 1),
        ] {
            await assertThrows(SQLiteStoreError.self) {
                _ = try await store.claimCommands(
                    owner: invalid.0,
                    now: .init(rawValue: invalid.1),
                    leaseUntil: .init(rawValue: invalid.2),
                    limit: invalid.3
                )
            }
        }

        let validLease = AgentCommandLeaseIdentity(
            owner: "worker",
            token: RuntimeTestFixtures.uuid(20_004),
            generation: 1,
            expiresAt: .init(rawValue: 20)
        )
        let receipt = try commandReceipt(for: unknownCommand, state: .created, version: 1)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.completeCommand(
                commandID: unknownCommand.payload.commandID,
                lease: validLease,
                receipt: receipt,
                completedAt: .init(rawValue: 10)
            )
        }
        let otherCommandID = RuntimeTestFixtures.commandID(20_005)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.completeCommand(
                commandID: otherCommandID,
                lease: validLease,
                receipt: receipt,
                completedAt: .init(rawValue: 10)
            )
        }
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.completeCommand(
                commandID: unknownCommand.payload.commandID,
                lease: AgentCommandLeaseIdentity(
                    owner: "",
                    token: RuntimeTestFixtures.uuid(20_006),
                    generation: 0,
                    expiresAt: .init(rawValue: 20)
                ),
                receipt: receipt,
                completedAt: .init(rawValue: 10)
            )
        }

        _ = try await store.openForWrite()
        let unresolvedSnapshot = try await store.loadRunSnapshot(for: stream.executionHandleID)
        XCTAssertNil(unresolvedSnapshot)
    }

    func testCommandCompletionRejectsWrongRunMissingLeaseAndExpiredLease() async throws {
        let fixture = try submission(offset: 20_100)
        let other = try submission(offset: 20_200)
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await store.commitSubmission(fixture.commit)
        _ = try await store.commitSubmission(other.commit)
        let envelope = try command(stream: fixture.stream, number: 20_101, action: .resume)
        _ = try await store.enqueueCommand(envelope)
        let fakeLease = AgentCommandLeaseIdentity(
            owner: "worker-a",
            token: RuntimeTestFixtures.uuid(20_102),
            generation: 1,
            expiresAt: .init(rawValue: 10)
        )
        let correctReceipt = try commandReceipt(for: envelope, state: .created, version: 1)

        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.completeCommand(
                commandID: envelope.payload.commandID,
                lease: fakeLease,
                receipt: correctReceipt,
                completedAt: .init(rawValue: 2)
            )
        }
        let wrongRunReceipt = try AgentCommandReceiptEnvelope(payload: AgentCommandReceipt(
            commandID: envelope.payload.commandID,
            runID: other.stream.runID,
            disposition: .accepted,
            currentStatus: AgentRunStatus(state: .created, stateVersion: 1)
        ))
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.completeCommand(
                commandID: envelope.payload.commandID,
                lease: fakeLease,
                receipt: wrongRunReceipt,
                completedAt: .init(rawValue: 2)
            )
        }

        let claim = try await store.claimCommands(
            owner: "worker-a",
            now: .init(rawValue: 1),
            leaseUntil: .init(rawValue: 10),
            limit: 1
        )
        let lease = try XCTUnwrap(claim.commands.first?.lease)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.completeCommand(
                commandID: envelope.payload.commandID,
                lease: lease,
                receipt: correctReceipt,
                completedAt: .init(rawValue: 11)
            )
        }
    }

    func testMutationAndFinalizationLedgerFallbacksAreExplicit() async throws {
        let noLedgerStream = RuntimeTestFixtures.Stream(offset: 20_300)
        let noLedgerStore = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        let initial = try RuntimeTestFixtures.envelope(
            stream: noLedgerStream,
            eventNumber: 20_301,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        _ = try await noLedgerStore.append(try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(20_301)),
            runID: noLedgerStream.runID,
            expectedRunStateVersion: 1,
            events: [initial]
        ))
        let loadedProjection = try await noLedgerStore.loadProjection(for: noLedgerStream.runID)
        let projection = try XCTUnwrap(loadedProjection)
        let mutationWithoutLedger = try mutation(
            stream: noLedgerStream,
            projection: projection,
            commandNumber: 20_302,
            eventNumber: 20_303,
            usage: .zero,
            operations: []
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await noLedgerStore.commit(mutationWithoutLedger)
        }
        let committedWithoutLedger = try await noLedgerStore.loadProjection(for: noLedgerStream.runID)
        XCTAssertEqual(
            committedWithoutLedger?.eventCount,
            1,
            "a missing required ledger must fail before the causal event is committed"
        )

        let noLedgerAssistant = messageReference(
            stream: noLedgerStream,
            conversation: ConversationID(rawValue: RuntimeTestFixtures.uuid(20_304)),
            role: .assistant,
            number: 20_305
        )
        let noLedgerFinalization = RuntimeFinalizationCommit(
            message: noLedgerAssistant,
            outbox: outboxItem(message: noLedgerAssistant, kind: .finalAnswer),
            mutation: try terminalMutation(
                stream: noLedgerStream,
                first: initial,
                commandNumber: 20_306,
                baseEventNumber: 20_320
            )
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await noLedgerStore.commitFinalization(noLedgerFinalization)
        }
        let afterRejectedFinalization = try await noLedgerStore.loadProjection(
            for: noLedgerStream.runID
        )
        XCTAssertEqual(afterRejectedFinalization?.state, .created)
        XCTAssertEqual(afterRejectedFinalization?.eventCount, 1)
        let rejectedMessageCount = try await noLedgerStore.rowCount(table: "messages")
        let rejectedOutboxCount = try await noLedgerStore.rowCount(table: "projection_outbox")
        XCTAssertEqual(rejectedMessageCount, 0)
        XCTAssertEqual(rejectedOutboxCount, 0)

        let missingLedgerStream = RuntimeTestFixtures.Stream(offset: 20_400)
        let missingLedgerStore = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        let missingInitial = try RuntimeTestFixtures.envelope(
            stream: missingLedgerStream,
            eventNumber: 20_401,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        _ = try await missingLedgerStore.append(try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(20_401)),
            runID: missingLedgerStream.runID,
            expectedRunStateVersion: 1,
            events: [missingInitial]
        ))
        let loadedMissingProjection = try await missingLedgerStore.loadProjection(
            for: missingLedgerStream.runID
        )
        let missingProjection = try XCTUnwrap(loadedMissingProjection)
        let reservation = try budgetReservation(number: 20_402, inputTokens: 1)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await missingLedgerStore.commit(try mutation(
                stream: missingLedgerStream,
                projection: missingProjection,
                commandNumber: 20_403,
                eventNumber: 20_404,
                usage: .zero,
                operations: [.reserve(reservation)]
            ))
        }
        let projectionAfterMissingLedger = try await missingLedgerStore.loadProjection(
            for: missingLedgerStream.runID
        )
        XCTAssertEqual(projectionAfterMissingLedger?.eventCount, 1, "a missing ledger must roll back the causal event")

        let fixture = try submission(offset: 20_500)
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await store.commitSubmission(fixture.commit)
        let terminalMutation = try terminalMutation(
            stream: fixture.stream,
            first: fixture.commit.initialAppend.events[0],
            commandNumber: 20_501,
            baseEventNumber: 20_530
        )
        let assistant = messageReference(
            stream: fixture.stream,
            conversation: fixture.commit.userMessage.conversationID,
            role: .assistant,
            number: 20_520
        )
        let finalOutbox = outboxItem(message: assistant, kind: .finalAnswer)
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.commitFinalization(RuntimeFinalizationCommit(
                message: assistant,
                outbox: outboxItem(message: assistant, kind: .acceptedUserMessage),
                mutation: terminalMutation
            ))
        }
        let finalized = try await store.commitFinalization(RuntimeFinalizationCommit(
            message: assistant,
            outbox: finalOutbox,
            mutation: terminalMutation
        ))
        XCTAssertTrue(finalized.appendReceipt.projection.isTerminal)
        XCTAssertEqual(finalized.budgetLedger, fixture.commit.initialLedger)
        let terminalDirective = try await store.recoveryDirective(for: fixture.stream.runID)
        XCTAssertEqual(terminalDirective?.disposition, .alreadyStable)
    }

    func testSubmissionReplayFallsBackToDurableLedgerAndFailsWhenLedgerWasLost() async throws {
        let fallbackURL = temporaryDatabaseURL()
        let fallbackFixture = try submission(offset: 20_600)
        let fallbackStore = SQLiteRunJournal(databaseURL: fallbackURL)
        _ = try await fallbackStore.commitSubmission(fallbackFixture.commit)
        try executeRaw(
            at: fallbackURL,
            sql: "UPDATE mutation_receipts SET ledger_payload = NULL"
        )
        let replay = try await fallbackStore.commitSubmission(fallbackFixture.commit)
        XCTAssertEqual(replay.appendReceipt.disposition, .replayed)
        XCTAssertEqual(replay.budgetLedger, fallbackFixture.commit.initialLedger)

        let missingURL = temporaryDatabaseURL()
        let missingFixture = try submission(offset: 20_700)
        let missingStore = SQLiteRunJournal(databaseURL: missingURL)
        _ = try await missingStore.commitSubmission(missingFixture.commit)
        try executeRaw(
            at: missingURL,
            sql: "UPDATE mutation_receipts SET ledger_payload = NULL"
        )
        try executeRaw(
            at: missingURL,
            sql: "DELETE FROM budget_ledgers WHERE run_id = ?",
            values: [.text(missingFixture.stream.runID.description)]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await missingStore.commitSubmission(missingFixture.commit)
        }
    }

    func testBudgetOperationConflictsAndUsageMismatchRollBackTheirCausalEvents() async throws {
        let fixture = try submission(offset: 20_800, budgetLimit: 20)
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await store.commitSubmission(fixture.commit)
        let loadedInitialProjection = try await store.loadProjection(for: fixture.stream.runID)
        var projection = try XCTUnwrap(loadedInitialProjection)

        let first = try budgetReservation(number: 20_801, inputTokens: 2)
        let reserved = try await store.commit(try mutation(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 20_802,
            eventNumber: 20_803,
            usage: .zero,
            operations: [.reserve(first)]
        ))
        projection = reserved.appendReceipt.projection

        let conflictingFirst = try BudgetReservation(
            id: first.id,
            maximumUsage: RuntimeTestFixtures.usage(3),
            reason: "different.maximum"
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.commit(try mutation(
                stream: fixture.stream,
                projection: projection,
                commandNumber: 20_804,
                eventNumber: 20_805,
                usage: .zero,
                operations: [.reserve(conflictingFirst)]
            ))
        }

        let missingID = BudgetReservationID(rawValue: RuntimeTestFixtures.uuid(20_806))
        for operation in [
            BudgetLedgerOperation.settle(
                reservationID: missingID,
                actualUsage: RuntimeTestFixtures.usage(1)
            ),
            .release(reservationID: missingID),
        ] {
            await assertThrows(RuntimeRepositoryError.self) {
                _ = try await store.commit(try mutation(
                    stream: fixture.stream,
                    projection: projection,
                    commandNumber: 20_807,
                    eventNumber: 20_808,
                    usage: .zero,
                    operations: [operation]
                ))
            }
        }

        let released = try await store.commit(try mutation(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 20_809,
            eventNumber: 20_810,
            usage: .zero,
            operations: [.release(reservationID: first.id)]
        ))
        projection = released.appendReceipt.projection
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.commit(try mutation(
                stream: fixture.stream,
                projection: projection,
                commandNumber: 20_811,
                eventNumber: 20_812,
                usage: .zero,
                operations: [.settle(
                    reservationID: first.id,
                    actualUsage: RuntimeTestFixtures.usage(1)
                )]
            ))
        }

        let second = try budgetReservation(number: 20_813, inputTokens: 4)
        let secondReserved = try await store.commit(try mutation(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 20_814,
            eventNumber: 20_815,
            usage: .zero,
            operations: [.reserve(second)]
        ))
        projection = secondReserved.appendReceipt.projection
        let actual = RuntimeTestFixtures.usage(2)
        let secondSettled = try await store.commit(try mutation(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 20_816,
            eventNumber: 20_817,
            usage: actual,
            operations: [.settle(reservationID: second.id, actualUsage: actual)]
        ))
        projection = secondSettled.appendReceipt.projection
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.commit(try mutation(
                stream: fixture.stream,
                projection: projection,
                commandNumber: 20_818,
                eventNumber: 20_819,
                usage: actual,
                operations: [.release(reservationID: second.id)]
            ))
        }

        let third = try budgetReservation(number: 20_820, inputTokens: 1)
        let thirdReserved = try await store.commit(try mutation(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 20_821,
            eventNumber: 20_822,
            usage: actual,
            operations: [.reserve(third)]
        ))
        projection = thirdReserved.appendReceipt.projection
        let eventCountBeforeMismatch = projection.eventCount
        await assertThrows(SQLiteStoreError.self) {
            _ = try await store.commit(try mutation(
                stream: fixture.stream,
                projection: projection,
                commandNumber: 20_823,
                eventNumber: 20_824,
                usage: actual,
                operations: [.settle(
                    reservationID: third.id,
                    actualUsage: RuntimeTestFixtures.usage(1)
                )]
            ))
        }
        let afterMismatch = try await store.loadProjection(for: fixture.stream.runID)
        let ledgerAfterMismatch = try await store.loadBudgetLedger(for: fixture.stream.runID)
        XCTAssertEqual(afterMismatch?.eventCount, eventCountBeforeMismatch)
        XCTAssertEqual(ledgerAfterMismatch?.reservations, [third])
        XCTAssertEqual(ledgerAfterMismatch?.consumed.quantities[.inputTokens], 2)
    }

    func testBoundaryClaimRejectsMismatchedAttemptsMissingSubmissionsAndReusedIdentity() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 20_900)
        let store = SQLiteRunJournal(databaseURL: url)
        _ = try await store.commitSubmission(fixture.commit)
        let loadedCreated = try await store.loadProjection(for: fixture.stream.runID)
        let created = try XCTUnwrap(loadedCreated)
        _ = try await store.append(try transitionAppend(
            stream: fixture.stream,
            projection: created,
            commandNumber: 20_901,
            baseEventNumber: 20_902,
            states: [.preparing, .waitingForModel, .generating],
            finalEvent: nil
        ))
        let prepared = try preparedRequest(
            stream: fixture.stream,
            number: 20_910,
            idempotency: .pureRead
        )
        let firstAttempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        let otherPrepared = try preparedRequest(
            stream: fixture.stream,
            number: 20_913,
            idempotency: .pureRead
        )
        let secondAttempt = try ExternalOperationAttempt(prepared: otherPrepared, attemptNumber: 1)
        let secondHop = try ExternalOperationBoundaryHop(
            prepared: otherPrepared,
            attempt: secondAttempt,
            destination: otherPrepared.plan.destination
        )
        let approvalID = ApprovalID(rawValue: RuntimeTestFixtures.uuid(20_911))
        let scope = try RuntimeBoundaryClaimScope(
            runID: fixture.stream.runID,
            expectedState: .generating,
            expectedStateVersion: 4
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.claimBoundaryHop(
                scope: scope,
                approvalID: approvalID,
                preparedRequestFingerprint: prepared.fingerprint,
                attempt: firstAttempt,
                hop: secondHop
            )
        }

        let firstHop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: firstAttempt,
            destination: prepared.plan.destination
        )
        let initiallyClaimed = try await store.claimBoundaryHop(
            scope: scope,
            approvalID: approvalID,
            preparedRequestFingerprint: prepared.fingerprint,
            attempt: firstAttempt,
            hop: firstHop
        )
        XCTAssertTrue(initiallyClaimed)
        try executeRaw(
            at: url,
            sql: "UPDATE external_claims SET approval_id = ? WHERE claim_id = ?",
            values: [
                .text(ApprovalID(rawValue: RuntimeTestFixtures.uuid(20_912)).description),
                .text("boundary-hop:\(firstHop.fingerprint.rawValue)"),
            ]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.claimBoundaryHop(
                scope: scope,
                approvalID: approvalID,
                preparedRequestFingerprint: prepared.fingerprint,
                attempt: firstAttempt,
                hop: firstHop
            )
        }

        let missingStream = RuntimeTestFixtures.Stream(offset: 21_000)
        let missingStore = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        let missingInitial = try RuntimeTestFixtures.envelope(
            stream: missingStream,
            eventNumber: 21_001,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil
        )
        _ = try await missingStore.append(try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(21_001)),
            runID: missingStream.runID,
            expectedRunStateVersion: 1,
            events: [missingInitial]
        ))
        let loadedMissingCreated = try await missingStore.loadProjection(for: missingStream.runID)
        let missingCreated = try XCTUnwrap(loadedMissingCreated)
        _ = try await missingStore.append(try transitionAppend(
            stream: missingStream,
            projection: missingCreated,
            commandNumber: 21_002,
            baseEventNumber: 21_003,
            states: [.preparing, .waitingForModel, .generating],
            finalEvent: nil
        ))
        let missingPrepared = try preparedRequest(
            stream: missingStream,
            number: 21_010,
            idempotency: .pureRead
        )
        let missingAttempt = try ExternalOperationAttempt(
            prepared: missingPrepared,
            attemptNumber: 1
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await missingStore.claimBoundaryHop(
                scope: try RuntimeBoundaryClaimScope(
                    runID: missingStream.runID,
                    expectedState: .generating,
                    expectedStateVersion: 4
                ),
                approvalID: ApprovalID(rawValue: RuntimeTestFixtures.uuid(21_011)),
                preparedRequestFingerprint: missingPrepared.fingerprint,
                attempt: missingAttempt,
                hop: try ExternalOperationBoundaryHop(
                    prepared: missingPrepared,
                    attempt: missingAttempt,
                    destination: missingPrepared.plan.destination
                )
            )
        }
    }

    func testCommandRowsFailClosedForEveryCorruptLifecycleShape() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 21_100)
        let store = SQLiteRunJournal(databaseURL: url)
        _ = try await store.commitSubmission(fixture.commit)
        let envelope = try command(stream: fixture.stream, number: 21_101, action: .resume)
        let admission = try await store.enqueueCommand(envelope)
        let commandID = envelope.payload.commandID

        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET fingerprint = 'not-a-digest' WHERE command_id = ?",
            values: [.text(commandID.description)]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadCommand(commandID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET fingerprint = ? WHERE command_id = ?",
            values: [.text(admission.command.fingerprint.rawValue), .text(commandID.description)]
        )

        let replacementID = RuntimeTestFixtures.commandID(21_102)
        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET command_id = ? WHERE command_id = ?",
            values: [.text(replacementID.description), .text(commandID.description)]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadCommand(replacementID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET command_id = ? WHERE command_id = ?",
            values: [.text(commandID.description), .text(replacementID.description)]
        )

        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET command_id = 'invalid-command-id' WHERE command_id = ?",
            values: [.text(commandID.description)]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.claimCommands(
                owner: "worker",
                now: .init(rawValue: 1),
                leaseUntil: .init(rawValue: 10),
                limit: 1
            )
        }
        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET command_id = ? WHERE command_id = 'invalid-command-id'",
            values: [.text(commandID.description)]
        )

        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET attempt_count = 4294967296 WHERE command_id = ?",
            values: [.text(commandID.description)]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadCommand(commandID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET attempt_count = 0 WHERE command_id = ?",
            values: [.text(commandID.description)]
        )

        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET claim_owner = 'impossible' WHERE command_id = ?",
            values: [.text(commandID.description)],
            ignoringCheckConstraints: true
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadCommand(commandID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET claim_owner = NULL WHERE command_id = ?",
            values: [.text(commandID.description)],
            ignoringCheckConstraints: true
        )

        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET state = 'claimed', claim_owner = 'worker', claim_expires_at = 10, lease_token = ?, lease_generation = 0 WHERE command_id = ?",
            values: [.text(RuntimeTestFixtures.uuid(21_103).uuidString), .text(commandID.description)],
            ignoringCheckConstraints: true
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadCommand(commandID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET state = 'pending', claim_owner = NULL, claim_expires_at = NULL, lease_token = NULL, lease_generation = 0 WHERE command_id = ?",
            values: [.text(commandID.description)],
            ignoringCheckConstraints: true
        )

        try executeRaw(
            at: url,
            sql: "UPDATE agent_commands SET state = 'completed', lease_generation = 1, completed_at = 10, receipt = NULL WHERE command_id = ?",
            values: [.text(commandID.description)],
            ignoringCheckConstraints: true
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadCommand(commandID)
        }
    }

    func testCorruptTypedRowsHandlesSubmissionsOutboxAndDeletionFailClosed() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 21_200)
        let store = SQLiteRunJournal(databaseURL: url)
        _ = try await store.commitSubmission(fixture.commit)
        let loadedProjection = try await store.loadProjection(for: fixture.stream.runID)
        let projection = try XCTUnwrap(loadedProjection)
        let prepared = try preparedRequest(
            stream: fixture.stream,
            number: 21_210,
            idempotency: .pureRead
        )
        let invocationID = try XCTUnwrap(prepared.invocationID)
        let approval = try AgentApprovalRequest(
            id: ApprovalID(rawValue: RuntimeTestFixtures.uuid(21_211)),
            prepared: prepared,
            policyVersion: 1,
            createdAt: .init(rawValue: 10)
        )
        let approvalReceipt = try ApprovalReceipt(
            request: approval,
            decision: .approved,
            scope: .exactInvocation,
            decidedAt: .init(rawValue: 11)
        )
        let interaction = try UserInputRequest(
            id: InteractionRequestID(rawValue: RuntimeTestFixtures.uuid(21_212)),
            runID: fixture.stream.runID,
            prompt: "Keep corrupt durable rows fail-closed",
            creationStateVersion: 1
        )
        let response = try AgentStableBoundaryReference(digest: digest("corrupt-response"))
        let manifest = try AgentStableBoundaryReference(digest: digest("corrupt-manifest"))
        let outcome = AgentToolInvocationOutcome.failed(try RuntimeTestFixtures.failure())
        _ = try await store.append(try appendSameStateEvents(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 21_220,
            baseEventNumber: 21_230,
            events: [
                .compiledManifestCommitted(stepID: prepared.stepID, reference: manifest),
                .toolIntentRecorded(prepared),
                .toolOutcomeRecorded(invocationID: invocationID, outcome: outcome),
                .approvalRequested(approval),
                .approvalDecided(approvalReceipt),
                .userInputRequested(interaction),
                .userInputResponseCommitted(requestID: interaction.id, reference: response),
            ]
        ))

        try executeRaw(at: url, sql: "UPDATE compiled_manifests SET payload = NULL")
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadCompiledManifests(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE compiled_manifests SET payload = ?",
            values: [.blob(try wireData(manifest))]
        )

        try executeRaw(at: url, sql: "UPDATE approvals SET request_payload = NULL")
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadApprovals(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE approvals SET request_payload = ?",
            values: [.blob(try wireData(approval))]
        )
        try executeRaw(at: url, sql: "UPDATE approvals SET receipt_payload = NULL")
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadApprovals(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE approvals SET receipt_payload = ?",
            values: [.blob(try wireData(approvalReceipt))]
        )

        try executeRaw(at: url, sql: "UPDATE interactions SET request_payload = NULL")
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadInteractions(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE interactions SET request_payload = ?",
            values: [.blob(try wireData(interaction))]
        )
        try executeRaw(at: url, sql: "UPDATE interactions SET response_payload = NULL")
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadInteractions(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE interactions SET response_payload = ?",
            values: [.blob(try wireData(response))]
        )

        try executeRaw(at: url, sql: "UPDATE tool_invocations SET intent_payload = NULL")
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadToolInvocations(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE tool_invocations SET intent_payload = ?",
            values: [.blob(try wireData(prepared))]
        )
        try executeRaw(at: url, sql: "UPDATE tool_invocations SET outcome_payload = NULL")
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadToolInvocations(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE tool_invocations SET outcome_payload = ?",
            values: [.blob(try wireData(outcome))]
        )

        try executeRaw(
            at: url,
            sql: "UPDATE run_submissions SET execution_handle_id = 'invalid-handle'"
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadRunFacts(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE run_submissions SET execution_handle_id = ?",
            values: [.text(fixture.stream.executionHandleID.description)]
        )
        let other = try submission(offset: 21_300)
        try executeRaw(
            at: url,
            sql: "UPDATE run_submissions SET request_payload = ?",
            values: [.blob(try wireData(other.commit.request))]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.loadRunFacts(for: fixture.stream.runID)
        }
        try executeRaw(
            at: url,
            sql: "UPDATE run_submissions SET request_payload = ?",
            values: [.blob(try wireData(fixture.commit.request))]
        )

        try executeRaw(
            at: url,
            sql: "UPDATE projection_outbox SET kind = 'invalid-kind'"
        )
        await assertThrows(SQLiteStoreError.self) {
            _ = try await store.claimOutbox(
                owner: "projection-worker",
                now: .init(rawValue: 1),
                leaseUntil: .init(rawValue: 10),
                limit: 1
            )
        }
        try executeRaw(
            at: url,
            sql: "UPDATE projection_outbox SET kind = 'acceptedUserMessage', claim_owner = NULL, claim_expires_at = NULL, attempt_count = 4294967295"
        )
        let saturated = try await store.claimOutbox(
            owner: "projection-worker",
            now: .init(rawValue: 11),
            leaseUntil: .init(rawValue: 20),
            limit: 1
        )
        XCTAssertEqual(saturated.items.first?.attemptCount, UInt32.max)

        let intent = DeletionIntent(
            id: "corrupt-deletion",
            scope: .deleteAll,
            conversationID: nil,
            createdAt: .init(rawValue: 1)
        )
        try await store.createDeletionIntent(intent)
        try executeRaw(
            at: url,
            sql: "UPDATE deletion_intents SET scope = 'invalid-scope' WHERE intent_id = ?",
            values: [.text(intent.id)]
        )
        await assertThrows(SQLiteStoreError.self) {
            _ = try await store.pendingDeletionIntents()
        }
    }

    func testRecoveryReportsPendingGatesUncertainOutcomesAndOrphanedExecutingState() async throws {
        let pendingFixture = try submission(offset: 21_400)
        let pendingStore = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await pendingStore.commitSubmission(pendingFixture.commit)
        let loadedPendingProjection = try await pendingStore.loadProjection(
            for: pendingFixture.stream.runID
        )
        let pendingProjection = try XCTUnwrap(loadedPendingProjection)
        let pendingPrepared = try preparedRequest(
            stream: pendingFixture.stream,
            number: 21_410,
            idempotency: .pureRead
        )
        let pendingApproval = try AgentApprovalRequest(
            id: ApprovalID(rawValue: RuntimeTestFixtures.uuid(21_411)),
            prepared: pendingPrepared,
            policyVersion: 1,
            createdAt: .init(rawValue: 10)
        )
        let pendingInteraction = try UserInputRequest(
            id: InteractionRequestID(rawValue: RuntimeTestFixtures.uuid(21_412)),
            runID: pendingFixture.stream.runID,
            prompt: "Await a durable response",
            creationStateVersion: 1
        )
        _ = try await pendingStore.append(try appendSameStateEvents(
            stream: pendingFixture.stream,
            projection: pendingProjection,
            commandNumber: 21_413,
            baseEventNumber: 21_420,
            events: [
                .approvalRequested(pendingApproval),
                .userInputRequested(pendingInteraction),
            ]
        ))
        let loadedPendingFacts = try await pendingStore.loadRecoveryFacts(
            for: pendingFixture.stream.runID
        )
        let pendingFacts = try XCTUnwrap(loadedPendingFacts)
        XCTAssertEqual(pendingFacts.pendingApprovalIDs, [pendingApproval.id])
        XCTAssertEqual(pendingFacts.pendingInteractionIDs, [pendingInteraction.id])

        let uncertainFixture = try submission(offset: 21_500)
        let uncertainStore = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await uncertainStore.commitSubmission(uncertainFixture.commit)
        let loadedUncertainProjection = try await uncertainStore.loadProjection(
            for: uncertainFixture.stream.runID
        )
        let uncertainProjection = try XCTUnwrap(loadedUncertainProjection)
        let uncertainPrepared = try preparedRequest(
            stream: uncertainFixture.stream,
            number: 21_510,
            idempotency: .nonIdempotent
        )
        let uncertainInvocationID = try XCTUnwrap(uncertainPrepared.invocationID)
        let uncertainFailure = try AgentFailure(
            code: "test.uncertain-outcome",
            classification: .potentiallySideEffecting,
            safeMessage: "The external outcome requires reconciliation.",
            retryAdvice: .never,
            externalEffect: .uncertain,
            requiredUserAction: .reconcile,
            redaction: RuntimeTestFixtures.redaction()
        )
        _ = try await uncertainStore.append(try appendSameStateEvents(
            stream: uncertainFixture.stream,
            projection: uncertainProjection,
            commandNumber: 21_511,
            baseEventNumber: 21_520,
            events: [
                .toolIntentRecorded(uncertainPrepared),
                .toolOutcomeRecorded(
                    invocationID: uncertainInvocationID,
                    outcome: .uncertain(uncertainFailure)
                ),
            ]
        ))
        let uncertainDirective = try await uncertainStore.recoveryDirective(
            for: uncertainFixture.stream.runID
        )
        XCTAssertEqual(uncertainDirective?.disposition, .waitingForReconciliation)

        let orphanFixture = try submission(offset: 21_600)
        let orphanStore = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await orphanStore.commitSubmission(orphanFixture.commit)
        let loadedOrphanCreated = try await orphanStore.loadProjection(
            for: orphanFixture.stream.runID
        )
        let orphanCreated = try XCTUnwrap(loadedOrphanCreated)
        _ = try await orphanStore.append(try transitionAppend(
            stream: orphanFixture.stream,
            projection: orphanCreated,
            commandNumber: 21_601,
            baseEventNumber: 21_630,
            states: [
                .preparing, .waitingForModel, .generating, .validatingAction, .executingTools,
            ],
            finalEvent: nil
        ))
        let orphanDirective = try await orphanStore.recoveryDirective(for: orphanFixture.stream.runID)
        XCTAssertEqual(orphanDirective?.disposition, .waitingForReconciliation)
    }

    func testCorruptRunIdentitiesMutationReceiptsAndReservationPayloadsFailClosed() async throws {
        let handleURL = temporaryDatabaseURL()
        let handleFixture = try submission(offset: 21_700)
        let handleStore = SQLiteRunJournal(databaseURL: handleURL)
        _ = try await handleStore.commitSubmission(handleFixture.commit)
        try executeRaw(
            at: handleURL,
            sql: "UPDATE runs SET run_id = 'invalid-run-id' WHERE run_id = ?",
            values: [.text(handleFixture.stream.runID.description)]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await handleStore.loadRunFacts(for: handleFixture.stream.executionHandleID)
        }
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await handleStore.loadRunSnapshot(for: handleFixture.stream.executionHandleID)
        }

        let receiptURL = temporaryDatabaseURL()
        let receiptFixture = try submission(offset: 21_800)
        let receiptStore = SQLiteRunJournal(databaseURL: receiptURL)
        _ = try await receiptStore.commitSubmission(receiptFixture.commit)
        try executeRaw(
            at: receiptURL,
            sql: "UPDATE mutation_receipts SET run_id = ?",
            values: [.text(AgentRunID(rawValue: RuntimeTestFixtures.uuid(21_801)).description)]
        )
        await assertThrows(SQLiteStoreError.self) {
            _ = try await receiptStore.commitSubmission(receiptFixture.commit)
        }

        let reservationURL = temporaryDatabaseURL()
        let reservationFixture = try submission(offset: 21_900, budgetLimit: 10)
        let reservationStore = SQLiteRunJournal(databaseURL: reservationURL)
        _ = try await reservationStore.commitSubmission(reservationFixture.commit)
        let loadedReservationProjection = try await reservationStore.loadProjection(
            for: reservationFixture.stream.runID
        )
        let reservationProjection = try XCTUnwrap(loadedReservationProjection)
        let reservation = try budgetReservation(number: 21_901, inputTokens: 2)
        _ = try await reservationStore.commit(try mutation(
            stream: reservationFixture.stream,
            projection: reservationProjection,
            commandNumber: 21_902,
            eventNumber: 21_903,
            usage: .zero,
            operations: [.reserve(reservation)]
        ))
        try executeRaw(
            at: reservationURL,
            sql: "UPDATE budget_reservations SET payload = NULL WHERE reservation_id = ?",
            values: [.text(reservation.id.description)]
        )
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await reservationStore.loadBudgetLedger(for: reservationFixture.stream.runID)
        }
    }

    func testLegacyBoundaryClaimCorruptionAndGenericFaultInjectionFailClosed() async throws {
        let fixture = try submission(offset: 22_000)
        let store = SQLiteRunJournal(databaseURL: temporaryDatabaseURL())
        _ = try await store.commitSubmission(fixture.commit)
        let prepared = try preparedRequest(
            stream: fixture.stream,
            number: 22_010,
            idempotency: .pureRead
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        let hop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: prepared.plan.destination
        )
        try await store.recordExternalClaim(ExternalClaimReference(
            id: "boundary-hop:\(hop.fingerprint.rawValue)",
            runID: fixture.stream.runID,
            invocationID: prepared.invocationID,
            kind: "wrong-kind",
            payloadDigest: digest("legacy-boundary")
        ))
        await assertThrows(RuntimeRepositoryError.self) {
            _ = try await store.boundaryClaimEvidence(
                approvalID: ApprovalID(rawValue: RuntimeTestFixtures.uuid(22_011)),
                prepared: prepared,
                attempt: attempt
            )
        }

        enum SyntheticFault: Error { case failure }
        let faulting = SQLiteRunJournal(databaseURL: temporaryDatabaseURL()) { point in
            if point == .beforeOpenForWrite { throw SyntheticFault.failure }
        }
        do {
            _ = try await faulting.openForWrite()
            XCTFail("a non-SQLite injected failure must be normalized")
        } catch let error as SQLiteStoreError {
            XCTAssertEqual(error, .injected(.beforeOpenForWrite))
        }
    }

    func testVersionTwoMigrationRebuildsEveryTypedFactAndVersionFiveBoundaryColumns() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 22_100)
        let seed = SQLiteRunJournal(databaseURL: url)
        _ = try await seed.commitSubmission(fixture.commit)
        let loadedProjection = try await seed.loadProjection(for: fixture.stream.runID)
        let projection = try XCTUnwrap(loadedProjection)
        let prepared = try preparedRequest(
            stream: fixture.stream,
            number: 22_110,
            idempotency: .pureRead
        )
        let invocationID = try XCTUnwrap(prepared.invocationID)
        let manifest = try AgentStableBoundaryReference(digest: digest("all-migration-manifest"))
        let approval = try AgentApprovalRequest(
            id: ApprovalID(rawValue: RuntimeTestFixtures.uuid(22_111)),
            prepared: prepared,
            policyVersion: 1,
            createdAt: .init(rawValue: 10)
        )
        let approvalReceipt = try ApprovalReceipt(
            request: approval,
            decision: .approved,
            scope: .exactInvocation,
            decidedAt: .init(rawValue: 11)
        )
        let interaction = try UserInputRequest(
            id: InteractionRequestID(rawValue: RuntimeTestFixtures.uuid(22_112)),
            runID: fixture.stream.runID,
            prompt: "Rebuild every v2 typed fact",
            creationStateVersion: 1
        )
        let response = try AgentStableBoundaryReference(digest: digest("all-migration-response"))
        let outcome = AgentToolInvocationOutcome.failed(try RuntimeTestFixtures.failure())
        _ = try await seed.append(try appendSameStateEvents(
            stream: fixture.stream,
            projection: projection,
            commandNumber: 22_120,
            baseEventNumber: 22_130,
            events: [
                .compiledManifestCommitted(stepID: prepared.stepID, reference: manifest),
                .toolIntentRecorded(prepared),
                .toolOutcomeRecorded(invocationID: invocationID, outcome: outcome),
                .approvalRequested(approval),
                .approvalDecided(approvalReceipt),
                .userInputRequested(interaction),
                .userInputResponseCommitted(requestID: interaction.id, reference: response),
                .validatedActionCommitted(
                    stepID: AgentStepID(rawValue: RuntimeTestFixtures.uuid(22_113)),
                    reference: try AgentStableBoundaryReference(digest: digest("migration-default"))
                ),
            ]
        ))
        try await seed.checkpointWAL()
        await seed.close()

        let v2 = try SQLiteConnection(url: url, create: false)
        try v2.execute("PRAGMA foreign_keys = OFF")
        for statement in [
            "ALTER TABLE mutation_receipts DROP COLUMN ledger_payload",
            "ALTER TABLE compiled_manifests DROP COLUMN payload",
            "ALTER TABLE tool_invocations DROP COLUMN intent_payload",
            "ALTER TABLE tool_invocations DROP COLUMN outcome_payload",
            "ALTER TABLE approvals DROP COLUMN request_payload",
            "ALTER TABLE approvals DROP COLUMN receipt_payload",
            "ALTER TABLE interactions DROP COLUMN request_payload",
            "ALTER TABLE interactions DROP COLUMN response_payload",
            "ALTER TABLE budget_reservations DROP COLUMN payload",
            "ALTER TABLE budget_reservations DROP COLUMN actual_usage",
            "ALTER TABLE external_claims DROP COLUMN approval_id",
            "ALTER TABLE external_claims DROP COLUMN prepared_fingerprint",
            "ALTER TABLE external_claims DROP COLUMN attempt_fingerprint",
            "ALTER TABLE external_claims DROP COLUMN hop_fingerprint",
            "DROP TABLE run_input_snapshots",
            "DROP TABLE run_admissions",
            "DROP TABLE agent_commands",
            "PRAGMA user_version = 2",
        ] {
            try v2.execute(statement)
        }
        v2.close()

        let migrated = SQLiteRunJournal(databaseURL: url)
        let report = try await migrated.openForWrite()
        XCTAssertEqual(report.currentVersion, 5)
        XCTAssertNotNil(report.migrationBackupURL)
        let loadedFacts = try await migrated.loadRunFacts(for: fixture.stream.runID)
        let facts = try XCTUnwrap(loadedFacts)
        XCTAssertEqual(facts.submission?.inputSnapshot, fixture.commit.inputSnapshot)
        let manifests = try await migrated.loadCompiledManifests(for: fixture.stream.runID)
        XCTAssertEqual(manifests.map(\.reference), [manifest])
        let tools = try await migrated.loadToolInvocations(for: fixture.stream.runID)
        XCTAssertEqual(tools.map(\.request), [prepared])
        XCTAssertEqual(tools.map(\.outcome), [outcome])
        let approvals = try await migrated.loadApprovals(for: fixture.stream.runID)
        XCTAssertEqual(approvals.map(\.request), [approval])
        XCTAssertEqual(approvals.map(\.receipt), [approvalReceipt])
        let interactions = try await migrated.loadInteractions(for: fixture.stream.runID)
        XCTAssertEqual(interactions.map(\.request), [interaction])
        XCTAssertEqual(interactions.map(\.response), [response])
        let snapshotCount = try await migrated.rowCount(table: "run_input_snapshots")
        XCTAssertEqual(snapshotCount, 1)
        await migrated.close()

        let schema = try SQLiteConnection(url: url, create: false, readOnly: true)
        let externalClaimColumns = try schema.rows("PRAGMA table_info(external_claims)")
            .compactMap { $0[1].text }
        XCTAssertTrue(externalClaimColumns.contains("approval_id"))
        XCTAssertTrue(externalClaimColumns.contains("prepared_fingerprint"))
        XCTAssertTrue(externalClaimColumns.contains("attempt_fingerprint"))
        XCTAssertTrue(externalClaimColumns.contains("hop_fingerprint"))
        schema.close()
    }

    func testVersionTwoMigrationBacksUpAndRebuildsTypedManifest() async throws {
        let url = temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture = try submission(offset: 2_000)
        let reference = try AgentStableBoundaryReference(digest: digest("migration-manifest"))
        let stepID = AgentStepID(rawValue: RuntimeTestFixtures.uuid(2_001))
        let event = try RuntimeTestFixtures.envelope(
            stream: fixture.stream,
            eventNumber: 2_002,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil,
            event: .compiledManifestCommitted(stepID: stepID, reference: reference)
        )
        let db = try SQLiteConnection(url: url, create: true)
        try db.execute("CREATE TABLE runs(run_id TEXT PRIMARY KEY, conversation_id TEXT, request_id TEXT NOT NULL UNIQUE, execution_handle_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL, state_version INTEGER NOT NULL, next_sequence INTEGER NOT NULL, terminal_event_id TEXT UNIQUE, last_digest TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deletion_blocked INTEGER NOT NULL DEFAULT 0) STRICT")
        try db.execute("CREATE TABLE events(event_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, sequence INTEGER NOT NULL, state_version INTEGER NOT NULL, timestamp INTEGER NOT NULL, record_digest TEXT NOT NULL UNIQUE, previous_digest TEXT, payload_version INTEGER NOT NULL, payload BLOB NOT NULL, is_terminal INTEGER NOT NULL, UNIQUE(run_id, sequence)) STRICT")
        try db.execute("CREATE TABLE compiled_manifests(manifest_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE, step_id TEXT NOT NULL, digest TEXT NOT NULL, artifact_id TEXT, payload_version INTEGER NOT NULL) STRICT")
        try db.execute(
            "INSERT INTO runs VALUES(?, NULL, ?, ?, 'created', 1, 2, NULL, ?, 1, 1, 0)",
            [.text(fixture.stream.runID.description), .text(fixture.stream.requestID.description), .text(fixture.stream.executionHandleID.description), .text(event.payload.recordDigest.rawValue)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try db.execute(
            "INSERT INTO events VALUES(?, ?, 1, 1, 1, ?, NULL, 1, ?, 0)",
            [.text(event.payload.eventID.description), .text(fixture.stream.runID.description), .text(event.payload.recordDigest.rawValue), .blob(try encoder.encode(event))]
        )
        try db.execute(
            "INSERT INTO compiled_manifests VALUES(?, ?, ?, ?, NULL, 1)",
            [.text(event.payload.eventID.description), .text(fixture.stream.runID.description), .text(stepID.description), .text(reference.digest.rawValue)]
        )
        try db.execute("PRAGMA user_version = 2")
        db.close()

        let store = SQLiteRunJournal(databaseURL: url)
        let report = try await store.openForWrite()
        XCTAssertEqual(report.currentVersion, 5)
        let backup = try XCTUnwrap(report.migrationBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let manifests = try await store.loadCompiledManifests(for: fixture.stream.runID)
        XCTAssertEqual(manifests.map(\.reference), [reference])
        let backupDB = try SQLiteConnection(url: backup, create: false, readOnly: true)
        XCTAssertEqual(try backupDB.scalarInt("PRAGMA user_version"), 2)
        XCTAssertFalse(try backupDB.rows("PRAGMA table_info(compiled_manifests)").contains { $0[1].text == "payload" })
    }
}

private extension RuntimeRepositorySQLiteTests {
    struct SubmissionFixture {
        let stream: RuntimeTestFixtures.Stream
        let commit: RuntimeSubmissionCommit
    }

    func submission(offset: Int, budgetLimit: UInt64 = 100) throws -> SubmissionFixture {
        let stream = RuntimeTestFixtures.Stream(offset: offset)
        let conversationID = ConversationID(rawValue: RuntimeTestFixtures.uuid(offset + 10))
        let messageID = MessageID(rawValue: RuntimeTestFixtures.uuid(offset + 11))
        let message = JournalMessageReference(
            messageID: messageID,
            conversationID: conversationID,
            runID: stream.runID,
            role: .user,
            bodyDigest: digest("message-\(offset)"),
            bodyArtifactID: ArtifactID(rawValue: RuntimeTestFixtures.uuid(offset + 12)),
            createdAt: .init(rawValue: 1)
        )
        let budget = try makeBudget(limit: budgetLimit)
        let selection = AgentModelSelection(
            providerID: try AgentModelProviderID("local.test"),
            modelID: try AgentModelID("bonsai"),
            variantID: try AgentModelVariantID("8b-1bit"),
            capabilityVersion: SemanticVersion("1.0.0")!
        )
        let request = try AgentRequest(
            id: stream.requestID,
            runID: stream.runID,
            conversationID: conversationID,
            userTurnID: UserTurnID(rawValue: RuntimeTestFixtures.uuid(offset + 13)),
            role: "primary",
            instruction: "Test the durable runtime repository.",
            outputRequirement: .text,
            modelPolicy: AgentModelPolicy(
                localOnly: true,
                allowedSelections: [selection],
                strategy: .pinned,
                requiredCapabilities: AgentModelCapabilitySet([])
            ),
            capabilityCeiling: RunCapabilityCeiling(capabilities: AgentCapabilitySet([])),
            budget: budget,
            provenance: AgentRequestProvenance(source: .user, sourceMessageID: messageID)
        )
        let requestEnvelope = try AgentRequestEnvelope(payload: request)
        let input = try AgentStableBoundaryReference(digest: digest("input-\(offset)"))
        let event = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: offset + 14,
            sequence: 1,
            stateVersion: 1,
            state: .created,
            timestamp: 1,
            previousDigest: nil,
            event: .runInputSnapshotCommitted(input)
        )
        let commandID = RuntimeTestFixtures.commandID(offset + 15)
        let append = try RunJournalAppendRequest(
            mutationIdentity: .command(commandID),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            events: [event]
        )
        let outbox = ProjectionOutboxItem(
            idempotencyKey: "accepted:\(messageID)",
            conversationID: conversationID,
            runID: stream.runID,
            messageID: messageID,
            kind: .acceptedUserMessage,
            payloadDigest: message.bodyDigest,
            payloadArtifactID: message.bodyArtifactID
        )
        return SubmissionFixture(
            stream: stream,
            commit: RuntimeSubmissionCommit(
                commandID: commandID,
                request: requestEnvelope,
                executionHandleID: stream.executionHandleID,
                userMessage: message,
                inputSnapshot: input,
                initialAppend: append,
                initialLedger: try BudgetLedgerSnapshot(budget: budget),
                outbox: outbox
            )
        )
    }

    func command(
        stream: RuntimeTestFixtures.Stream,
        number: Int,
        action: AgentCommandAction
    ) throws -> AgentCommandEnvelope {
        try AgentCommandEnvelope(payload: AgentCommand(
            commandID: RuntimeTestFixtures.commandID(10_000 + number),
            runID: stream.runID,
            expectedRunStateVersion: 1,
            action: action,
            issuedAt: .init(rawValue: Int64(number))
        ))
    }

    func commandReceipt(
        for command: AgentCommandEnvelope,
        state: AgentRunState,
        version: UInt64
    ) throws -> AgentCommandReceiptEnvelope {
        try AgentCommandReceiptEnvelope(payload: AgentCommandReceipt(
            commandID: command.payload.commandID,
            runID: command.payload.runID,
            disposition: .accepted,
            currentStatus: AgentRunStatus(state: state, stateVersion: version)
        ))
    }

    func makeBudget(limit: UInt64) throws -> AgentBudget {
        try AgentBudget(
            limits: BudgetQuantities(Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
                ($0, limit)
            })),
            maximumThermalState: .fair,
            memoryPressureResponse: .pause
        )
    }

    func budgetReservation(number: Int, inputTokens: UInt64) throws -> BudgetReservation {
        try BudgetReservation(
            id: BudgetReservationID(rawValue: RuntimeTestFixtures.uuid(number)),
            maximumUsage: RuntimeTestFixtures.usage(inputTokens),
            reason: "model.attempt"
        )
    }

    func messageReference(
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
            bodyDigest: digest("message-body-\(number)"),
            bodyArtifactID: ArtifactID(rawValue: RuntimeTestFixtures.uuid(number + 1)),
            createdAt: .init(rawValue: Int64(number))
        )
    }

    func outboxItem(
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

    func terminalMutation(
        stream: RuntimeTestFixtures.Stream,
        first: AgentEventEnvelope,
        commandNumber: Int,
        baseEventNumber: Int
    ) throws -> RuntimeJournalMutation {
        let preparing = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: baseEventNumber,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 2,
            previousDigest: first.payload.recordDigest
        )
        let waiting = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: baseEventNumber + 1,
            sequence: 3,
            stateVersion: 3,
            state: .waitingForModel,
            timestamp: 3,
            previousDigest: preparing.payload.recordDigest
        )
        let generating = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: baseEventNumber + 2,
            sequence: 4,
            stateVersion: 4,
            state: .generating,
            timestamp: 4,
            previousDigest: waiting.payload.recordDigest
        )
        let validating = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: baseEventNumber + 3,
            sequence: 5,
            stateVersion: 5,
            state: .validatingAction,
            timestamp: 5,
            previousDigest: generating.payload.recordDigest
        )
        let completed = try RuntimeTestFixtures.completedEnvelope(
            stream: stream,
            eventNumber: baseEventNumber + 4,
            sequence: 6,
            stateVersion: 6,
            timestamp: 6,
            usage: .zero,
            previousDigest: validating.payload.recordDigest
        )
        return RuntimeJournalMutation(
            append: try RunJournalAppendRequest(
                mutationIdentity: .command(RuntimeTestFixtures.commandID(commandNumber)),
                runID: stream.runID,
                expectedRunStateVersion: 1,
                events: [preparing, waiting, generating, validating, completed]
            )
        )
    }

    func executeRaw(
        at url: URL,
        sql: String,
        values: [SQLiteValue] = [],
        ignoringCheckConstraints: Bool = false
    ) throws {
        let db = try SQLiteConnection(url: url, create: false)
        defer { db.close() }
        if ignoringCheckConstraints {
            try db.execute("PRAGMA ignore_check_constraints = ON")
        }
        try db.execute(sql, values)
    }

    func wireData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    func mutation(
        stream: RuntimeTestFixtures.Stream,
        projection: AgentRunProjection,
        commandNumber: Int,
        eventNumber: Int,
        usage: AgentUsage,
        operations: [BudgetLedgerOperation]
    ) throws -> RuntimeJournalMutation {
        let event = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: eventNumber,
            sequence: projection.eventCount + 1,
            stateVersion: projection.stateVersion,
            state: projection.state,
            timestamp: projection.cursor.timestamp.rawValue + 1,
            usage: usage,
            previousDigest: projection.cursor.recordDigest,
            event: .usageUpdated(usage)
        )
        return RuntimeJournalMutation(
            append: try RunJournalAppendRequest(
                mutationIdentity: .command(RuntimeTestFixtures.commandID(commandNumber)),
                runID: stream.runID,
                expectedRunStateVersion: projection.stateVersion,
                events: [event]
            ),
            budgetOperations: operations
        )
    }

    func appendSameStateEvents(
        stream: RuntimeTestFixtures.Stream,
        projection: AgentRunProjection,
        commandNumber: Int,
        baseEventNumber: Int,
        events: [AgentEvent]
    ) throws -> RunJournalAppendRequest {
        var envelopes: [AgentEventEnvelope] = []
        for (index, event) in events.enumerated() {
            let predecessor = envelopes.last?.payload.recordDigest ?? projection.cursor.recordDigest
            envelopes.append(try RuntimeTestFixtures.envelope(
                stream: stream,
                eventNumber: baseEventNumber + index,
                sequence: projection.eventCount + UInt64(index) + 1,
                stateVersion: projection.stateVersion,
                state: projection.state,
                timestamp: projection.cursor.timestamp.rawValue + Int64(index) + 1,
                previousDigest: predecessor,
                event: event
            ))
        }
        return try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(commandNumber)),
            runID: stream.runID,
            expectedRunStateVersion: projection.stateVersion,
            events: envelopes
        )
    }

    func transitionAppend(
        stream: RuntimeTestFixtures.Stream,
        projection: AgentRunProjection,
        commandNumber: Int,
        baseEventNumber: Int,
        states: [AgentRunState],
        finalEvent: AgentEvent?
    ) throws -> RunJournalAppendRequest {
        var envelopes: [AgentEventEnvelope] = []
        for (index, state) in states.enumerated() {
            let predecessor = envelopes.last?.payload.recordDigest ?? projection.cursor.recordDigest
            let diagnostic = AgentEvent.diagnostic(try RuntimeTestFixtures.failure())
            let payload = index == states.count - 1 ? (finalEvent ?? diagnostic) : diagnostic
            envelopes.append(try RuntimeTestFixtures.envelope(
                stream: stream,
                eventNumber: baseEventNumber + index,
                sequence: projection.eventCount + UInt64(index) + 1,
                stateVersion: projection.stateVersion + UInt64(index) + 1,
                state: state,
                timestamp: projection.cursor.timestamp.rawValue + Int64(index) + 1,
                previousDigest: predecessor,
                event: payload
            ))
        }
        return try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(commandNumber)),
            runID: stream.runID,
            expectedRunStateVersion: projection.stateVersion,
            events: envelopes
        )
    }

    func preparedRequest(
        stream: RuntimeTestFixtures.Stream,
        number: Int,
        idempotency: ExternalIdempotency,
        allowedRedirects: [ExternalDestination] = [],
        allowedFallbacks: [ExternalDestination] = []
    ) throws -> PreparedExternalOperationRequest {
        let destination = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://example.invalid/runtime-\(number)"
        )
        let category = try AgentDataCategory(rawValue: "user.query")
        let capability: AgentCapability = idempotency == .pureRead ? .networkRead : .externalWrite
        let effect: AgentEffect = idempotency == .pureRead ? .networkRead : .externalWrite
        let authority = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([capability]),
            destinations: [destination] + allowedRedirects + allowedFallbacks,
            dataCategories: [category]
        )
        let canonical = try CanonicalJSON(.object(["query": .string("repository")]))
        let sanitized = try SanitizedCanonicalJSON(
            value: canonical,
            redaction: RuntimeTestFixtures.redaction(),
            policyRevision: 1,
            attestationDigest: digest("attestation-\(number)")
        )
        let key: ExternalIdempotencyKey? = idempotency == .idempotencyKeyRequired
            ? .derive(components: [Data("key-\(number)".utf8)]) : nil
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: "test.repository.operation.\(number)",
            destination: destination,
            allowedRedirects: allowedRedirects,
            allowedFallbacks: allowedFallbacks,
            dataCategories: [category],
            payloadDigest: canonical.fingerprint,
            effects: [effect],
            requiredCapabilities: AgentCapabilitySet([capability]),
            maximumRequestBytes: 4_096,
            maximumResponseBytes: 8_192,
            timeoutMilliseconds: 5_000,
            retryPolicy: .never,
            idempotency: idempotency,
            idempotencyKey: key,
            userPreview: "Perform a bounded test operation",
            descriptorID: "test.repository.operation@1"
        )
        let ceiling = RunCapabilityCeiling(authority: authority)
        return try PreparedExternalOperationRequest(
            requestID: stream.requestID,
            runID: stream.runID,
            conversationID: ConversationID(rawValue: RuntimeTestFixtures.uuid(number + 1)),
            stepID: AgentStepID(rawValue: RuntimeTestFixtures.uuid(number + 2)),
            invocationID: ToolInvocationID(rawValue: RuntimeTestFixtures.uuid(number + 3)),
            plan: plan,
            payload: sanitized,
            capabilityGrant: StepCapabilityGrant(runCeiling: ceiling, authority: authority)
        )
    }

    func digest(_ label: String) -> StableDigest {
        StableDigest.sha256(Data(label.utf8))
    }

    func temporaryDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuntimeRepositorySQLiteTests-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal.sqlite3")
    }

    func assertThrows<E: Error>(
        _ expected: E.Type,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertTrue(error is E, "Unexpected error: \(error)", file: file, line: line)
        }
    }
}
