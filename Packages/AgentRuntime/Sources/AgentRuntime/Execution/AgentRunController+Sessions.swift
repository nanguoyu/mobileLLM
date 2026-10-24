// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public struct AgentSessionMessageView: Identifiable, Sendable {
    public let id: MessageID
    public let text: String
    public let mode: AgentSessionInputMode
    public let included: Bool
}

public struct AgentSessionTurnView: Identifiable, Sendable {
    public var id: AgentRunID { runID }
    public let runID: AgentRunID
    public let handleID: AgentExecutionHandleID?
    public let status: AgentRunStatus?
    public let answer: String?
    public let inputIDs: [MessageID]
}

public struct AgentSessionView: Sendable {
    public let snapshot: AgentSessionSnapshot
    public let messages: [AgentSessionMessageView]
    public let turns: [AgentSessionTurnView]
}

private struct PreparedAgentSessionActivation: Codable, Sendable {
    let request: AgentRequest
    let inputs: FrozenAgentRunInputs
}

extension AgentRunController {
    var sessionJournal: (any AgentSessionJournaling)? { repository as? any AgentSessionJournaling }

    /// Reading a session never registers it, starts a run, or resumes interrupted work.
    public func sessionView(seedRunID: AgentRunID, conversationID: ConversationID) async throws -> AgentSessionView {
        let session = try await sessionSnapshot(seedRunID: seedRunID, conversationID: conversationID)
        let included = Set(session.inclusions.map(\.messageID))
        var messages: [AgentSessionMessageView] = []
        for input in session.inputs {
            messages.append(AgentSessionMessageView(id: input.id, text: try await sessionText(input.body),
                                                    mode: input.mode, included: included.contains(input.id)))
        }
        var turns: [AgentSessionTurnView] = []
        for activation in session.activations {
            if let snapshot = try await repository.loadRunSnapshot(for: activation.runID) {
                let history = try ExecutionHistory(events: snapshot.events, projection: snapshot.facts.projection)
                turns.append(AgentSessionTurnView(runID: activation.runID,
                    handleID: snapshot.facts.projection.executionHandleID, status: history.status,
                    answer: history.result?.answer?.text, inputIDs: activation.inputIDs))
            } else {
                turns.append(AgentSessionTurnView(runID: activation.runID, handleID: nil,
                    status: nil, answer: nil, inputIDs: activation.inputIDs))
            }
        }
        return AgentSessionView(snapshot: session, messages: messages, turns: turns)
    }

