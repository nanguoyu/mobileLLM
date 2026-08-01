// SPDX-License-Identifier: MIT

import Foundation

/// Provider-neutral location of artifact bytes without embedding an absolute path or body.
public struct ArtifactLocator: Hashable, Codable, Sendable {
    /// Locator family.
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        /// A root-confined relative path owned by the app artifact store.
        case managedRelativePath
        /// An opaque handle interpreted by a locally registered provider.
        case providerOpaque
    }

    /// Locator family.
    public let kind: Kind
    /// Root-relative path or opaque provider handle.
    public let value: String
    /// Provider namespace required for opaque provider handles.
    public let providerID: String?

    /// Creates a validated non-secret artifact locator.
    public init(kind: Kind, value: String, providerID: String? = nil) throws {
        guard AgentWireValidation.isNonblankControlFree(value, maximumLength: 2_048) else {
            throw AgentContractError.invalidArtifactReference("invalid locator value")
        }
        switch kind {
        case .managedRelativePath:
            let components = value.split(separator: "/", omittingEmptySubsequences: false)
            guard !value.hasPrefix("/"), !value.hasPrefix("~"),
                  !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }),
                  providerID == nil
            else { throw AgentContractError.invalidArtifactReference("unconfined artifact path") }
        case .providerOpaque:
            guard let providerID,
                  AgentWireValidation.isNonblankControlFree(providerID, maximumLength: 256)
            else {
                throw AgentContractError.invalidArtifactReference("opaque locator requires provider")
            }
        }
        self.kind = kind
        self.value = value
        self.providerID = providerID
    }

    /// Decodes and revalidates confinement and provider requirements.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(Kind.self, forKey: .kind),
                value: container.decode(String.self, forKey: .value),
                providerID: container.decodeIfPresent(String.self, forKey: .providerID)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value, providerID
    }
}

/// Retention policy applied by the owning artifact store.
public enum ArtifactRetentionPolicy: String, CaseIterable, Hashable, Codable, Sendable {
    /// Retain while the owning run exists.
    case run
    /// Retain while the owning conversation or another durable reference exists.
    case conversation
    /// Retain until the user explicitly removes an exported or saved artifact.
    case userManaged
    /// Retain only for a bounded transient operation.
    case transient
}

/// Current integrity state of referenced artifact bytes.
public enum ArtifactIntegrityStatus: String, CaseIterable, Hashable, Codable, Sendable {
    /// Content hash and byte count were verified.
    case verified
    /// Verification has not yet completed.
    case unverified
    /// Content exists but failed integrity verification.
    case corrupt
    /// Referenced content is unavailable.
    case missing
}

/// Durable provenance for a provider-neutral artifact reference.
public struct ArtifactProvenance: Hashable, Codable, Sendable {
    /// Run that created or first accepted the artifact.
    public let runID: AgentRunID?
    /// Stable step that created the artifact.
    public let stepID: AgentStepID?
    /// Tool invocation that created the artifact.
    public let invocationID: ToolInvocationID?
    /// External-operation plan under which content entered or left a boundary.
    public let externalOperationFingerprint: StableDigest?
    /// Stable provider namespace, when content came from an adapter.
    public let providerID: String?

    /// Creates provenance without requiring a run for preaccepted user attachments.
    public init(
        runID: AgentRunID? = nil,
        stepID: AgentStepID? = nil,
        invocationID: ToolInvocationID? = nil,
        externalOperationFingerprint: StableDigest? = nil,
        providerID: String? = nil
    ) throws {
        if stepID != nil || invocationID != nil {
            guard runID != nil else {
                throw AgentContractError.invalidArtifactReference("step provenance requires a run")
            }
        }
        if let providerID, !AgentWireValidation.isNonblankControlFree(providerID, maximumLength: 256) {
            throw AgentContractError.invalidArtifactReference("empty provider identity")
        }
        self.runID = runID
        self.stepID = stepID
        self.invocationID = invocationID
        self.externalOperationFingerprint = externalOperationFingerprint
        self.providerID = providerID
    }

    /// Decodes and revalidates provenance relationships.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                runID: container.decodeIfPresent(AgentRunID.self, forKey: .runID),
                stepID: container.decodeIfPresent(AgentStepID.self, forKey: .stepID),
                invocationID: container.decodeIfPresent(ToolInvocationID.self, forKey: .invocationID),
                externalOperationFingerprint: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .externalOperationFingerprint
                ),
                providerID: container.decodeIfPresent(String.self, forKey: .providerID)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runID, stepID, invocationID, externalOperationFingerprint, providerID
    }
}

