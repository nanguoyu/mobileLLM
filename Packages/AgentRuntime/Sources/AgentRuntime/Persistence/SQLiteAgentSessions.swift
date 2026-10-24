// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public enum AgentSessionError: Error, Equatable, Sendable {
    case unavailable
    case staleRevision
    case invalidHistory
    case inputConflict
    case inputTooLarge
    case capacityReached
    case pendingInput
    case requiresResume
}

/// Session facts share the run journal's database and conversation deletion boundary.
public protocol AgentSessionJournaling: Sendable {
    func session(_ id: AgentSessionID) async throws -> AgentSessionSnapshot?
    func session(for runID: AgentRunID) async throws -> AgentSessionSnapshot?
    func appendSession(_ value: AgentSessionSnapshot, expectedRevision: UInt64) async throws
}

extension SQLiteRunJournal: AgentSessionJournaling {
    public func session(_ id: AgentSessionID) async throws -> AgentSessionSnapshot? {
        guard let db = try existingConnection() else { return nil }
        return try session(id, db: db)
    }

    public func session(for runID: AgentRunID) async throws -> AgentSessionSnapshot? {
        guard let db = try existingConnection(),
              let id = try db.scalarText("SELECT session_id FROM agent_session_runs WHERE run_id = ?",
                                        [.text(runID.description)]).flatMap(AgentSessionID.init)
        else { return nil }
        return try session(id, db: db)
    }

    public func appendSession(_ value: AgentSessionSnapshot, expectedRevision: UInt64) async throws {
        let db = try writableConnection()
        try db.execute("BEGIN IMMEDIATE")
        do {
            try appendSession(value, expectedRevision: expectedRevision, db: db)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    func session(_ id: AgentSessionID, db: SQLiteConnection) throws -> AgentSessionSnapshot? {
        guard let row = try db.rows(
            "SELECT payload, digest FROM agent_session_events WHERE session_id = ? ORDER BY revision DESC LIMIT 1",
            [.text(id.description)]
        ).first else { return nil }
        guard let data = row[0].blob, row[1].text == StableDigest.sha256(data).rawValue else {
            throw AgentSessionError.invalidHistory
        }
        let value = try JSONDecoder().decode(AgentSessionSnapshot.self, from: data)
        try value.validate()
        guard value.id == id else { throw AgentSessionError.invalidHistory }
        return value
    }

    func session(for runID: AgentRunID, db: SQLiteConnection) throws -> AgentSessionSnapshot? {
        guard let id = try db.scalarText("SELECT session_id FROM agent_session_runs WHERE run_id = ?",
                                        [.text(runID.description)]).flatMap(AgentSessionID.init)
        else { return nil }
        return try session(id, db: db)
    }

    func appendSession(_ value: AgentSessionSnapshot, expectedRevision: UInt64, db: SQLiteConnection) throws {
        try value.validate()
        let previous = try session(value.id, db: db)
        if previous == value { return }
        guard expectedRevision < UInt64(Int64.max), value.revision == expectedRevision + 1,
              previous?.revision ?? 0 == expectedRevision else { throw AgentSessionError.staleRevision }
        if let previous {
            guard value.conversationID == previous.conversationID, value.seedRunID == previous.seedRunID,
                  value.inputs.starts(with: previous.inputs),
                  value.activations.starts(with: previous.activations),
                  value.inclusions.starts(with: previous.inclusions)
            else { throw AgentSessionError.invalidHistory }
        } else {
            guard value.activations.count == 1, value.inputs.isEmpty, value.inclusions.isEmpty,
                  try db.scalarText("SELECT conversation_id FROM runs WHERE run_id = ? AND deletion_blocked = 0",
                                    [.text(value.seedRunID.description)]) == value.conversationID.description
            else { throw AgentSessionError.invalidHistory }
            try db.execute("INSERT INTO agent_sessions(session_id, seed_run_id, conversation_id) VALUES(?, ?, ?)",
                           [.text(value.id.description), .text(value.seedRunID.description), .text(value.conversationID.description)])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try db.execute("INSERT INTO agent_session_events(session_id, revision, payload, digest) VALUES(?, ?, ?, ?)",
                       [.text(value.id.description), .integer(Int64(value.revision)), .blob(data), .text(StableDigest.sha256(data).rawValue)])
        for activation in value.activations.dropFirst(previous?.activations.count ?? 0) {
            try db.execute("INSERT INTO agent_session_runs(run_id, session_id) VALUES(?, ?)",
                           [.text(activation.runID.description), .text(value.id.description)])
        }
    }
}
