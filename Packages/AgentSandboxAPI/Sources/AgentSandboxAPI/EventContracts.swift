// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Safe, redacted diagnostic emitted by a sandbox provider.
public struct SandboxAuditRecord: Hashable, Codable, Sendable {
    public let category: String
    public let action: String
    public let safeDetails: [String: String]

    public init(category: String, action: String, safeDetails: [String: String] = [:]) throws {
        let byteCount = safeDetails.reduce(0) { partial, entry in
            let keyBytes = min(65_537, entry.key.utf8.count)
            let valueBytes = min(65_537, entry.value.utf8.count)
            let addition = keyBytes > 65_537 - valueBytes ? 65_537 : keyBytes + valueBytes
            return partial > 65_537 - addition ? 65_537 : partial + addition
        }
        guard SandboxContractValidation.namespace(category),
              SandboxContractValidation.namespace(action),
              safeDetails.count <= 64,
              byteCount <= 65_536,
              safeDetails.allSatisfy({ key, value in
                  SandboxContractValidation.namespace(key)
                      && (value.isEmpty
                          || SandboxContractValidation.safeText(value, maximumUTF8Bytes: 2_048))
              })
        else { throw AgentSandboxAPIError.invalidValue("audit record") }
        self.category = category
        self.action = action
        self.safeDetails = safeDetails
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            try Self(
                category: container.decode(String.self, forKey: .category),
                action: container.decode(String.self, forKey: .action),
                safeDetails: container.decode([String: String].self, forKey: .safeDetails)
            )
        }
    }
}

/// Exhaustive first-version event vocabulary for durable sandbox observation.
public enum SandboxEvent: Hashable, Codable, Sendable {
    case accepted(requestFingerprint: StableDigest)
    case started
    case progress(AgentExecutionProgress)
    case audit(SandboxAuditRecord)
    case artifactProduced(ArtifactReference)
    case checkpointCreated(SandboxCheckpointHandleID)
    case commandProcessed(SandboxCommandReceipt)
    case terminal(SandboxExecutionResult)
}

/// Hash-chained durable event record. A cursor is valid only after journal lookup of this record.
public struct SandboxEventRecord: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.event"

    public let eventID: SandboxEventID
    public let handleID: SandboxExecutionHandleID
    public let sequence: UInt64
    public let timestamp: AgentTimestamp
    public let status: SandboxExecutionStatus
    public let cumulativeUsage: AgentUsage
    public let event: SandboxEvent
    public let previousRecordDigest: StableDigest?
    public let recordDigest: StableDigest

    public var cursor: AgentEventCursor {
        get throws {
            try AgentEventCursor(
                executionHandleID: AgentExecutionHandleID(rawValue: handleID.rawValue),
                eventID: AgentEventID(rawValue: eventID.rawValue),
                sequence: sequence,
                runStateVersion: status.stateVersion,
                runState: status.state.agentRunState,
                timestamp: timestamp,
                cumulativeUsage: cumulativeUsage,
                recordDigest: recordDigest,
                isTerminal: status.state.isTerminal
            )
        }
    }

    /// Auxiliary narrow cursor for callers that persist sandbox-only cursor metadata.
    public var sandboxCursor: SandboxEventCursor {
        get throws {
            try SandboxEventCursor(
                executionHandleID: handleID,
                eventID: eventID,
                sequence: sequence
            )
        }
    }

    public init(
        eventID: SandboxEventID,
        handleID: SandboxExecutionHandleID,
        sequence: UInt64,
        timestamp: AgentTimestamp,
        status: SandboxExecutionStatus,
        cumulativeUsage: AgentUsage = .zero,
        event: SandboxEvent,
        previousRecordDigest: StableDigest?
    ) throws {
        guard sequence > 0,
              (sequence == 1) == (previousRecordDigest == nil),
              status.handleID == handleID,
              timestamp >= status.updatedAt
        else { throw AgentSandboxAPIError.invalidEventChain }

        switch event {
        case .accepted:
            guard sequence == 1, status.state == .accepted else {
                throw AgentSandboxAPIError.invalidEventChain
            }
        case .started:
            guard status.state == .running else { throw AgentSandboxAPIError.invalidEventChain }
        case .progress(let progress):
            guard status.state == .running || status.state == .cancellationRequested,
                  status.progress == progress
            else { throw AgentSandboxAPIError.invalidEventChain }
        case .audit, .artifactProduced, .checkpointCreated:
            guard !status.state.isTerminal else { throw AgentSandboxAPIError.invalidEventChain }
        case .commandProcessed(let receipt):
            guard receipt.handleID == handleID, receipt.currentStatus == status else {
                throw AgentSandboxAPIError.invalidEventChain
            }
        case .terminal(let result):
            guard result.handleID == handleID,
                  result.terminalStatus == status,
                  result.usage == cumulativeUsage,
                  status.state.isTerminal
            else { throw AgentSandboxAPIError.invalidEventChain }
        }
        if status.state.isTerminal {
            guard case .terminal = event else { throw AgentSandboxAPIError.invalidEventChain }
        }

        self.eventID = eventID
        self.handleID = handleID
        self.sequence = sequence
        self.timestamp = timestamp
        self.status = status
        self.cumulativeUsage = cumulativeUsage
        self.event = event
        self.previousRecordDigest = previousRecordDigest
        recordDigest = try Self.makeDigest(
            eventID: eventID,
            handleID: handleID,
            sequence: sequence,
            timestamp: timestamp,
            status: status,
            cumulativeUsage: cumulativeUsage,
            event: event,
            previousRecordDigest: previousRecordDigest
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedDigest = try container.decode(StableDigest.self, forKey: .recordDigest)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                eventID: container.decode(SandboxEventID.self, forKey: .eventID),
                handleID: container.decode(SandboxExecutionHandleID.self, forKey: .handleID),
                sequence: container.decode(UInt64.self, forKey: .sequence),
                timestamp: container.decode(AgentTimestamp.self, forKey: .timestamp),
                status: container.decode(SandboxExecutionStatus.self, forKey: .status),
                cumulativeUsage: container.decode(AgentUsage.self, forKey: .cumulativeUsage),
                event: container.decode(SandboxEvent.self, forKey: .event),
                previousRecordDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .previousRecordDigest
                )
            )
            guard decoded.recordDigest == encodedDigest else {
                throw AgentSandboxAPIError.invalidEventChain
            }
            return decoded
        }
    }

    private struct DigestMaterial: Encodable {
        let eventID: SandboxEventID
        let handleID: SandboxExecutionHandleID
        let sequence: UInt64
        let timestamp: AgentTimestamp
        let status: SandboxExecutionStatus
        let cumulativeUsage: AgentUsage
        let event: SandboxEvent
        let previousRecordDigest: StableDigest?
    }

    private static func makeDigest(
        eventID: SandboxEventID,
        handleID: SandboxExecutionHandleID,
        sequence: UInt64,
        timestamp: AgentTimestamp,
        status: SandboxExecutionStatus,
        cumulativeUsage: AgentUsage,
        event: SandboxEvent,
        previousRecordDigest: StableDigest?
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-event-record.v1",
            value: DigestMaterial(
                eventID: eventID,
                handleID: handleID,
                sequence: sequence,
                timestamp: timestamp,
                status: status,
                cumulativeUsage: cumulativeUsage,
                event: event,
                previousRecordDigest: previousRecordDigest
            )
        )
    }
}