    /// Trusted host entry point for an explicit human message. Automatic agents cannot mint turns
    /// through this API's user authority. Workflow hosts decide when independent follow-ups may start.
    public func sendSessionInput(seedRunID: AgentRunID, conversationID: ConversationID,
                                 messageID: MessageID, text: String, mode: AgentSessionInputMode,
                                 startNextTurn: Bool) async throws {
        try beginPublicMutation()
        defer { endPublicMutation() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 16_384 else { throw AgentSessionError.inputTooLarge }
        let id = AgentSessionID(rawValue: seedRunID.rawValue)
        await acquireSessionGate(id)
        defer { releaseSessionGate(id) }
        guard let journal = sessionJournal else { throw AgentSessionError.unavailable }
        var session = try await sessionSnapshot(seedRunID: seedRunID, conversationID: conversationID)
        if let prior = session.inputs.first(where: { $0.id == messageID }) {
            guard try await sessionText(prior.body) == text, (prior.requestedMode ?? prior.mode) == mode
            else { throw AgentSessionError.inputConflict }
            if startNextTurn { _ = try await activateSession(session) }
            return
        }
        if try await journal.session(id) == nil { try await journal.appendSession(session, expectedRevision: 0) }
        guard session.inputs.count < 256 else { throw AgentSessionError.capacityReached }
        let body = try await payloadStore.commit(data: Data(text.utf8), mimeType: "text/plain",
            semanticType: "agent-session-input.v1", runID: seedRunID, stepID: nil, invocationID: nil,
            owner: .conversation(conversationID), sensitivity: .personalData)
        let acceptedAt = try await clock.now()
        // A terminal commit may win while the payload is being stored. Re-read, then let the
        // journal atomically reject a late steer so it can be queued as a new human turn.
        for _ in 0..<8 {
            session = try await sessionSnapshot(seedRunID: seedRunID, conversationID: conversationID)
            if let existing = session.inputs.first(where: { $0.id == messageID }) {
                guard try await sessionText(existing.body) == text, (existing.requestedMode ?? existing.mode) == mode
                else { throw AgentSessionError.inputConflict }
                if startNextTurn { _ = try await activateSession(session) }
                return
            }
            let last = session.activations.last!
            let facts = try await repository.loadRunFacts(for: last.runID)
            let target = mode == .steer && facts?.projection.isTerminal == false ? last.runID : nil
            var next = session
            next.revision += 1
            next.inputs.append(AgentSessionInput(id: messageID, mode: target == nil ? .nextTurn : .steer,
                body: body, acceptedAt: acceptedAt, targetRunID: target,
                requestedMode: target == nil && mode == .steer ? mode : nil))
            do {
                try await journal.appendSession(next, expectedRevision: session.revision)
                if startNextTurn, target == nil { _ = try await activateSession(next) }
                return
            } catch AgentSessionError.staleRevision { continue }
              catch AgentSessionError.requiresResume { continue }
        }
        throw AgentSessionError.staleRevision
    }

    /// Explicit user resume. Merely viewing the session or launching the application never calls it.
    public func resumeSession(seedRunID: AgentRunID, conversationID: ConversationID) async throws -> AgentExecutionHandleID? {
        try beginPublicMutation()
        defer { endPublicMutation() }
        let id = AgentSessionID(rawValue: seedRunID.rawValue)
        await acquireSessionGate(id)
        defer { releaseSessionGate(id) }
        let session = try await sessionSnapshot(seedRunID: seedRunID, conversationID: conversationID)
        return try await activateSession(session, resumeExisting: true)
    }

    private func sessionSnapshot(seedRunID: AgentRunID, conversationID: ConversationID) async throws -> AgentSessionSnapshot {
        guard let journal = sessionJournal,
              let facts = try await repository.loadRunFacts(for: seedRunID),
              let submission = facts.submission,
              submission.request.payload.conversationID == conversationID,
              submission.request.payload.outputRequirement == .text
        else { throw AgentSessionError.unavailable }
        let id = AgentSessionID(rawValue: seedRunID.rawValue)
        if let session = try await journal.session(id) {
            guard session.seedRunID == seedRunID, session.conversationID == conversationID else {
                throw AgentSessionError.invalidHistory
            }
            return session
        }
        return AgentSessionSnapshot(id: id, conversationID: conversationID,
            seed: AgentSessionActivation(runID: seedRunID, commandID: submission.commandID, inputIDs: []))
    }

    private func activateSession(_ snapshot: AgentSessionSnapshot, resumeExisting: Bool = false) async throws -> AgentExecutionHandleID? {
        guard let journal = sessionJournal else { throw AgentSessionError.unavailable }
        let session = try await journal.session(snapshot.id) ?? snapshot
        let last = session.activations.last!
        if let facts = try await repository.loadRunFacts(for: last.runID) {
            if !facts.projection.isTerminal {
                if resumeExisting, workers[last.runID] == nil {
                    let command = try AgentCommand(commandID: AgentCommandID(rawValue: UUID()), runID: last.runID,
                        expectedRunStateVersion: facts.projection.stateVersion, action: .resume, issuedAt: try await clock.now())
                    let receipt = try await send(AgentCommandEnvelope(payload: command), through: facts.projection.executionHandleID)
                    guard receipt.disposition == .accepted else { throw AgentSessionError.requiresResume }
                }
                return facts.projection.executionHandleID
            }
        } else if let material = last.material {
            return try await submitSessionActivation(last, material: material)
        } else { throw AgentSessionError.invalidHistory }

        guard let message = session.pendingTurns.first else { return nil }
        guard session.activations.count < 128 else { throw AgentSessionError.capacityReached }
        let material = try await prepareSessionActivation(session, input: message)
        let data = try ExecutionEncoding.encode(material)
        let artifact = try await payloadStore.commit(data: data, mimeType: "application/json",
            semanticType: "agent-session-activation.v1", runID: session.seedRunID, stepID: nil, invocationID: nil,
            owner: .conversation(session.conversationID), sensitivity: .personalData)
        let included = Set(session.inclusions.map(\.messageID))
        let assigned = Set(session.activations.flatMap(\.inputIDs))
        let carried = session.inputs.filter {
            !included.contains($0.id) && ($0.targetRunID != nil || assigned.contains($0.id))
        }.map(\.id)
        let activation = AgentSessionActivation(runID: material.request.runID,
            commandID: AgentCommandID(rawValue: message.id.rawValue), inputIDs: carried + [message.id], material: artifact)
        var next = session
        next.revision += 1
        next.activations.append(activation)
        try await journal.appendSession(next, expectedRevision: session.revision)
        return try await submitSessionActivation(activation, material: artifact)
    }

    private func submitSessionActivation(_ activation: AgentSessionActivation, material: ArtifactReference) async throws -> AgentExecutionHandleID {
        let bytes = try await payloadStore.load(material, maximumBytes: 4 * 1_024 * 1_024)
        let prepared = try ExecutionEncoding.decode(PreparedAgentSessionActivation.self, from: bytes)
        guard prepared.request.runID == activation.runID else { throw AgentSessionError.invalidHistory }
        return try await submit(prepared.request, commandID: activation.commandID, frozenInputs: prepared.inputs)
    }

    private func prepareSessionActivation(_ session: AgentSessionSnapshot, input: AgentSessionInput) async throws -> PreparedAgentSessionActivation {
        let last = session.activations.last!
        let (facts, history) = try await loadRun(last.runID)
        guard let submission = facts.submission, let result = history.result else { throw AgentSessionError.requiresResume }
        let prior = submission.request.payload
        let frozen = try await loadPayload(FrozenAgentRunInputs.self, reference: submission.inputSnapshot)
        var conversation = frozen.conversation
        let oldUser = try await sessionCurrentUser(frozen: frozen, runID: last.runID, includedOnly: true).source
        conversation.append(try ConversationTurnContextSource(messageID: ExecutionStableID.message(runID: last.runID, role: .user),
            revision: oldUser.frozen.revision, role: .user, content: oldUser.frozen.content))
        let output = result.answer?.text ?? result.status.failure?.safeMessage ?? "The previous activation ended without an answer."
        conversation.append(try ConversationTurnContextSource(messageID: ExecutionStableID.message(runID: last.runID, role: .assistant),
            revision: facts.projection.cursor.recordDigest.rawValue, role: .assistant, content: output))
        let text = try await sessionText(input.body)
        let runID = AgentRunID(rawValue: input.id.rawValue)
        let turnID = UserTurnID(rawValue: input.id.rawValue)
        let request = try AgentRequest(id: AgentRequestID(rawValue: input.id.rawValue), runID: runID,
            conversationID: session.conversationID, userTurnID: turnID, parent: prior.parent,
            role: prior.role, instruction: text, outputRequirement: .text, modelPolicy: prior.modelPolicy,
            capabilityCeiling: prior.capabilityCeiling, budget: prior.budget,
            contextReferences: prior.contextReferences, artifactReferences: prior.artifactReferences,
            sandboxRequirement: prior.sandboxRequirement,
            labels: [AgentRequestLabel(key: "session.id", value: session.id.description)],
            provenance: AgentRequestProvenance(source: .workflow, parentRequestID: prior.provenance.parentRequestID,
                evidenceDigests: prior.provenance.evidenceDigests + [input.body.contentDigest]),
            approvalMode: prior.approvalMode, parallelToolBatchLimit: prior.parallelToolBatchLimit)
        let inputs = try frozen.replacingConversation(conversation, currentUser: CurrentUserContextSource(
            userTurnID: turnID, revision: input.body.contentDigest.rawValue, content: text))
        return PreparedAgentSessionActivation(request: request, inputs: inputs)
    }

    func sessionCurrentUser(frozen: FrozenAgentRunInputs, runID: AgentRunID, includedOnly: Bool) async throws
        -> (source: CurrentUserContextSource, unclaimed: [MessageID]) {
        guard let session = try await sessionJournal?.session(for: runID) else { return (frozen.currentUser, []) }
        let included = Set(session.inclusions.map(\.messageID))
        let inputs = session.inputs(for: runID).filter { !includedOnly || included.contains($0.id) }
        let steering = inputs.filter { $0.mode == .steer || $0.id.description != frozen.currentUser.frozen.sourceID }
        var content = frozen.currentUser.frozen.content
        let carried = steering.filter { $0.targetRunID != runID }
        if !carried.isEmpty {
            var earlier = "Earlier user instructions retained after interruption:\n"
            for input in carried { earlier += "\n" + (try await sessionText(input.body)) + "\n" }
            content = earlier + "\nCurrent user instruction:\n" + content
        }
        let fresh = steering.filter { $0.targetRunID == runID }
        if !fresh.isEmpty {
            content += "\n\nAdditional user instructions, in acceptance order:\n"
            for input in fresh { content += "\n" + (try await sessionText(input.body)) + "\n" }
        }
        let revision = StableDigest.fingerprint(domain: "agent-session-current-user.v1",
            components: [Data(frozen.currentUser.frozen.revision.utf8)] + steering.map { Data($0.body.contentDigest.rawValue.utf8) })
        guard let turnID = UserTurnID(frozen.currentUser.frozen.sourceID) else { throw AgentSessionError.invalidHistory }
        return (try CurrentUserContextSource(userTurnID: turnID,
                    revision: revision.rawValue, content: content, attachments: frozen.currentUser.attachments),
                inputs.filter { !included.contains($0.id) }.map(\.id))
    }

    private func sessionText(_ artifact: ArtifactReference) async throws -> String {
        let data = try await payloadStore.load(artifact, maximumBytes: 16_384)
        guard let text = String(data: data, encoding: .utf8) else { throw AgentSessionError.invalidHistory }
        return text
    }

    /// Only explicitly requested follow-up activations advance queued human turns. The seed run
    /// still belongs to its original workflow, whose controller owns its next dispatch decision.
    func advanceSessionAfterCompletion(_ runID: AgentRunID) async {
        guard !dataEraseSuspended else { return }
        do {
            try beginPublicMutation()
            defer { endPublicMutation() }
            guard let session = try await sessionJournal?.session(for: runID),
                  session.activations.count > 1, session.activations.last?.runID == runID,
                  !session.pendingTurns.isEmpty,
                  try await repository.loadRunFacts(for: runID)?.projection.state == .completed
            else { return }
            await acquireSessionGate(session.id)
            defer { releaseSessionGate(session.id) }
            guard !dataEraseSuspended else { return }
            _ = try await activateSession(session)
        } catch {
            await logger.record(code: "execution.session-continuation-pending", metadata: ["run": runID.description])
        }
    }

    private func acquireSessionGate(_ id: AgentSessionID) async {
        if sessionGates[id] != nil {
            await withCheckedContinuation { continuation in sessionGates[id]!.waiters.append(continuation) }
        } else { sessionGates[id] = ToolCommitGate(inFlight: true) }
    }

    private func releaseSessionGate(_ id: AgentSessionID) {
        guard var gate = sessionGates[id] else { return }
        if gate.waiters.isEmpty { sessionGates.removeValue(forKey: id) }
        else {
            let next = gate.waiters.removeFirst()
            sessionGates[id] = gate
            next.resume()
        }
    }
}
