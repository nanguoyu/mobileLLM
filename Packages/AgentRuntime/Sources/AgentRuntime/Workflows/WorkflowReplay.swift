// SPDX-License-Identifier: MIT

import AgentContracts
import CryptoKit
import Foundation

public enum WorkflowReplayDecision: Hashable, Sendable {
    case reuse(call: WorkflowAgentCallV1, outcome: WorkflowAgentOutcomeV1)
    case `continue`(call: WorkflowAgentCallV1)
    case execute(call: WorkflowAgentCallV1)
}

/// Started-order rolling-prefix replay. It deliberately does not include the complete script digest:
/// edits after a completed prefix may reuse that prefix, while any changed invocation breaks reuse
/// for that call and every call started later.
public actor WorkflowReplayCursor {
    private let runID: WorkflowRunID
    private let previousCalls: [WorkflowAgentCallV1]
    private let previousOutcomes: [WorkflowAgentCallID: WorkflowAgentOutcomeV1]
    private let invalidatedCalls: Set<WorkflowAgentCallID>
    private var priorPrefixIsReusable = true
    private var previousKey: StableDigest
    private var nextOrdinal: UInt32 = 1

    public init(
        launch: WorkflowLaunchSnapshotV1,
        priorProjection: WorkflowRunProjectionV1? = nil
    ) throws {
        runID = launch.runID
        previousCalls = priorProjection?.calls ?? []
        previousOutcomes = priorProjection?.outcomes ?? [:]
        invalidatedCalls = Set(priorProjection?.restartRequests ?? [])
        previousKey = try Self.seed(for: launch)
    }

    public func next(prompt: String, options: WorkflowAgentOptionsV1, reuseSettledFailures: Bool = false) throws -> WorkflowReplayDecision {
        guard nextOrdinal > 0 else { throw WorkflowScriptRuntimeError.internalInvariant("workflow ordinal overflow") }
        let promptDigest = StableDigest.fingerprint(
            domain: "dynamic-workflow-agent-prompt.v1",
            components: [Data(prompt.utf8)]
        )
        let optionsDigest = try options.outputIdentity()
        let prefixKey = StableDigest.fingerprint(
            domain: "dynamic-workflow-prefix.v1",
            components: [
                Data(previousKey.rawValue.utf8),
                Data(promptDigest.rawValue.utf8),
                Data(optionsDigest.rawValue.utf8),
            ]
        )
        let existingAttempts = previousCalls.filter { $0.ordinal == nextOrdinal }
        if priorPrefixIsReusable,
           let prior = existingAttempts.last,
           prior.prefixKey == prefixKey,
           !invalidatedCalls.contains(prior.callID)
        {
            if let outcome = previousOutcomes[prior.callID], reuseSettledFailures || Self.isCompleted(outcome) {
                previousKey = prefixKey
                if nextOrdinal == UInt32.max { nextOrdinal = 0 } else { nextOrdinal += 1 }
                return .reuse(call: prior, outcome: outcome)
            }
            if previousOutcomes[prior.callID] == nil {
                previousKey = prefixKey
                if nextOrdinal == UInt32.max { nextOrdinal = 0 } else { nextOrdinal += 1 }
                return .continue(call: prior)
            }
        }
        priorPrefixIsReusable = false
        let priorAttempt = existingAttempts.map(\.attempt).max() ?? 0
        let (nextAttempt, attemptOverflow) = priorAttempt.addingReportingOverflow(1)
        guard !attemptOverflow else {
            throw WorkflowScriptRuntimeError.internalInvariant("workflow attempt overflow")
        }
        let callID = WorkflowAgentCallID(rawValue: Self.stableUUID(
            domain: "dynamic-workflow-call.v1",
            components: [runID.description, String(nextOrdinal), String(nextAttempt), prefixKey.rawValue]
        ))
        let childRunID = AgentRunID(rawValue: Self.stableUUID(
            domain: "dynamic-workflow-child.v1",
            components: [runID.description, String(nextOrdinal), String(nextAttempt), prefixKey.rawValue]
        ))
        let call = try WorkflowAgentCallV1(
            callID: callID,
            ordinal: nextOrdinal,
            attempt: nextAttempt,
            prefixKey: prefixKey,
            promptDigest: promptDigest,
            options: options,
            childRunID: childRunID
        )
        defer {
            previousKey = prefixKey
            if nextOrdinal == UInt32.max { nextOrdinal = 0 } else { nextOrdinal += 1 }
        }
        return .execute(call: call)
    }

    private static func isCompleted(_ outcome: WorkflowAgentOutcomeV1) -> Bool {
        if case .completed = outcome { return true }
        return false
    }

    private static func seed(for launch: WorkflowLaunchSnapshotV1) throws -> StableDigest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return StableDigest.fingerprint(
            domain: "dynamic-workflow-prefix-seed.v1",
            components: [
                Data(WorkflowScriptABI.v1.description.utf8),
                Data((launch.args?.fingerprint.rawValue ?? "").utf8),
                try encoder.encode(launch.defaultModelPolicy),
                Data(launch.toolPolicyDigest.rawValue.utf8),
                Data(launch.policySnapshotDigest.rawValue.utf8),
                try encoder.encode(launch.capabilityCeiling),
            ]
        )
    }

    private static func stableUUID(domain: String, components: [String]) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(domain.utf8))
        for component in components {
            var count = UInt64(component.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
            hasher.update(data: Data(component.utf8))
        }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { raw in
            let tuple = raw.load(as: uuid_t.self)
            return UUID(uuid: tuple)
        }
    }
}
