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

        await store.close()
        let reopened = SQLiteRunJournal(databaseURL: url)
        let replay = try await reopened.commitSubmission(fixture.commit)
        XCTAssertEqual(replay.appendReceipt.disposition, .replayed)
        XCTAssertEqual(replay.executionHandleID, fixture.stream.executionHandleID)
        let messageCount = try await reopened.rowCount(table: "messages")
        let outboxCount = try await reopened.rowCount(table: "projection_outbox")
        XCTAssertEqual(messageCount, 1)
        XCTAssertEqual(outboxCount, 1)

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
        XCTAssertEqual(report.currentVersion, 3)
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
        idempotency: ExternalIdempotency
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
            destinations: [destination],
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
