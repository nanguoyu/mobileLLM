// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime

final class RuntimeRepositorySnapshotConcurrencyTests: XCTestCase {
    func testRunSnapshotAlwaysMatchesReplayDuringConcurrentCommitsAndAfterReopen() async throws {
        let url = temporaryDatabaseURL()
        let fixture = try submission(offset: 40_000)
        let writer = SQLiteRunJournal(databaseURL: url)
        let initialReceipt = try await writer.commitSubmission(fixture.commit)

        // Separate actors own separate SQLite connections, so reads can overlap a writer
        // transaction instead of merely being serialized by one journal actor.
        let firstReader = SQLiteRunJournal(databaseURL: url)
        let secondReader = SQLiteRunJournal(databaseURL: url)
        _ = try await firstReader.openForWrite()
        _ = try await secondReader.openForWrite()

        let additionalEventCount: UInt64 = 64
        let finalEventCount = initialReceipt.appendReceipt.projection.eventCount + additionalEventCount
        let startGate = SnapshotReaderStartGate(requiredReaders: 2)
        async let firstObservations = Self.pollSnapshots(
            store: firstReader,
            fixture: fixture,
            finalEventCount: finalEventCount,
            startGate: startGate
        )
        async let secondObservations = Self.pollSnapshots(
            store: secondReader,
            fixture: fixture,
            finalEventCount: finalEventCount,
            startGate: startGate
        )

        // Both readers first observe the pre-write snapshot. This prevents a fast writer from
        // making the concurrency test accidentally degenerate into a post-write-only read.
        await startGate.waitUntilAllReadersStarted()
        var projection = initialReceipt.appendReceipt.projection
        for index in 0 ..< Int(additionalEventCount) {
            let append = try sameStateAppend(
                stream: fixture.stream,
                projection: projection,
                commandNumber: 50_000 + index,
                eventNumber: 60_000 + index
            )
            let receipt = try await writer.append(append)
            XCTAssertEqual(receipt.disposition, .appended)
            projection = receipt.projection
            await Task.yield()
        }

        let observationSets = try await [firstObservations, secondObservations]
        for observations in observationSets {
            XCTAssertEqual(observations.first, 1)
            XCTAssertEqual(observations.last, finalEventCount)
            XCTAssertGreaterThan(Set(observations).count, 1)
        }

        await firstReader.close()
        await secondReader.close()
        await writer.close()

        let reopened = SQLiteRunJournal(databaseURL: url)
        let loadedByRunID = try await reopened.loadRunSnapshot(for: fixture.stream.runID)
        let byRunID = try XCTUnwrap(loadedByRunID)
        try Self.validate(snapshot: byRunID, fixture: fixture)
        XCTAssertEqual(byRunID.facts.projection, projection)
        XCTAssertEqual(byRunID.events.count, Int(finalEventCount))

        let loadedByHandle = try await reopened.loadRunSnapshot(
            for: fixture.stream.executionHandleID
        )
        let byHandle = try XCTUnwrap(loadedByHandle)
        try Self.validate(snapshot: byHandle, fixture: fixture)
        XCTAssertEqual(
            byHandle.events.map(\.payload.eventID),
            byRunID.events.map(\.payload.eventID)
        )
        XCTAssertEqual(byHandle.facts.projection, byRunID.facts.projection)
        await reopened.close()
    }

