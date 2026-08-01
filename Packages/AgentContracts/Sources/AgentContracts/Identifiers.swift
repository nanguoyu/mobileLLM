// SPDX-License-Identifier: MIT

import Foundation

/// A marker protocol that gives each stable identifier its own compile-time domain.
public protocol AgentIdentifierDomain: Sendable {}

/// A stable opaque UUID identifier whose generic domain prevents cross-entity substitution.
public struct AgentIdentifier<Domain: AgentIdentifierDomain>: RawRepresentable, Hashable, Codable,
    Sendable, CustomStringConvertible, LosslessStringConvertible
{
    /// The UUID stored by the identifier.
    public let rawValue: UUID

    /// Creates a new random stable identifier.
    public init() {
        rawValue = UUID()
    }

    /// Creates an identifier from an already generated UUID.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Parses the canonical UUID representation of an identifier.
    public init?(_ description: String) {
        guard let value = UUID(uuidString: description) else { return nil }
        rawValue = value
    }

    /// The canonical lowercase UUID representation used on the wire.
    public var description: String {
        rawValue.uuidString.lowercased()
    }

    /// Decodes an identifier from one canonical UUID string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let value = Self(encoded), encoded == value.description else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a canonical lowercase UUID identifier string"
            )
        }
        self = value
    }

    /// Encodes the identifier as one canonical UUID string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Identifier domain for an agent run.
public enum AgentRunIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a stable run step.
public enum AgentStepIDDomain: AgentIdentifierDomain {}
/// Identifier domain for an agent request.
public enum AgentRequestIDDomain: AgentIdentifierDomain {}
/// Identifier domain for one normalized tool invocation.
public enum ToolInvocationIDDomain: AgentIdentifierDomain {}
/// Identifier domain for an approval decision and receipt.
public enum ApprovalIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a durable artifact.
public enum ArtifactIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a durable event.
public enum AgentEventIDDomain: AgentIdentifierDomain {}
/// Identifier domain for an agent execution handle.
public enum AgentExecutionHandleIDDomain: AgentIdentifierDomain {}
/// Identifier domain for an idempotent agent command.
public enum AgentCommandIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a durable conversation message.
public enum MessageIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a conversation.
public enum ConversationIDDomain: AgentIdentifierDomain {}
/// Identifier domain for the user turn that initiated a run.
public enum UserTurnIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a durable user-interaction request.
public enum InteractionRequestIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a budget reservation.
public enum BudgetReservationIDDomain: AgentIdentifierDomain {}
/// Identifier domain for an opaque sandbox workspace handle.
public enum SandboxWorkspaceHandleIDDomain: AgentIdentifierDomain {}
/// Identifier domain for an opaque sandbox checkpoint handle.
public enum SandboxCheckpointHandleIDDomain: AgentIdentifierDomain {}
/// Identifier domain for an opaque secret reference.
public enum SecretReferenceIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a sandbox-provider execution handle.
public enum SandboxExecutionHandleIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a sandbox command.
public enum SandboxCommandIDDomain: AgentIdentifierDomain {}
/// Identifier domain for a sandbox event.
public enum SandboxEventIDDomain: AgentIdentifierDomain {}

/// Stable identifier for an agent run.
public typealias AgentRunID = AgentIdentifier<AgentRunIDDomain>
/// Stable identifier for an execution step.
public typealias AgentStepID = AgentIdentifier<AgentStepIDDomain>
/// Stable identifier for an agent request.
public typealias AgentRequestID = AgentIdentifier<AgentRequestIDDomain>
/// Stable identifier for one tool invocation.
public typealias ToolInvocationID = AgentIdentifier<ToolInvocationIDDomain>
/// Stable identifier for an approval.
public typealias ApprovalID = AgentIdentifier<ApprovalIDDomain>
/// Stable identifier for an artifact.
public typealias ArtifactID = AgentIdentifier<ArtifactIDDomain>
/// Stable identifier for an event.
public typealias AgentEventID = AgentIdentifier<AgentEventIDDomain>
/// Stable identifier used to reattach to an agent execution.
public typealias AgentExecutionHandleID = AgentIdentifier<AgentExecutionHandleIDDomain>
/// Stable identifier used to deduplicate a state-changing command.
public typealias AgentCommandID = AgentIdentifier<AgentCommandIDDomain>
/// Stable identifier for a durable message.
public typealias MessageID = AgentIdentifier<MessageIDDomain>
/// Stable identifier for a conversation.
public typealias ConversationID = AgentIdentifier<ConversationIDDomain>
/// Stable identifier for a user turn.
public typealias UserTurnID = AgentIdentifier<UserTurnIDDomain>
/// Stable identifier for a request for additional user input.
public typealias InteractionRequestID = AgentIdentifier<InteractionRequestIDDomain>
/// Stable identifier for one budget reservation.
public typealias BudgetReservationID = AgentIdentifier<BudgetReservationIDDomain>
/// Opaque identifier for a sandbox workspace.
public typealias SandboxWorkspaceHandleID = AgentIdentifier<SandboxWorkspaceHandleIDDomain>
/// Opaque identifier for a sandbox checkpoint.
public typealias SandboxCheckpointHandleID = AgentIdentifier<SandboxCheckpointHandleIDDomain>
/// Opaque identifier for a secret stored outside durable envelopes.
public typealias SecretReferenceID = AgentIdentifier<SecretReferenceIDDomain>
/// Stable provider-neutral sandbox execution handle.
public typealias SandboxExecutionHandleID = AgentIdentifier<SandboxExecutionHandleIDDomain>
/// Stable idempotency identity for a sandbox command.
public typealias SandboxCommandID = AgentIdentifier<SandboxCommandIDDomain>
/// Stable identity for one durable sandbox event.
public typealias SandboxEventID = AgentIdentifier<SandboxEventIDDomain>

