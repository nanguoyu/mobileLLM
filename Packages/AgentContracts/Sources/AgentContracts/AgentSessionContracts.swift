// SPDX-License-Identifier: MIT

import Foundation

/// A conversation owned by one agent, independent of any individual execution.
public enum AgentSessionIDDomain: AgentIdentifierDomain {}
public typealias AgentSessionID = AgentIdentifier<AgentSessionIDDomain>

public enum AgentSessionInputMode: String, Codable, Sendable {
    case steer
    case nextTurn
    /// Agent-authored information, saved for later context without requiring a reply or activation.
    case notice
}

/// Nil on old records means a human. Agent identities are supplied by the trusted runtime.
public enum AgentSessionInputSender: Hashable, Codable, Sendable {
    case agent(AgentRunID)
    /// Human amendment scoped to an existing goal; it does not grant a standalone follow-up budget.
    case goalOwner(WorkflowRunID)
}

public struct AgentSessionPendingMessage: Hashable, Codable, Sendable {
    public let id: MessageID
    public let seedRunID: AgentRunID
    public let sender: AgentSessionInputSender?
    public let preview: String
    public init(id: MessageID, seedRunID: AgentRunID, sender: AgentSessionInputSender?, preview: String) {
        self.id = id; self.seedRunID = seedRunID; self.sender = sender; self.preview = preview
    }
}

public struct AgentSessionPendingInputs: Hashable, Codable, Sendable {
    public let count: Int
    public let messages: [AgentSessionPendingMessage]
    public init(count: Int = 0, messages: [AgentSessionPendingMessage] = []) { self.count = count; self.messages = messages }
}

/// Accepted input. The protected artifact contains its UTF-8 body.
public struct AgentSessionInput: Hashable, Codable, Sendable {
    public let id: MessageID
    public let mode: AgentSessionInputMode
    public let body: ArtifactReference
    public let acceptedAt: AgentTimestamp
    /// A steering message addresses an exact activation. Queued input is bound at activation.
    public let targetRunID: AgentRunID?
    /// Retains the caller's intent when a late steer was accepted as a subsequent turn.
    public let requestedMode: AgentSessionInputMode?
    public let sender: AgentSessionInputSender?

    public init(id: MessageID, mode: AgentSessionInputMode, body: ArtifactReference,
                acceptedAt: AgentTimestamp, targetRunID: AgentRunID?, requestedMode: AgentSessionInputMode? = nil,
                sender: AgentSessionInputSender? = nil) {
        self.id = id
        self.mode = mode
        self.body = body
        self.acceptedAt = acceptedAt
        self.targetRunID = targetRunID
        self.requestedMode = requestedMode
        self.sender = sender
    }
}

/// A reserved activation. Material is committed before reservation, allowing exact submission replay.
public struct AgentSessionActivation: Hashable, Codable, Sendable {
    public let runID: AgentRunID
    public let commandID: AgentCommandID
    public let inputIDs: [MessageID]
    /// Nil only for the already submitted seed run.
    public let material: ArtifactReference?
    /// Automatic activations are advanced only by their workflow's shared-budget admission.
    public let workflowManaged: Bool?

    public init(runID: AgentRunID, commandID: AgentCommandID, inputIDs: [MessageID],
                material: ArtifactReference? = nil, workflowManaged: Bool? = nil) {
        self.runID = runID
        self.commandID = commandID
        self.inputIDs = inputIDs
        self.material = material
        self.workflowManaged = workflowManaged
    }
}

/// Inclusion in an immutable model-request context, distinct from model completion.
public struct AgentSessionInputInclusion: Hashable, Codable, Sendable {
    public let messageID: MessageID
    public let runID: AgentRunID
    public let stepID: AgentStepID

    public init(messageID: MessageID, runID: AgentRunID, stepID: AgentStepID) {
        self.messageID = messageID
        self.runID = runID
        self.stepID = stepID
    }
}

