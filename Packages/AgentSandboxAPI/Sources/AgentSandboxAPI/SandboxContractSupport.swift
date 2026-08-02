// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Fail-closed errors produced by sandbox contract validation and provider negotiation.
public enum AgentSandboxAPIError: Error, Equatable, Hashable, Sendable {
    /// A descriptor, feature, audit field, or other bounded wire value is malformed.
    case invalidValue(String)
    /// The locally registered provider identity does not match the provider's claim.
    case providerIdentityMismatch
    /// The provider descriptor no longer matches the fingerprint pinned by local policy.
    case descriptorFingerprintMismatch
    /// The provider's trust revision no longer matches the locally registered revision.
    case trustRevisionMismatch
    /// No protocol version is supported by all parties.
    case incompatibleProtocol
    /// A capability report is not bound to the descriptor that produced it.
    case capabilityReportBindingMismatch
    /// A negotiated capability value is not the intersection of policy and provider claims.
    case negotiatedCapabilityMismatch
    /// A request attempted to widen immutable authority or budget.
    case authorityOrBudgetExpansion
    /// A request is not bound to its negotiated provider or authorization decision.
    case requestBindingMismatch
    /// One idempotency identity was reused for a different request or command.
    case idempotencyConflict
    /// The requested durable execution does not exist.
    case executionNotFound
    /// A command targeted an obsolete execution state version.
    case staleCommand
    /// A cursor does not resolve to the claimed event in the execution journal.
    case invalidCursor
    /// A replayed event sequence or its hash chain is invalid.
    case invalidEventChain
    /// A command attempted to mutate a terminal execution.
    case terminalExecution
}

extension AgentSandboxAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidValue(let value): "Invalid sandbox contract value: \(value)"
        case .providerIdentityMismatch: "Sandbox provider identity does not match local policy."
        case .descriptorFingerprintMismatch: "Sandbox provider descriptor fingerprint changed."
        case .trustRevisionMismatch: "Sandbox provider trust revision changed."
        case .incompatibleProtocol: "No compatible sandbox protocol version is available."
        case .capabilityReportBindingMismatch: "Sandbox capability report is not descriptor-bound."
        case .negotiatedCapabilityMismatch: "Sandbox capabilities do not match local negotiation."
        case .authorityOrBudgetExpansion: "Sandbox request widened authority or budget."
        case .requestBindingMismatch: "Sandbox request authorization binding is invalid."
        case .idempotencyConflict: "Idempotency identity was reused with different content."
        case .executionNotFound: "Sandbox execution was not found."
        case .staleCommand: "Sandbox command targeted a stale state version."
        case .invalidCursor: "Sandbox event cursor is invalid."
        case .invalidEventChain: "Sandbox event chain is invalid."
        case .terminalExecution: "Sandbox execution is already terminal."
        }
    }
}

enum SandboxContractValidation {
    static func namespace(_ value: String, maximumUTF8Bytes: Int = 128) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              value.first?.isASCIIAlphaNumeric == true,
              value.last?.isASCIIAlphaNumeric == true
        else { return false }

        var previousSeparator = false
        for scalar in value.unicodeScalars {
            let isAlphanumeric = scalar.isLowercaseASCIIAlphaNumeric
            let isSeparator = scalar.value == 0x2D || scalar.value == 0x2E || scalar.value == 0x5F
            guard isAlphanumeric || isSeparator, !(previousSeparator && isSeparator) else {
                return false
            }
            previousSeparator = isSeparator
        }
        return true
    }

    static func safeText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumUTF8Bytes
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func canonicalVersions(_ versions: some Sequence<SemanticVersion>) -> [SemanticVersion] {
        Array(Set(versions)).sorted()
    }

    static func budgetIntersection(_ local: AgentBudget, _ reported: AgentBudget) throws -> AgentBudget {
        guard local.memoryPressureResponse == reported.memoryPressureResponse else {
            throw AgentSandboxAPIError.negotiatedCapabilityMismatch
        }
        var values: [BudgetDimension: UInt64] = [:]
        for dimension in BudgetDimension.allCases {
            values[dimension] = min(local.limits[dimension], reported.limits[dimension])
        }
        return try AgentBudget(
            limits: BudgetQuantities(values),
            maximumThermalState: min(local.maximumThermalState, reported.maximumThermalState),
            memoryPressureResponse: local.memoryPressureResponse
        )
    }

    static func authorityIntersection(
        _ local: AgentAuthorityScope,
        _ reported: AgentAuthorityScope
    ) throws -> AgentAuthorityScope {
        let reportedConstraints = Dictionary(uniqueKeysWithValues: reported.constraints.map { ($0.key, $0) })
        let constraints: [AgentAuthorityConstraint] = try local.constraints.compactMap { localConstraint in
            guard let reportedConstraint = reportedConstraints[localConstraint.key] else { return nil }
            let values = Set(localConstraint.allowedValues).intersection(
                Set(reportedConstraint.allowedValues)
            )
            guard !values.isEmpty else { return nil }
            return try AgentAuthorityConstraint(key: localConstraint.key, allowedValues: values)
        }
        let capabilities = Set(local.capabilities.values).intersection(
            Set(reported.capabilities.values)
        )
        let destinations = Set(local.destinations).intersection(Set(reported.destinations))
        let dataCategories = Set(local.dataCategories).intersection(Set(reported.dataCategories))
        let artifactIDs = Set(local.artifactIDs).intersection(Set(reported.artifactIDs))
        let secretIDs = Set(local.secretReferenceIDs).intersection(Set(reported.secretReferenceIDs))
        let workspaceIDs = Set(local.workspaceIDs).intersection(Set(reported.workspaceIDs))
        let checkpointIDs = Set(local.checkpointIDs).intersection(Set(reported.checkpointIDs))
        return try AgentAuthorityScope(
            capabilities: AgentCapabilitySet(capabilities),
            destinations: destinations,
            dataCategories: dataCategories,
            artifactIDs: artifactIDs,
            secretReferenceIDs: secretIDs,
            workspaceIDs: workspaceIDs,
            checkpointIDs: checkpointIDs,
            constraints: constraints
        )
    }

    static func fingerprint<T: Encodable>(domain: String, value: T) throws -> StableDigest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        let json = try AgentWireDecoder.decode(
            JSONValue.self,
            from: encoded,
            limits: .contractEnvelope
        )
        let canonical = try json.canonicalData()
        return .fingerprint(domain: domain, components: [canonical])
    }

    static func rethrowAsCorruption<Value>(
        _ decoder: Decoder,
        _ operation: () throws -> Value
    ) throws -> Value {
        do { return try operation() }
        catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first?.isLowercaseASCIIAlphaNumeric == true
    }
}

private extension Unicode.Scalar {
    var isLowercaseASCIIAlphaNumeric: Bool {
        (0x30 ... 0x39).contains(value) || (0x61 ... 0x7A).contains(value)
    }
}
