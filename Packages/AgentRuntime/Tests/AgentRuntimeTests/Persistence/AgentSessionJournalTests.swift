// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

final class AgentSessionJournalTests: XCTestCase {
    private func seeded(_ offset: Int) async throws -> (ExecutorTestHarness, AgentSessionSnapshot) {
        let model = try ExecutorTestModelDefinition(offset: offset)
        let provider = try FixedCompletionModelProvider(model: model, answer: "Original result")
        let harness = try ExecutorTestHarness(offset: offset, provider: provider, model: model)
        let command = ExecutorTestID.command(offset)
        let handle = try await harness.executor.submit(harness.request, commandID: command)
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: handle))
        let snapshot = AgentSessionSnapshot(
            id: AgentSessionID(rawValue: harness.request.runID.rawValue),
            conversationID: harness.request.conversationID,
            seed: AgentSessionActivation(runID: harness.request.runID, commandID: command, inputIDs: [])
        )
        try await harness.repository.appendSession(snapshot, expectedRevision: 0)
        return (harness, snapshot)
    }

    private func input(_ harness: ExecutorTestHarness, id: Int) async throws -> AgentSessionInput {
        let body = try await harness.payloadStore.commit(
            data: Data("Preserve the original constraint".utf8), mimeType: "text/plain",
            semanticType: "agent-session-input.v1", runID: harness.request.runID,
            stepID: nil, invocationID: nil, owner: .conversation(harness.request.conversationID),
            sensitivity: .personalData
        )
        return AgentSessionInput(id: MessageID(rawValue: ExecutorTestID.uuid(id)), mode: .nextTurn,
                                 body: body, acceptedAt: AgentTimestamp(rawValue: 50_001), targetRunID: nil)
    }

    func testAcceptedInputSurvivesReopenAndExactAppendReplay() async throws {
        let (harness, initial) = try await seeded(810)
        var next = initial
        next.revision += 1
        next.inputs.append(try await input(harness, id: 81_001))
        try await harness.repository.appendSession(next, expectedRevision: initial.revision)
        try await harness.repository.appendSession(next, expectedRevision: initial.revision)
        await harness.repository.close()
        let reopened = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let byID = try await reopened.session(initial.id)
        let byRun = try await reopened.session(for: harness.request.runID)
        XCTAssertEqual(byID, next)
        XCTAssertEqual(byRun, next)
        XCTAssertEqual(byRun?.pendingTurns.map(\.id), next.inputs.map(\.id))
    }

    func testStaleWriterCannotLoseAnAcceptedMessage() async throws {
        let (harness, initial) = try await seeded(811)
        var first = initial
        first.revision += 1
        first.inputs.append(try await input(harness, id: 81_002))
        var stale = initial
        stale.revision += 1
        stale.inputs.append(try await input(harness, id: 81_003))
        try await harness.repository.appendSession(first, expectedRevision: initial.revision)
        do {
            try await harness.repository.appendSession(stale, expectedRevision: initial.revision)
            XCTFail("A stale writer replaced accepted input")
        } catch { XCTAssertEqual(error as? AgentSessionError, .staleRevision) }
        let saved = try await harness.repository.session(initial.id)
        XCTAssertEqual(saved, first)
    }

    func testVersionFiveMigrationPreservesRunHistory() async throws {
        let (harness, initial) = try await seeded(813)
        let before = try await harness.repository.loadRunSnapshot(for: initial.seedRunID)
        await harness.repository.close()
        let old = try SQLiteConnection(url: harness.databaseURL, create: false, readOnly: false)
        try old.execute("DROP TABLE agent_session_runs")
        try old.execute("DROP TABLE agent_session_events")
        try old.execute("DROP TABLE agent_sessions")
        try old.execute("PRAGMA user_version = 5")
        old.close()
        let migrated = SQLiteRunJournal(databaseURL: harness.databaseURL)
        let report = try await migrated.openForWrite()
        XCTAssertEqual(report.currentVersion, 6)
        XCTAssertNotNil(report.migrationBackupURL)
        let after = try await migrated.loadRunSnapshot(for: initial.seedRunID)
        XCTAssertEqual(before?.events, after?.events)
        try await migrated.appendSession(initial, expectedRevision: 0)
        let restored = try await migrated.session(initial.id)
        XCTAssertEqual(restored, initial)
    }

    func testHistoryCannotBeRewrittenOrBoundToAnotherConversation() async throws {
        let (harness, initial) = try await seeded(812)
        var accepted = initial
        accepted.revision += 1
        accepted.inputs.append(try await input(harness, id: 81_004))
        try await harness.repository.appendSession(accepted, expectedRevision: initial.revision)
        var rewritten = initial
        rewritten.revision = accepted.revision + 1
        do {
            try await harness.repository.appendSession(rewritten, expectedRevision: accepted.revision)
            XCTFail("Accepted history was erased")
        } catch { XCTAssertEqual(error as? AgentSessionError, .invalidHistory) }
        let wrongConversation = AgentSessionSnapshot(
            id: AgentSessionID(rawValue: ExecutorTestID.uuid(81_005)),
            conversationID: ExecutorTestID.conversation(999), seed: initial.activations[0]
        )
        do {
            try await harness.repository.appendSession(wrongConversation, expectedRevision: 0)
            XCTFail("Cross-conversation session was admitted")
        } catch { XCTAssertEqual(error as? AgentSessionError, .invalidHistory) }
        let saved = try await harness.repository.session(initial.id)
        XCTAssertEqual(saved, accepted)
    }
}