    func testRunAdmissionSequenceIsUniqueStableAndNeverReusedAfterDeletion() async throws {
        let url = temporaryDatabaseURL()
        let first = try submission(offset: 41_000)
        let second = try submission(offset: 42_000)
        let third = try submission(offset: 43_000)
        let store = SQLiteRunJournal(databaseURL: url)

        _ = try await store.commitSubmission(first.commit)
        _ = try await store.commitSubmission(second.commit)
        let loadedFirstFacts = try await store.loadRunFacts(for: first.stream.runID)
        let loadedSecondFacts = try await store.loadRunFacts(for: second.stream.runID)
        let firstFacts = try XCTUnwrap(loadedFirstFacts)
        let secondFacts = try XCTUnwrap(loadedSecondFacts)
        let firstSequence = try XCTUnwrap(firstFacts.submission?.admissionSequence)
        let secondSequence = try XCTUnwrap(secondFacts.submission?.admissionSequence)
        XCTAssertGreaterThan(firstSequence, 0)
        XCTAssertGreaterThan(secondSequence, firstSequence)
        XCTAssertEqual(Set([firstSequence, secondSequence]).count, 2)

        // Exact submission replay must resolve the existing admission rather than consume one.
        let replay = try await store.commitSubmission(first.commit)
        XCTAssertEqual(replay.appendReceipt.disposition, .replayed)
        let loadedReplayedFacts = try await store.loadRunFacts(for: first.stream.runID)
        let replayedFacts = try XCTUnwrap(loadedReplayedFacts)
        XCTAssertEqual(replayedFacts.submission?.admissionSequence, firstSequence)
        let admissionCountBeforeReopen = try await store.rowCount(table: "run_admissions")
        XCTAssertEqual(admissionCountBeforeReopen, 2)
        await store.close()

        let reopened = SQLiteRunJournal(databaseURL: url)
        let loadedReopenedFirst = try await reopened.loadRunFacts(
            for: first.stream.executionHandleID
        )
        let loadedReopenedSecond = try await reopened.loadRunFacts(
            for: second.stream.executionHandleID
        )
        let reopenedFirst = try XCTUnwrap(loadedReopenedFirst)
        let reopenedSecond = try XCTUnwrap(loadedReopenedSecond)
        XCTAssertEqual(reopenedFirst.submission?.admissionSequence, firstSequence)
        XCTAssertEqual(reopenedSecond.submission?.admissionSequence, secondSequence)

        let secondConversationID = second.commit.request.payload.conversationID
        let deletionIntent = DeletionIntent(
            id: "delete-run-with-maximum-admission",
            scope: .conversation,
            conversationID: secondConversationID,
            createdAt: .init(rawValue: 100)
        )
        try await reopened.createDeletionIntent(deletionIntent)
        try await reopened.cascadeConversation(secondConversationID, intentID: deletionIntent.id)
        try await reopened.completeDeletionIntent(id: deletionIntent.id, at: .init(rawValue: 101))
        let deletedFacts = try await reopened.loadRunFacts(for: second.stream.runID)
        XCTAssertNil(deletedFacts)

        _ = try await reopened.commitSubmission(third.commit)
        let loadedThirdFacts = try await reopened.loadRunFacts(for: third.stream.runID)
        let thirdFacts = try XCTUnwrap(loadedThirdFacts)
        let thirdSequence = try XCTUnwrap(thirdFacts.submission?.admissionSequence)
        XCTAssertGreaterThan(thirdSequence, secondSequence)
        let admissionCountAfterReplacement = try await reopened.rowCount(table: "run_admissions")
        XCTAssertEqual(admissionCountAfterReplacement, 2)
        await reopened.close()

        let reopenedAgain = SQLiteRunJournal(databaseURL: url)
        let loadedStableFirst = try await reopenedAgain.loadRunFacts(
            for: first.stream.executionHandleID
        )
        let loadedStableThird = try await reopenedAgain.loadRunFacts(
            for: third.stream.executionHandleID
        )
        let stableFirst = try XCTUnwrap(loadedStableFirst)
        let stableThird = try XCTUnwrap(loadedStableThird)
        XCTAssertEqual(stableFirst.submission?.admissionSequence, firstSequence)
        XCTAssertEqual(stableThird.submission?.admissionSequence, thirdSequence)
        XCTAssertGreaterThan(thirdSequence, secondSequence)
        await reopenedAgain.close()
    }
}

private extension RuntimeRepositorySnapshotConcurrencyTests {
    struct SubmissionFixture: Sendable {
        let stream: RuntimeTestFixtures.Stream
        let commit: RuntimeSubmissionCommit
    }

    struct SnapshotInvariantViolation: Error, CustomStringConvertible, Sendable {
        let description: String
    }