/// Append-only session facts. Run status and outputs remain authoritative in the run journal.
public struct AgentSessionSnapshot: Hashable, Codable, Sendable {
    public let id: AgentSessionID
    public let conversationID: ConversationID
    public let seedRunID: AgentRunID
    public var revision: UInt64
    public var inputs: [AgentSessionInput]
    public var activations: [AgentSessionActivation]
    public var inclusions: [AgentSessionInputInclusion]

    public init(id: AgentSessionID, conversationID: ConversationID, seed: AgentSessionActivation) {
        self.id = id
        self.conversationID = conversationID
        seedRunID = seed.runID
        revision = 1
        inputs = []
        activations = [seed]
        inclusions = []
    }

    public func validate() throws {
        guard revision > 0, revision <= UInt64(Int64.max),
              !activations.isEmpty, activations.count <= 128, inputs.count <= 256,
              inclusions.count <= inputs.count,
              activations[0].runID == seedRunID, activations[0].material == nil,
              activations[0].inputIDs.isEmpty,
              Set(inputs.map(\.id)).count == inputs.count,
              Set(activations.map(\.runID)).count == activations.count,
              Set(activations.map(\.commandID)).count == activations.count,
              Set(inclusions.map(\.messageID)).count == inclusions.count
        else { throw AgentContractError.invalidName("agent session facts") }
        let runs = Set(activations.map(\.runID))
        for (index, activation) in activations.enumerated().dropFirst() {
            guard activation.material != nil, !activation.inputIDs.isEmpty,
                  Set(activation.inputIDs).count == activation.inputIDs.count else {
                throw AgentContractError.invalidName("agent session activation")
            }
            for id in activation.inputIDs {
                guard let input = inputs.first(where: { $0.id == id }),
                      input.targetRunID == nil || activations.prefix(index).contains(where: { $0.runID == input.targetRunID }),
                      !inclusions.contains(where: { inclusion in
                          inclusion.messageID == id && activations.prefix(index).contains(where: { $0.runID == inclusion.runID })
                      })
                else { throw AgentContractError.invalidName("agent session activation input") }
            }
        }
        for input in inputs {
            let limit: UInt64
            if case .agent = input.sender { limit = 262_144 } else { limit = 16_384 }
            guard input.body.byteCount > 0, input.body.byteCount <= limit,
                  input.body.semanticType == "agent-session-input.v1",
                  (input.mode == .steer && input.targetRunID.map(runs.contains) == true)
                    || (input.mode == .nextTurn && input.targetRunID == nil)
                    || (input.mode == .notice && (input.targetRunID == nil || input.targetRunID.map(runs.contains) == true))
            else { throw AgentContractError.invalidName("agent session input") }
            if input.mode == .notice, case .agent = input.sender {} else if input.mode == .notice {
                throw AgentContractError.invalidName("only agent messages may be optional notices")
            }
        }
        for inclusion in inclusions {
            guard let input = inputs.first(where: { $0.id == inclusion.messageID }),
                  input.targetRunID == inclusion.runID
                    || activations.contains(where: { $0.runID == inclusion.runID && $0.inputIDs.contains(input.id) })
            else { throw AgentContractError.invalidName("agent session input inclusion") }
        }
    }

    public func inputs(for runID: AgentRunID) -> [AgentSessionInput] {
        let assigned = Set(activations.first(where: { $0.runID == runID })?.inputIDs ?? [])
        return inputs.filter { $0.targetRunID == runID || assigned.contains($0.id) }
    }

    public func pendingInputs(for runID: AgentRunID) -> [AgentSessionInput] {
        let included = Set(inclusions.map(\.messageID))
        return inputs(for: runID).filter { !included.contains($0.id) }
    }

    public func pendingInstructions(for runID: AgentRunID) -> [AgentSessionInput] {
        pendingInputs(for: runID).filter { $0.mode != .notice }
    }

    public var pendingTurns: [AgentSessionInput] {
        let assigned = Set(activations.flatMap(\.inputIDs))
        return inputs.filter { $0.mode == .nextTurn && !assigned.contains($0.id) }
    }
}