/// Content-addressed artifact metadata shared by runtime, tools, models, and sandbox adapters.
public struct ArtifactReference: Hashable, Codable, Sendable {
    /// Stable artifact identity.
    public let id: ArtifactID
    /// SHA-256 digest of complete artifact bytes.
    public let contentDigest: StableDigest
    /// Exact artifact byte count.
    public let byteCount: UInt64
    /// Lowercase MIME type without parameters.
    public let mimeType: String
    /// Optional stable semantic type interpreted by local presentation policy.
    public let semanticType: String?
    /// Provenance without embedding external content.
    public let provenance: ArtifactProvenance
    /// Deterministic creation timestamp.
    public let createdAt: AgentTimestamp
    /// Retention policy applied by the artifact store.
    public let retentionPolicy: ArtifactRetentionPolicy
    /// Root-confined or opaque content locator.
    public let locator: ArtifactLocator
    /// Sensitivity of the artifact body.
    public let sensitivity: RedactionClassification
    /// Current content-integrity state.
    public let integrityStatus: ArtifactIntegrityStatus

    /// Creates validated artifact metadata; secret-classified content is prohibited.
    public init(
        id: ArtifactID,
        contentDigest: StableDigest,
        byteCount: UInt64,
        mimeType: String,
        semanticType: String? = nil,
        provenance: ArtifactProvenance,
        createdAt: AgentTimestamp,
        retentionPolicy: ArtifactRetentionPolicy,
        locator: ArtifactLocator,
        sensitivity: RedactionClassification,
        integrityStatus: ArtifactIntegrityStatus
    ) throws {
        guard AgentWireValidation.isMIMEType(mimeType)
        else { throw AgentContractError.invalidArtifactReference("invalid MIME type") }
        guard sensitivity != .secret else {
            throw AgentContractError.invalidArtifactReference("secrets cannot be artifacts")
        }
        if let semanticType,
           !AgentWireValidation.isNonblankControlFree(semanticType, maximumLength: 128)
        {
            throw AgentContractError.invalidArtifactReference("invalid semantic type")
        }
        self.id = id
        self.contentDigest = contentDigest
        self.byteCount = byteCount
        self.mimeType = mimeType
        self.semanticType = semanticType
        self.provenance = provenance
        self.createdAt = createdAt
        self.retentionPolicy = retentionPolicy
        self.locator = locator
        self.sensitivity = sensitivity
        self.integrityStatus = integrityStatus
    }

    /// Decodes and revalidates all artifact representation rules.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                contentDigest: container.decode(StableDigest.self, forKey: .contentDigest),
                byteCount: container.decode(UInt64.self, forKey: .byteCount),
                mimeType: container.decode(String.self, forKey: .mimeType),
                semanticType: container.decodeIfPresent(String.self, forKey: .semanticType),
                provenance: container.decode(ArtifactProvenance.self, forKey: .provenance),
                createdAt: container.decode(AgentTimestamp.self, forKey: .createdAt),
                retentionPolicy: container.decode(ArtifactRetentionPolicy.self, forKey: .retentionPolicy),
                locator: container.decode(ArtifactLocator.self, forKey: .locator),
                sensitivity: container.decode(RedactionClassification.self, forKey: .sensitivity),
                integrityStatus: container.decode(ArtifactIntegrityStatus.self, forKey: .integrityStatus)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, contentDigest, byteCount, mimeType, semanticType, provenance, createdAt
        case retentionPolicy, locator, sensitivity, integrityStatus
    }
}

/// Stable failure category controlling retry, recovery, and user presentation policy.
public enum AgentFailureClassification: String, CaseIterable, Hashable, Codable, Sendable {
    /// A bounded retry may succeed without changing authority or inputs.
    case transient
    /// Retrying unchanged input cannot succeed.
    case permanent
    /// Required user, system, or agent authorization is absent.
    case permissionRelated
    /// A hard resource budget prevented or ended work.
    case budgetRelated
    /// Explicit cancellation ended the operation.
    case cancelled
    /// A pinned protocol, model, tool, schema, or dependency is incompatible.
    case incompatible
    /// An external side effect may have occurred and requires reconciliation.
    case potentiallySideEffecting
}

/// Whether a failed operation may have crossed an external side-effect boundary.
public enum ExternalEffectDisposition: String, CaseIterable, Hashable, Codable, Sendable {
    /// No external effect was possible.
    case notApplicable
    /// The adapter confirmed that no effect occurred.
    case confirmedNone
    /// The adapter confirmed the effect completed.
    case confirmedApplied
    /// The effect outcome cannot be proven and must not be replayed automatically.
    case uncertain
}

/// User action required before a failed or blocked operation may proceed.
public enum AgentRequiredUserAction: String, CaseIterable, Hashable, Codable, Sendable {
    /// No user action is required.
    case none
    /// Review and approve a newly prepared external operation.
    case approve
    /// Supply additional structured input.
    case respond
    /// Reconcile an uncertain external result.
    case reconcile
    /// Select or restore a compatible model, tool, skill, or provider.
    case restoreDependency
    /// Change a system permission manually.
    case updateSystemPermission
}

/// Bounded retry advice attached to a typed failure.
public struct AgentRetryAdvice: Hashable, Codable, Sendable {
    /// Whether unchanged input may be retried automatically.
    public let automaticallyRetryable: Bool
    /// Maximum additional automatic attempts.
    public let maximumAdditionalAttempts: UInt16
    /// Minimum delay before the next attempt.
    public let delayMilliseconds: UInt64