    static func pollSnapshots(
        store: SQLiteRunJournal,
        fixture: SubmissionFixture,
        finalEventCount: UInt64,
        startGate: SnapshotReaderStartGate
    ) async throws -> [UInt64] {
        var observations: [UInt64] = []
        while true {
            guard let snapshot = try await store.loadRunSnapshot(for: fixture.stream.runID) else {
                throw SnapshotInvariantViolation(description: "run snapshot disappeared while polling")
            }
            try validate(snapshot: snapshot, fixture: fixture)
            let eventCount = snapshot.facts.projection.eventCount
            observations.append(eventCount)
            if observations.count == 1 {
                await startGate.readerStarted()
            }
            if eventCount == finalEventCount {
                return observations
            }
            guard eventCount < finalEventCount else {
                throw SnapshotInvariantViolation(
                    description: "snapshot advanced beyond expected terminal count \(finalEventCount)"
                )
            }
            await Task.yield()
        }
    }

    static func validate(
        snapshot: RuntimeRunSnapshot,
        fixture: SubmissionFixture
    ) throws {
        guard let replayed = try AgentRunProjection.replay(snapshot.events) else {
            throw SnapshotInvariantViolation(description: "non-empty run returned an empty event stream")
        }
        guard replayed == snapshot.facts.projection else {
            throw SnapshotInvariantViolation(
                description: "materialized projection at sequence \(snapshot.facts.projection.eventCount) "
                    + "differs from replayed sequence \(replayed.eventCount)"
            )
        }
        guard snapshot.events.count == Int(snapshot.facts.projection.eventCount) else {
            throw SnapshotInvariantViolation(
                description: "event count and projection sequence differ"
            )
        }
        guard snapshot.events.last?.payload.cursor == snapshot.facts.projection.cursor else {
            throw SnapshotInvariantViolation(description: "last event cursor differs from projection cursor")
        }
        guard snapshot.facts.projection.runID == fixture.stream.runID,
              snapshot.facts.projection.executionHandleID == fixture.stream.executionHandleID,
              snapshot.facts.conversationID == fixture.commit.request.payload.conversationID,
              snapshot.facts.submission?.request == fixture.commit.request,
              snapshot.facts.submission?.inputSnapshot == fixture.commit.inputSnapshot,
              snapshot.facts.budgetLedger == fixture.commit.initialLedger
        else {
            throw SnapshotInvariantViolation(description: "snapshot facts differ from immutable submission")
        }
    }

    func submission(offset: Int) throws -> SubmissionFixture {
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
        let budget = try makeBudget(limit: 100)
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
            instruction: "Test atomic runtime repository snapshots.",
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

    func sameStateAppend(
        stream: RuntimeTestFixtures.Stream,
        projection: AgentRunProjection,
        commandNumber: Int,
        eventNumber: Int
    ) throws -> RunJournalAppendRequest {
        let event = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: eventNumber,
            sequence: projection.eventCount + 1,
            stateVersion: projection.stateVersion,
            state: projection.state,
            timestamp: projection.cursor.timestamp.rawValue + 1,
            previousDigest: projection.cursor.recordDigest,
            event: .diagnostic(try RuntimeTestFixtures.failure())
        )
        return try RunJournalAppendRequest(
            mutationIdentity: .command(RuntimeTestFixtures.commandID(commandNumber)),
            runID: stream.runID,
            expectedRunStateVersion: projection.stateVersion,
            events: [event]
        )
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

    func digest(_ label: String) -> StableDigest {
        StableDigest.sha256(Data(label.utf8))
    }

    func temporaryDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuntimeRepositorySnapshotConcurrencyTests-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal.sqlite3")
    }
}

private actor SnapshotReaderStartGate {
    private let requiredReaders: Int
    private var startedReaders = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(requiredReaders: Int) {
        self.requiredReaders = requiredReaders
    }

    func readerStarted() {
        startedReaders += 1
        guard startedReaders >= requiredReaders else { return }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitUntilAllReadersStarted() async {
        if startedReaders >= requiredReaders { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
