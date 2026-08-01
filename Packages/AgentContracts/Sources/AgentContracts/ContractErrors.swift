// SPDX-License-Identifier: MIT

import Foundation

/// Validation failures raised by pure AgentContracts constructors and reducers.
public enum AgentContractError: Error, Equatable, Sendable {
    /// A Foundation timestamp was non-finite or outside the Int64 millisecond range.
    case invalidTimestamp
    /// Redaction metadata was noncanonical, unbounded, or retained a secret digest.
    case invalidRedactionMetadata
    /// A payload type declared an invalid schema identifier or current version range.
    case invalidSchemaDeclaration(String)
    /// A semantic-version string or identifier did not satisfy Semantic Versioning 2.0.0.
    case invalidSemanticVersion
    /// A wire envelope used an incompatible protocol major version.
    case unsupportedProtocolVersion(received: SemanticVersion, supportedMajor: UInt)
    /// A wire envelope used a payload version outside the supported range.
    case unsupportedPayloadVersion(received: UInt16, supported: ClosedRange<UInt16>)
    /// A wire envelope claimed the wrong stable schema identity.
    case schemaMismatch(expected: String, received: String)
    /// A SHA-256 digest was not canonical lowercase hexadecimal.
    case invalidDigest(String)
    /// JSON attempted to carry NaN or an infinite value.
    case nonFiniteJSONNumber
    /// An integral JSON value exceeded the exact interoperable I-JSON range.
    case integerOutsideIJSONRange
    /// JSON bytes were valid but not in deterministic canonical form.
    case nonCanonicalJSON
    /// Untrusted wire data exceeded a pre-decode structural or byte limit.
    case wireLimitExceeded(String)
    /// A stable name or namespace was empty or malformed.
    case invalidName(String)
    /// A capability grant contained authority outside its ceiling.
    case capabilityEscalation([AgentCapability])
    /// A strict child grant was equal to rather than narrower than its parent.
    case capabilityNotStrictlyAttenuated
    /// A requested usage or reservation exceeded one hard budget dimension.
    case budgetExceeded(dimension: BudgetDimension, limit: UInt64, requested: UInt64)
    /// Unsigned usage arithmetic overflowed and therefore failed closed.
    case arithmeticOverflow(dimension: BudgetDimension)
    /// A reservation identifier did not exist in the ledger snapshot.
    case reservationNotFound(BudgetReservationID)
    /// An idempotent reservation identifier was reused with different quantities.
    case conflictingReservation(BudgetReservationID)
    /// Settled usage exceeded the maximum quantities reserved before work.
    case usageExceedsReservation(BudgetReservationID)
    /// An external-operation plan failed structural validation.
    case invalidExternalOperationPlan(String)
    /// Authorization was denied or otherwise did not grant execution.
    case authorizationDenied
    /// Authorization had expired at the explicitly supplied evaluation time.
    case authorizationExpired
    /// Authorization, plan, payload, run, or grant fingerprints did not match.
    case authorizationBindingMismatch(String)
    /// An artifact reference was invalid or violated representation policy.
    case invalidArtifactReference(String)
    /// A JSON Schema document exceeded a contract limit or used a forbidden reference.
    case invalidJSONSchema(String)
    /// A command was internally inconsistent with its target request or run.
    case invalidCommand(String)
    /// An event sequence violated run, cursor, ordering, state-version, or terminal invariants.
    case invalidEventSequence(String)
    /// A run status paired an impossible state and terminal outcome.
    case invalidRunStatus(String)
}

extension AgentContractError: LocalizedError {
    /// A stable, non-sensitive explanation suitable for diagnostics.
    public var errorDescription: String? {
        switch self {
        case .invalidTimestamp:
            "Timestamp is non-finite or outside the supported millisecond range"
        case .invalidRedactionMetadata:
            "Invalid or unsafe redaction metadata"
        case .invalidSchemaDeclaration(let schemaID):
            "Invalid contract schema declaration: \(schemaID)"
        case .invalidSemanticVersion:
            "Invalid semantic version"
        case .unsupportedProtocolVersion(let received, let supportedMajor):
            "Unsupported protocol version \(received); supported major is \(supportedMajor)"
        case .unsupportedPayloadVersion(let received, let supported):
            "Unsupported payload version \(received); supported range is \(supported)"
        case .schemaMismatch(let expected, let received):
            "Envelope schema mismatch; expected \(expected), received \(received)"
        case .invalidDigest:
            "Invalid SHA-256 digest"
        case .nonFiniteJSONNumber:
            "JSON numbers must be finite"
        case .integerOutsideIJSONRange:
            "Integral JSON values must remain inside the exact I-JSON range"
        case .nonCanonicalJSON:
            "JSON must use the canonical representation"
        case .wireLimitExceeded(let reason):
            "Untrusted wire data exceeded a limit: \(reason)"
        case .invalidName(let field):
            "Invalid stable name: \(field)"
        case .capabilityEscalation:
            "Capability grant exceeds its immutable ceiling"
        case .capabilityNotStrictlyAttenuated:
            "Child capability authority must be a strict subset"
        case .budgetExceeded(let dimension, let limit, let requested):
            "Budget \(dimension.rawValue) exceeded: limit \(limit), requested \(requested)"
        case .arithmeticOverflow(let dimension):
            "Usage arithmetic overflowed for \(dimension.rawValue)"
        case .reservationNotFound:
            "Budget reservation was not found"
        case .conflictingReservation:
            "Budget reservation identifier was reused with different quantities"
        case .usageExceedsReservation:
            "Settled usage exceeds the prior reservation"
        case .invalidExternalOperationPlan(let reason):
            "Invalid external-operation plan: \(reason)"
        case .authorizationDenied:
            "External-operation authorization was not granted"
        case .authorizationExpired:
            "External-operation authorization expired"
        case .authorizationBindingMismatch(let reason):
            "External-operation authorization mismatch: \(reason)"
        case .invalidArtifactReference(let reason):
            "Invalid artifact reference: \(reason)"
        case .invalidJSONSchema(let reason):
            "Invalid JSON Schema contract: \(reason)"
        case .invalidCommand(let reason):
            "Invalid agent command: \(reason)"
        case .invalidEventSequence(let reason):
            "Invalid event sequence: \(reason)"
        case .invalidRunStatus(let reason):
            "Invalid run status: \(reason)"
        }
    }
}