/// Stateless validation for replay pages after a cursor has been resolved by trusted storage.
public enum SandboxEventPageValidator {
    /// Validates identities, continuity, terminal placement, and the complete record hash chain.
    ///
    /// A provider must first resolve the supplied cursor against its local durable journal. This
    /// stateless validator then binds the replay page to the cursor's complete hash-chain anchor.
    public static func validate(
        _ envelopes: [SandboxEventEnvelope],
        after cursor: AgentEventCursor?
    ) throws {
        if cursor?.isTerminal == true, !envelopes.isEmpty {
            throw AgentSandboxAPIError.invalidCursor
        }
        guard let first = envelopes.first else { return }
        let handleID = first.payload.handleID
        if let cursor,
           cursor.executionHandleID.rawValue != handleID.rawValue
        {
            throw AgentSandboxAPIError.invalidCursor
        }
        let expectedFirstSequence: UInt64
        if let cursor {
            let (next, overflow) = cursor.sequence.addingReportingOverflow(1)
            guard !overflow else { throw AgentSandboxAPIError.invalidCursor }
            expectedFirstSequence = next
        } else {
            expectedFirstSequence = 1
        }
        guard first.payload.handleID == handleID,
              first.payload.sequence == expectedFirstSequence,
              first.payload.previousRecordDigest == cursor?.recordDigest
        else { throw AgentSandboxAPIError.invalidEventChain }

        var previousDigest = cursor?.recordDigest
        var previousUsage = cursor?.cumulativeUsage ?? .zero
        var expectedSequence = expectedFirstSequence
        var sawTerminal = false
        for (index, envelope) in envelopes.enumerated() {
            let record = envelope.payload
            guard !sawTerminal,
                  envelope.protocolVersion == record.status.protocolVersion,
                  record.handleID == handleID,
                  record.sequence == expectedSequence,
                  record.previousRecordDigest == previousDigest,
                  previousUsage.quantities.isComponentwiseAtMost(record.cumulativeUsage.quantities)
            else { throw AgentSandboxAPIError.invalidEventChain }
            sawTerminal = record.status.state.isTerminal
            previousDigest = record.recordDigest
            previousUsage = record.cumulativeUsage
            let (next, overflow) = expectedSequence.addingReportingOverflow(1)
            if overflow, index != envelopes.index(before: envelopes.endIndex) {
                throw AgentSandboxAPIError.invalidEventChain
            }
            expectedSequence = next
        }
    }
}

private extension SandboxExecutionState {
    var agentRunState: AgentRunState {
        switch self {
        case .accepted: .preparing
        case .running: .executingTools
        case .cancellationRequested: .pausing
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

public typealias SandboxEventEnvelope = AgentEnvelope<SandboxEventRecord>