/// Cursor bound to one sandbox execution stream and committed event.
public struct SandboxEventCursor: Hashable, Codable, Sendable, Comparable {
    /// Owning sandbox execution.
    public let executionHandleID: SandboxExecutionHandleID
    /// Last committed sandbox event.
    public let eventID: SandboxEventID
    /// Positive monotonic sequence of the last committed event.
    public let sequence: UInt64

    /// Creates a valid sandbox cursor.
    public init(
        executionHandleID: SandboxExecutionHandleID,
        eventID: SandboxEventID,
        sequence: UInt64
    ) throws {
        guard sequence > 0 else {
            throw AgentContractError.invalidEventSequence("sandbox cursor sequence must be positive")
        }
        self.executionHandleID = executionHandleID
        self.eventID = eventID
        self.sequence = sequence
    }

    /// Decodes and revalidates a sandbox cursor.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                executionHandleID: container.decode(
                    SandboxExecutionHandleID.self,
                    forKey: .executionHandleID
                ),
                eventID: container.decode(SandboxEventID.self, forKey: .eventID),
                sequence: container.decode(UInt64.self, forKey: .sequence)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case executionHandleID, eventID, sequence }

    /// Orders cursors by execution, sequence, and event identity.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.executionHandleID != rhs.executionHandleID {
            return lhs.executionHandleID.description < rhs.executionHandleID.description
        }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.eventID.description < rhs.eventID.description
    }
}

/// A durable cursor that resumes an event subscription after a committed event.
public struct AgentEventCursor: Hashable, Codable, Sendable, Comparable {
    /// The execution stream to which this cursor belongs.
    public let executionHandleID: AgentExecutionHandleID

    /// The last event observed by the subscriber.
    public let eventID: AgentEventID

    /// The monotonically increasing sequence of the last observed event.
    public let sequence: UInt64

    /// State version at the anchored event.
    public let runStateVersion: UInt64

    /// Durable run state at the anchored event.
    public let runState: AgentRunState

    /// Commit timestamp at the anchored event.
    public let timestamp: AgentTimestamp

    /// Cumulative usage at the anchored event.
    public let cumulativeUsage: AgentUsage

    /// Hash-chain digest of the complete anchored record.
    public let recordDigest: StableDigest

    /// Whether the anchored event terminated the stream.
    public let isTerminal: Bool

    /// Creates a cursor for a committed event sequence.
    public init(
        executionHandleID: AgentExecutionHandleID,
        eventID: AgentEventID,
        sequence: UInt64,
        runStateVersion: UInt64,
        runState: AgentRunState,
        timestamp: AgentTimestamp,
        cumulativeUsage: AgentUsage,
        recordDigest: StableDigest,
        isTerminal: Bool
    ) throws {
        guard sequence > 0, runStateVersion > 0, isTerminal == runState.isTerminal else {
            throw AgentContractError.invalidEventSequence("invalid cursor anchor")
        }
        self.executionHandleID = executionHandleID
        self.eventID = eventID
        self.sequence = sequence
        self.runStateVersion = runStateVersion
        self.runState = runState
        self.timestamp = timestamp
        self.cumulativeUsage = cumulativeUsage
        self.recordDigest = recordDigest
        self.isTerminal = isTerminal
    }

    /// Decodes and revalidates a complete cursor anchor.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                executionHandleID: container.decode(
                    AgentExecutionHandleID.self,
                    forKey: .executionHandleID
                ),
                eventID: container.decode(AgentEventID.self, forKey: .eventID),
                sequence: container.decode(UInt64.self, forKey: .sequence),
                runStateVersion: container.decode(UInt64.self, forKey: .runStateVersion),
                runState: container.decode(AgentRunState.self, forKey: .runState),
                timestamp: container.decode(AgentTimestamp.self, forKey: .timestamp),
                cumulativeUsage: container.decode(AgentUsage.self, forKey: .cumulativeUsage),
                recordDigest: container.decode(StableDigest.self, forKey: .recordDigest),
                isTerminal: container.decode(Bool.self, forKey: .isTerminal)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case executionHandleID, eventID, sequence, runStateVersion, runState, timestamp
        case cumulativeUsage, recordDigest, isTerminal
    }

    /// Orders cursors by sequence and then by stable event identity.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.executionHandleID != rhs.executionHandleID {
            return lhs.executionHandleID.description < rhs.executionHandleID.description
        }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.eventID != rhs.eventID { return lhs.eventID.description < rhs.eventID.description }
        return lhs.recordDigest.rawValue < rhs.recordDigest.rawValue
    }
}

/// Non-serializable cursor anchor resolved against a trusted local journal.
public struct TrustedAgentEventCursor: Hashable, Sendable {
    /// Journal-verified cursor value.
    public let cursor: AgentEventCursor

    /// Marks a cursor as trusted only after the runtime has matched its event ID and record digest.
    @_spi(AgentRuntime)
    public init(cursor: AgentEventCursor) { self.cursor = cursor }
}