    /// Creates internally consistent retry advice.
    public init(
        automaticallyRetryable: Bool,
        maximumAdditionalAttempts: UInt16 = 0,
        delayMilliseconds: UInt64 = 0
    ) throws {
        guard automaticallyRetryable
                ? maximumAdditionalAttempts > 0
                : maximumAdditionalAttempts == 0 && delayMilliseconds == 0
        else { throw AgentContractError.invalidName("retry advice") }
        self.automaticallyRetryable = automaticallyRetryable
        self.maximumAdditionalAttempts = maximumAdditionalAttempts
        self.delayMilliseconds = delayMilliseconds
    }

    /// Retry advice that forbids automatic retry.
    public static let never = try! Self(automaticallyRetryable: false)

    /// Decodes and revalidates retry advice.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                automaticallyRetryable: container.decode(Bool.self, forKey: .automaticallyRetryable),
                maximumAdditionalAttempts: container.decode(UInt16.self, forKey: .maximumAdditionalAttempts),
                delayMilliseconds: container.decode(UInt64.self, forKey: .delayMilliseconds)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case automaticallyRetryable, maximumAdditionalAttempts, delayMilliseconds
    }
}

/// A provider-neutral typed failure with retry, uncertainty, and redaction semantics.
public struct AgentFailure: Hashable, Codable, Sendable {
    /// Stable namespaced machine-readable failure code.
    public let code: String
    /// High-level failure classification.
    public let classification: AgentFailureClassification
    /// Safe user-visible summary containing no secret or raw external body.
    public let safeMessage: String
    /// Bounded retry advice.
    public let retryAdvice: AgentRetryAdvice
    /// External side-effect disposition.
    public let externalEffect: ExternalEffectDisposition
    /// User action required to make progress.
    public let requiredUserAction: AgentRequiredUserAction
    /// Redacted structured diagnostic details.
    public let details: [String: String]
    /// Metadata proving which original fields were redacted.
    public let redaction: RedactionMetadata

    /// Creates an internally consistent typed failure.
    public init(
        code: String,
        classification: AgentFailureClassification,
        safeMessage: String,
        retryAdvice: AgentRetryAdvice,
        externalEffect: ExternalEffectDisposition,
        requiredUserAction: AgentRequiredUserAction,
        details: [String: String] = [:],
        redaction: RedactionMetadata
    ) throws {
        let detailBytes = details.reduce(into: 0) { total, item in
            let addition = item.key.utf8.count + item.value.utf8.count
            total = total > 65_536 - min(addition, 65_536) ? 65_537 : total + addition
        }
        guard Self.validCode(code),
              AgentWireValidation.isNonblankControlFree(safeMessage, maximumLength: 2_048),
              details.count <= 64,
              detailBytes <= 65_536,
              details.keys.allSatisfy({
                  AgentWireValidation.isNonblankControlFree($0, maximumLength: 128)
              }),
              details.values.allSatisfy({
                  $0.utf8.count <= 2_048
                      && $0.unicodeScalars.allSatisfy {
                          !CharacterSet.controlCharacters.contains($0)
                      }
              })
        else { throw AgentContractError.invalidName("typed failure") }
        guard (classification == .potentiallySideEffecting) == (externalEffect == .uncertain) else {
            throw AgentContractError.invalidName("uncertainty classification mismatch")
        }
        if externalEffect == .uncertain {
            guard classification == .potentiallySideEffecting,
                  !retryAdvice.automaticallyRetryable,
                  requiredUserAction == .reconcile
            else { throw AgentContractError.invalidName("uncertain failure semantics") }
        }
        if retryAdvice.automaticallyRetryable {
            guard classification == .transient, externalEffect != .uncertain else {
                throw AgentContractError.invalidName("unsafe failure retry")
            }
        }
        self.code = code
        self.classification = classification
        self.safeMessage = safeMessage
        self.retryAdvice = retryAdvice
        self.externalEffect = externalEffect
        self.requiredUserAction = requiredUserAction
        self.details = details
        self.redaction = redaction
    }

    /// Decodes and revalidates retry and uncertainty cross-field invariants.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                code: container.decode(String.self, forKey: .code),
                classification: container.decode(AgentFailureClassification.self, forKey: .classification),
                safeMessage: container.decode(String.self, forKey: .safeMessage),
                retryAdvice: container.decode(AgentRetryAdvice.self, forKey: .retryAdvice),
                externalEffect: container.decode(ExternalEffectDisposition.self, forKey: .externalEffect),
                requiredUserAction: container.decode(
                    AgentRequiredUserAction.self,
                    forKey: .requiredUserAction
                ),
                details: container.decode([String: String].self, forKey: .details),
                redaction: container.decode(RedactionMetadata.self, forKey: .redaction)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case code, classification, safeMessage, retryAdvice, externalEffect, requiredUserAction
        case details, redaction
    }

    private static func validCode(_ code: String) -> Bool {
        AgentWireValidation.isLowercaseNamespace(code, maximumLength: 128)
    }
}
