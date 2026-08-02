// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public struct ValidatedToolCall: Hashable, Codable, Sendable {
    public let proposedCall: ProposedToolCall
    public let descriptor: AgentToolDescriptor
    public let argumentValidation: ToolArgumentValidation
    public let executionFingerprint: StableDigest
}

public struct ValidatedToolBatch: Hashable, Codable, Sendable, RandomAccessCollection {
    public let values: [ValidatedToolCall]

    public var startIndex: Int { values.startIndex }
    public var endIndex: Int { values.endIndex }
    public subscript(position: Int) -> ValidatedToolCall { values[position] }
}

public enum ToolBatchValidationError: Error, Hashable, Sendable {
    case emptyBatch
    case callBudgetExceeded
    case duplicateInvocationID
    case duplicateCallFingerprint
    case previouslyExecutedCall
    case ambiguousAdvertisedTool
    case unadvertisedTool(AgentToolLogicalID)
    case invalidArguments(ToolInvocationID)
}

/// Validates the complete proposed batch before the controller is allowed to prepare or execute its
/// first item. The returned order is exactly the model-provided order.
public struct ToolBatchValidator: Sendable {
    public init() {}

    public func validate(
        proposedCalls: [ProposedToolCall],
        advertisedDescriptors: [AgentToolDescriptor],
        maximumCalls: UInt16,
        maximumArgumentBytes: UInt64 = 256 * 1_024,
        previouslyExecutedFingerprints: Set<StableDigest> = []
    ) throws -> ValidatedToolBatch {
        guard !proposedCalls.isEmpty else { throw ToolBatchValidationError.emptyBatch }
        guard maximumCalls > 0, proposedCalls.count <= Int(maximumCalls) else {
            throw ToolBatchValidationError.callBudgetExceeded
        }
        guard maximumArgumentBytes > 0,
              maximumArgumentBytes <= UInt64(CanonicalJSON.maximumBytes)
        else { throw ToolBatchValidationError.callBudgetExceeded }
        guard Set(proposedCalls.map(\.invocationID)).count == proposedCalls.count else {
            throw ToolBatchValidationError.duplicateInvocationID
        }
        guard Set(advertisedDescriptors.map(\.id.logicalID)).count == advertisedDescriptors.count
        else { throw ToolBatchValidationError.ambiguousAdvertisedTool }
        let descriptors = Dictionary(
            uniqueKeysWithValues: advertisedDescriptors.map { ($0.id.logicalID, $0) }
        )
        var batchFingerprints: Set<StableDigest> = []
        var validated: [ValidatedToolCall] = []
        validated.reserveCapacity(proposedCalls.count)
        for call in proposedCalls {
            guard call.arguments.data.count <= maximumArgumentBytes else {
                throw ToolBatchValidationError.invalidArguments(call.invocationID)
            }
            guard let descriptor = descriptors[call.toolID] else {
                throw ToolBatchValidationError.unadvertisedTool(call.toolID)
            }
            let instance: JSONValue
            do {
                instance = try AgentWireDecoder.decode(
                    JSONValue.self,
                    from: call.arguments.data,
                    limits: .inlineValue
                )
            } catch {
                throw ToolBatchValidationError.invalidArguments(call.invocationID)
            }
            let validation: ToolArgumentValidation
            switch descriptor.inputSchema.enforcement {
            case .fullyEnforced:
                guard (try? descriptor.inputSchema.validates(instance: instance)) == true else {
                    throw ToolBatchValidationError.invalidArguments(call.invocationID)
                }
                validation = .fullyValidated
            case .partiallyEnforced:
                validation = .partiallyValidatedConservative
            }
            let fingerprint = StableDigest.fingerprint(
                domain: "tool-execution-fingerprint.v1",
                components: [
                    Data(descriptor.id.description.utf8),
                    Data(call.arguments.fingerprint.rawValue.utf8),
                    Data(descriptor.effects.map(\.rawValue).joined(separator: "\u{0}").utf8),
                ]
            )
            guard batchFingerprints.insert(fingerprint).inserted else {
                throw ToolBatchValidationError.duplicateCallFingerprint
            }
            guard !previouslyExecutedFingerprints.contains(fingerprint) else {
                throw ToolBatchValidationError.previouslyExecutedCall
            }
            validated.append(
                ValidatedToolCall(
                    proposedCall: call,
                    descriptor: descriptor,
                    argumentValidation: validation,
                    executionFingerprint: fingerprint
                )
            )
        }
        return ValidatedToolBatch(values: validated)
    }
}
