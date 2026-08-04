// SPDX-License-Identifier: MIT

import Foundation

/// The adapter family preparing one boundary-crossing operation.
public enum ExternalOperationKind: String, CaseIterable, Hashable, Codable, Sendable {
    /// A local operation that crosses no protected boundary.
    case localPure
    /// A tool invocation.
    case tool
    /// MCP discovery, refresh, or invocation.
    case mcp
    /// A future online model-provider request.
    case modelProvider
    /// Private user or system data access.
    case privateData
    /// User-selected or security-scoped file access.
    case file
    /// Artifact export outside the confined store.
    case artifactExport
    /// A future injected sandbox operation.
    case sandbox
}

/// A normalized exact destination or one element of a bounded redirect/fallback set.
public struct ExternalDestination: Hashable, Codable, Sendable, Comparable {
    /// The bounded "any public https host" destination used by the webpage-reader adapter for
    /// user-supplied links. Only https is covered; the adapter's SSRF guards still reject local,
    /// private, loopback, and literal-IP hosts before a plan is built.
    public static let anyHTTPSNetworkEndpoint = "https://*"

    /// The kind of boundary being addressed.
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        /// A scheme, host, and optional port.
        case networkEndpoint
        /// A stable MCP server identity rather than its mutable URL.
        case mcpServer
        /// A provider and model endpoint.
        case modelProvider
        /// A private-data store or collection.
        case privateDataStore
        /// A security-scoped file or directory reference.
        case fileReference
        /// An export destination selected by the user.
        case artifactExport
        /// An injected sandbox-provider boundary.
        case sandboxProvider
    }

    /// Destination category.
    public let kind: Kind

    /// Canonical adapter-defined identity matched immediately before external I/O.
    public let normalizedIdentity: String

    /// Creates an exact destination matcher value.
    public init(kind: Kind, normalizedIdentity: String) throws {
        guard AgentWireValidation.isNonblankControlFree(normalizedIdentity, maximumLength: 2_048) else {
            throw AgentContractError.invalidExternalOperationPlan("invalid destination identity")
        }
        self.kind = kind
        self.normalizedIdentity = normalizedIdentity
    }

    /// Whether this destination (or its https wildcard) authorizes `candidate`. Exact identities always
    /// match; only the network-endpoint `https://*` wildcard covers a different concrete https host.
    public func covers(_ candidate: ExternalDestination) -> Bool {
        if self == candidate { return true }
        guard kind == .networkEndpoint, candidate.kind == .networkEndpoint else { return false }
        return normalizedIdentity == Self.anyHTTPSNetworkEndpoint
            && candidate.normalizedIdentity.hasPrefix("https://")
    }

    /// Decodes and validates a normalized destination.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(Kind.self, forKey: .kind),
                normalizedIdentity: container.decode(String.self, forKey: .normalizedIdentity)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case normalizedIdentity
    }

    /// Orders destinations by kind and normalized identity.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.normalizedIdentity < rhs.normalizedIdentity
    }
}

/// A stable data-category label used in approval previews and egress policy.
public struct AgentDataCategory: Hashable, Codable, Sendable, Comparable {
    /// Lowercase namespaced category identifier.
    public let rawValue: String

    /// Creates a nonempty bounded data-category label.
    public init(rawValue: String) throws {
        guard AgentWireValidation.isLowercaseNamespace(rawValue, maximumLength: 128) else {
            throw AgentContractError.invalidName("data category")
        }
        self.rawValue = rawValue
    }

    /// Orders categories by stable identity.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Decodes one category string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(rawValue: encoded)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid data category")
        }
    }

    /// Encodes one category string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Retry semantics frozen into an external-operation plan.
public struct ExternalRetryPolicy: Hashable, Codable, Sendable {
    /// Retry classification.
    public enum Kind: String, Hashable, Codable, Sendable {
        /// Automatic retry is forbidden.
        case never
        /// A bounded exponential backoff may be applied.
        case boundedExponential
    }

    /// Retry classification.
    public let kind: Kind

    /// Maximum total attempts including the initial attempt.
    public let maximumAttempts: UInt16

    /// Initial backoff delay in milliseconds.
    public let baseDelayMilliseconds: UInt64

    /// Maximum backoff delay in milliseconds.
    public let maximumDelayMilliseconds: UInt64

    /// Whether deterministic jitter supplied by runtime policy may be applied.
    public let allowsJitter: Bool

    /// Creates a validated retry policy.
    public init(
        kind: Kind,
        maximumAttempts: UInt16,
        baseDelayMilliseconds: UInt64 = 0,
        maximumDelayMilliseconds: UInt64 = 0,
        allowsJitter: Bool = false
    ) throws {
        switch kind {
        case .never:
            guard maximumAttempts == 1,
                  baseDelayMilliseconds == 0,
                  maximumDelayMilliseconds == 0,
                  !allowsJitter
            else { throw AgentContractError.invalidExternalOperationPlan("invalid no-retry policy") }
        case .boundedExponential:
            guard maximumAttempts >= 2,
                  baseDelayMilliseconds > 0,
                  maximumDelayMilliseconds >= baseDelayMilliseconds
            else { throw AgentContractError.invalidExternalOperationPlan("invalid bounded retry policy") }
        }
        self.kind = kind
        self.maximumAttempts = maximumAttempts
        self.baseDelayMilliseconds = baseDelayMilliseconds
        self.maximumDelayMilliseconds = maximumDelayMilliseconds
        self.allowsJitter = allowsJitter
    }

    /// A policy that permits one attempt and no automatic retry.
    public static var never: Self {
        try! Self(kind: .never, maximumAttempts: 1)
    }

    /// Decodes and revalidates retry invariants.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(Kind.self, forKey: .kind),
                maximumAttempts: container.decode(UInt16.self, forKey: .maximumAttempts),
                baseDelayMilliseconds: container.decode(UInt64.self, forKey: .baseDelayMilliseconds),
                maximumDelayMilliseconds: container.decode(UInt64.self, forKey: .maximumDelayMilliseconds),
                allowsJitter: container.decode(Bool.self, forKey: .allowsJitter)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, maximumAttempts, baseDelayMilliseconds, maximumDelayMilliseconds, allowsJitter
    }
}

/// Idempotency and reconciliation guarantees frozen into an operation plan.
public enum ExternalIdempotency: String, CaseIterable, Hashable, Codable, Sendable {
    /// The operation is a pure read and has no external side effect.
    case pureRead
    /// Repeating the operation is safe only with the bound idempotency key.
    case idempotencyKeyRequired
    /// A reliable provider reconciliation operation is available.
    case reconciliationAvailable
    /// Repetition is unsafe after intent without a confirmed outcome.
    case nonIdempotent
}

/// A secret-free, strongly typed digest sent unchanged on every attempt of one idempotent write.
public struct ExternalIdempotencyKey: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Digest-form key safe to persist in plans and receipts.
    public let digest: StableDigest

    /// Creates a key from an already domain-separated digest.
    public init(digest: StableDigest) { self.digest = digest }

    /// Derives a non-secret key from stable, length-delimited request material.
    public static func derive(components: [Data]) -> Self {
        Self(digest: .fingerprint(domain: "external-idempotency-key.v1", components: components))
    }

    /// Canonical key representation.
    public var description: String { digest.rawValue }
}

/// An immutable prepare-stage description of the maximum operation that may execute.
public struct ExternalOperationPlan: Hashable, Codable, Sendable {
    /// Adapter family that prepared the operation.
    public let kind: ExternalOperationKind
    /// Stable local subject identity, such as a descriptor ID or provider ID.
    public let subjectID: String
    /// Canonical arguments after schema validation, when applicable.
    public let canonicalArguments: SanitizedCanonicalJSON?
    /// Exact primary destination, absent only for local-pure operations.
    public let destination: ExternalDestination?
    /// Complete bounded redirect set in deterministic order.
    public let allowedRedirects: [ExternalDestination]
    /// Complete bounded fallback set in deterministic order.
    public let allowedFallbacks: [ExternalDestination]
    /// Data categories that may cross the boundary.
    public let dataCategories: [AgentDataCategory]
    /// Existing artifacts this operation may access or export.
    public let artifactIDs: [ArtifactID]
    /// Optional sandbox workspace this operation may address.
    public let workspaceID: SandboxWorkspaceHandleID?
    /// Additional exact scoped-authority constraints required by the plan.
    public let authorityConstraints: [AgentAuthorityConstraint]
    /// Digest of a bounded payload whose body is not persisted in this plan.
    public let payloadDigest: StableDigest?
    /// Digest of complete sandbox/provider execution constraints not otherwise flattened here.
    public let executionConstraintDigest: StableDigest?
    /// Maximum effects trusted local policy assigned to the operation.
    public let effects: [AgentEffect]
    /// Capabilities required before authorization may bind this plan.
    public let requiredCapabilities: AgentCapabilitySet
    /// Maximum request bytes the executor may send or read.
    public let maximumRequestBytes: UInt64
    /// Maximum response bytes the executor may receive or produce.
    public let maximumResponseBytes: UInt64
    /// Maximum execution duration after work begins.
    public let timeoutMilliseconds: UInt64
    /// Frozen retry semantics.
    public let retryPolicy: ExternalRetryPolicy
    /// Frozen idempotency and reconciliation semantics.
    public let idempotency: ExternalIdempotency
    /// Exact key that must be reused on every attempt when key-based idempotency is declared.
    public let idempotencyKey: ExternalIdempotencyKey?
    /// Exact, localized user preview shown for invocation-bound authorization.
    public let userPreview: String
    /// Stable descriptor identity when an operation was prepared by a tool.
    public let descriptorID: String?
    /// Digest of the schema used to validate the request.
    public let schemaDigest: StableDigest?
    /// Locally assigned trust revision that cannot be downgraded by remote metadata.
    public let trustRevision: String?
    /// Opaque credential reference; plaintext credential material is prohibited.
    public let credentialReference: SecretReference?
    /// Deterministic fingerprint binding every authorization-relevant field.
    public let fingerprint: StableDigest

    /// Creates and fingerprints a validated immutable operation plan.
    public init(
        kind: ExternalOperationKind,
        subjectID: String,
        canonicalArguments: SanitizedCanonicalJSON? = nil,
        destination: ExternalDestination? = nil,
        allowedRedirects: [ExternalDestination] = [],
        allowedFallbacks: [ExternalDestination] = [],
        dataCategories: [AgentDataCategory] = [],
        artifactIDs: [ArtifactID] = [],
        workspaceID: SandboxWorkspaceHandleID? = nil,
        authorityConstraints: [AgentAuthorityConstraint] = [],
        payloadDigest: StableDigest? = nil,
        executionConstraintDigest: StableDigest? = nil,
        effects: some Sequence<AgentEffect>,
        requiredCapabilities: AgentCapabilitySet,
        maximumRequestBytes: UInt64,
        maximumResponseBytes: UInt64,
        timeoutMilliseconds: UInt64,
        retryPolicy: ExternalRetryPolicy,
        idempotency: ExternalIdempotency,
        idempotencyKey: ExternalIdempotencyKey? = nil,
        userPreview: String,
        descriptorID: String? = nil,
        schemaDigest: StableDigest? = nil,
        trustRevision: String? = nil,
        credentialReference: SecretReference? = nil
    ) throws {
        let effects = Array(Set(effects)).sorted()
        let redirects = Array(Set(allowedRedirects)).sorted()
        let fallbacks = Array(Set(allowedFallbacks)).sorted()
        let categories = Array(Set(dataCategories)).sorted()
        let artifacts = Array(Set(artifactIDs)).sorted { $0.description < $1.description }
        let constraints = Array(Set(authorityConstraints)).sorted()
        guard AgentWireValidation.isNonblankControlFree(subjectID, maximumLength: 512) else {
            throw AgentContractError.invalidExternalOperationPlan("invalid subject identity")
        }
        try AgentOperationSemantics.validate(
            effects: effects,
            capabilities: requiredCapabilities,
            retryPolicy: retryPolicy,
            idempotency: idempotency,
            idempotencyKey: idempotencyKey
        )
        guard timeoutMilliseconds > 0 else {
            throw AgentContractError.invalidExternalOperationPlan("timeout must be positive")
        }
        guard maximumRequestBytes >= 4, maximumResponseBytes > 0 else {
            throw AgentContractError.invalidExternalOperationPlan("invalid request or response byte bound")
        }
        guard descriptorID.map({
            AgentWireValidation.isNonblankControlFree($0, maximumLength: 512)
        }) ?? true,
        trustRevision.map({
            AgentWireValidation.isNonblankControlFree($0, maximumLength: 128)
        }) ?? true
        else { throw AgentContractError.invalidExternalOperationPlan("invalid descriptor metadata") }
        guard userPreview.isEmpty
                || AgentWireValidation.isNonblankControlFree(userPreview, maximumLength: 4_096)
        else { throw AgentContractError.invalidExternalOperationPlan("invalid operation preview") }
        guard Set(constraints.map(\.key)).count == constraints.count else {
            throw AgentContractError.invalidExternalOperationPlan("duplicate authority constraint key")
        }
        if kind == .localPure {
            guard destination == nil, redirects.isEmpty, fallbacks.isEmpty,
                  effects == [.localPure], categories.isEmpty, artifacts.isEmpty,
                  workspaceID == nil, constraints.isEmpty,
                  executionConstraintDigest == nil,
                  credentialReference == nil,
                  canonicalArguments?.referencedSecretIDs.isEmpty ?? true,
                  idempotency == .pureRead
            else { throw AgentContractError.invalidExternalOperationPlan("localPure plan crosses a boundary") }
        } else {
            guard !effects.contains(.localPure) else {
                throw AgentContractError.invalidExternalOperationPlan("external effects cannot include localPure")
            }
            guard destination != nil else {
                throw AgentContractError.invalidExternalOperationPlan("external plan requires a destination")
            }
            guard AgentWireValidation.isNonblankControlFree(userPreview, maximumLength: 4_096) else {
                throw AgentContractError.invalidExternalOperationPlan("external plan requires an exact preview")
            }
        }
        if kind == .sandbox, executionConstraintDigest == nil {
            throw AgentContractError.invalidExternalOperationPlan(
                "sandbox plan requires a complete execution constraint digest"
            )
        }
        guard !redirects.contains(where: { $0 == destination }),
              !fallbacks.contains(where: { $0 == destination }),
              Set(redirects).isDisjoint(with: Set(fallbacks))
        else { throw AgentContractError.invalidExternalOperationPlan("destination bounds contain duplicates") }

        self.kind = kind
        self.subjectID = subjectID
        self.canonicalArguments = canonicalArguments
        self.destination = destination
        self.allowedRedirects = redirects
        self.allowedFallbacks = fallbacks
        self.dataCategories = categories
        self.artifactIDs = artifacts
        self.workspaceID = workspaceID
        self.authorityConstraints = constraints
        self.payloadDigest = payloadDigest
        self.executionConstraintDigest = executionConstraintDigest
        self.effects = effects
        self.requiredCapabilities = requiredCapabilities
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.timeoutMilliseconds = timeoutMilliseconds
        self.retryPolicy = retryPolicy
        self.idempotency = idempotency
        self.idempotencyKey = idempotencyKey
        self.userPreview = userPreview
        self.descriptorID = descriptorID
        self.schemaDigest = schemaDigest
        self.trustRevision = trustRevision
        self.credentialReference = credentialReference
        fingerprint = try Self.makeFingerprint(
            kind: kind,
            subjectID: subjectID,
            canonicalArguments: canonicalArguments,
            destination: destination,
            allowedRedirects: redirects,
            allowedFallbacks: fallbacks,
            dataCategories: categories,
            artifactIDs: artifacts,
            workspaceID: workspaceID,
            authorityConstraints: constraints,
            payloadDigest: payloadDigest,
            executionConstraintDigest: executionConstraintDigest,
            effects: effects,
            requiredCapabilities: requiredCapabilities,
            maximumRequestBytes: maximumRequestBytes,
            maximumResponseBytes: maximumResponseBytes,
            timeoutMilliseconds: timeoutMilliseconds,
            retryPolicy: retryPolicy,
            idempotency: idempotency,
            idempotencyKey: idempotencyKey,
            userPreview: userPreview,
            descriptorID: descriptorID,
            schemaDigest: schemaDigest,
            trustRevision: trustRevision,
            credentialReference: credentialReference
        )
    }

    /// Decodes and recomputes the fingerprint, rejecting serialized plan tampering.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        let redirects = try container.decode([ExternalDestination].self, forKey: .allowedRedirects)
        let fallbacks = try container.decode([ExternalDestination].self, forKey: .allowedFallbacks)
        let categories = try container.decode([AgentDataCategory].self, forKey: .dataCategories)
        let artifacts = try container.decode([ArtifactID].self, forKey: .artifactIDs)
        let constraints = try container.decode([AgentAuthorityConstraint].self, forKey: .authorityConstraints)
        let effects = try container.decode([AgentEffect].self, forKey: .effects)
        guard redirects == Array(Set(redirects)).sorted(),
              fallbacks == Array(Set(fallbacks)).sorted(),
              categories == Array(Set(categories)).sorted(),
              artifacts == Array(Set(artifacts)).sorted(by: { $0.description < $1.description }),
              constraints == Array(Set(constraints)).sorted(),
              Set(constraints.map(\.key)).count == constraints.count,
              effects == Array(Set(effects)).sorted()
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Noncanonical operation plan")
            )
        }
        do {
            try self.init(
                kind: container.decode(ExternalOperationKind.self, forKey: .kind),
                subjectID: container.decode(String.self, forKey: .subjectID),
                canonicalArguments: container.decodeIfPresent(
                    SanitizedCanonicalJSON.self,
                    forKey: .canonicalArguments
                ),
                destination: container.decodeIfPresent(ExternalDestination.self, forKey: .destination),
                allowedRedirects: redirects,
                allowedFallbacks: fallbacks,
                dataCategories: categories,
                artifactIDs: artifacts,
                workspaceID: container.decodeIfPresent(SandboxWorkspaceHandleID.self, forKey: .workspaceID),
                authorityConstraints: constraints,
                payloadDigest: container.decodeIfPresent(StableDigest.self, forKey: .payloadDigest),
                executionConstraintDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .executionConstraintDigest
                ),
                effects: effects,
                requiredCapabilities: container.decode(AgentCapabilitySet.self, forKey: .requiredCapabilities),
                maximumRequestBytes: container.decode(UInt64.self, forKey: .maximumRequestBytes),
                maximumResponseBytes: container.decode(UInt64.self, forKey: .maximumResponseBytes),
                timeoutMilliseconds: container.decode(UInt64.self, forKey: .timeoutMilliseconds),
                retryPolicy: container.decode(ExternalRetryPolicy.self, forKey: .retryPolicy),
                idempotency: container.decode(ExternalIdempotency.self, forKey: .idempotency),
                idempotencyKey: container.decodeIfPresent(
                    ExternalIdempotencyKey.self,
                    forKey: .idempotencyKey
                ),
                userPreview: container.decode(String.self, forKey: .userPreview),
                descriptorID: container.decodeIfPresent(String.self, forKey: .descriptorID),
                schemaDigest: container.decodeIfPresent(StableDigest.self, forKey: .schemaDigest),
                trustRevision: container.decodeIfPresent(String.self, forKey: .trustRevision),
                credentialReference: container.decodeIfPresent(SecretReference.self, forKey: .credentialReference)
            )
            guard fingerprint == encodedFingerprint else {
                throw AgentContractError.authorizationBindingMismatch("serialized plan fingerprint")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    /// Returns whether every verb and scoped resource in the plan is permitted by an authority scope.
    public func isWithin(_ authority: AgentAuthorityScope) -> Bool {
        guard requiredCapabilities.isSubset(of: authority.capabilities) else { return false }
        let plannedDestinations = [destination].compactMap { $0 } + allowedRedirects + allowedFallbacks
        let destinationsCovered = plannedDestinations.allSatisfy { planned in
            authority.destinations.contains { $0.covers(planned) }
        }
        guard destinationsCovered,
              Set(dataCategories).isSubset(of: Set(authority.dataCategories)),
              Set(artifactIDs).isSubset(of: Set(authority.artifactIDs))
        else { return false }
        if let secretID = credentialReference?.id,
           !authority.secretReferenceIDs.contains(secretID)
        {
            return false
        }
        if let canonicalArguments,
           !Set(canonicalArguments.referencedSecretIDs).isSubset(of: Set(authority.secretReferenceIDs))
        {
            return false
        }
        if let workspaceID, !authority.workspaceIDs.contains(workspaceID) { return false }
        let constraintsByKey = Dictionary(uniqueKeysWithValues: authority.constraints.map { ($0.key, $0) })
        for required in authorityConstraints {
            guard let granted = constraintsByKey[required.key], required.isSubset(of: granted) else {
                return false
            }
        }
        return true
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, subjectID, canonicalArguments, destination, allowedRedirects, allowedFallbacks
        case dataCategories, artifactIDs, workspaceID, authorityConstraints, payloadDigest
        case executionConstraintDigest
        case effects, requiredCapabilities, maximumRequestBytes
        case maximumResponseBytes, timeoutMilliseconds, retryPolicy, idempotency, userPreview
        case idempotencyKey, descriptorID, schemaDigest, trustRevision, credentialReference, fingerprint
    }

    private static func makeFingerprint(
        kind: ExternalOperationKind,
        subjectID: String,
        canonicalArguments: SanitizedCanonicalJSON?,
        destination: ExternalDestination?,
        allowedRedirects: [ExternalDestination],
        allowedFallbacks: [ExternalDestination],
        dataCategories: [AgentDataCategory],
        artifactIDs: [ArtifactID],
        workspaceID: SandboxWorkspaceHandleID?,
        authorityConstraints: [AgentAuthorityConstraint],
        payloadDigest: StableDigest?,
        executionConstraintDigest: StableDigest?,
        effects: [AgentEffect],
        requiredCapabilities: AgentCapabilitySet,
        maximumRequestBytes: UInt64,
        maximumResponseBytes: UInt64,
        timeoutMilliseconds: UInt64,
        retryPolicy: ExternalRetryPolicy,
        idempotency: ExternalIdempotency,
        idempotencyKey: ExternalIdempotencyKey?,
        userPreview: String,
        descriptorID: String?,
        schemaDigest: StableDigest?,
        trustRevision: String?,
        credentialReference: SecretReference?
    ) throws -> StableDigest {
        func destinationValue(_ value: ExternalDestination) -> JSONValue {
            .object(["kind": .string(value.kind.rawValue), "identity": .string(value.normalizedIdentity)])
        }
        func optionalStringValue(_ value: String?) -> JSONValue {
            guard let value else { return .null }
            return .string(value)
        }
        func optionalDestinationValue(_ value: ExternalDestination?) -> JSONValue {
            guard let value else { return .null }
            return destinationValue(value)
        }
        let json: JSONValue = .object([
            "kind": .string(kind.rawValue),
            "subjectID": .string(subjectID),
            "canonicalArguments": canonicalArguments.map { arguments in
                .object([
                    "body": .string(arguments.string),
                    "secrets": .array(arguments.referencedSecretIDs.map {
                        .string($0.description)
                    }),
                    "redactionPolicy": .unsignedInteger(UInt64(arguments.redaction.policyVersion)),
                    "sanitizationPolicy": .unsignedInteger(arguments.policyRevision),
                    "attestation": .string(arguments.attestationDigest.rawValue),
                ])
            } ?? .null,
            "destination": optionalDestinationValue(destination),
            "allowedRedirects": .array(allowedRedirects.map(destinationValue)),
            "allowedFallbacks": .array(allowedFallbacks.map(destinationValue)),
            "dataCategories": .array(dataCategories.map { .string($0.rawValue) }),
            "artifactIDs": .array(artifactIDs.map { .string($0.description) }),
            "workspaceID": optionalStringValue(workspaceID?.description),
            "authorityConstraints": .array(authorityConstraints.map { constraint in
                .object([
                    "key": .string(constraint.key),
                    "allowedValues": .array(constraint.allowedValues.map(JSONValue.string)),
                ])
            }),
            "payloadDigest": optionalStringValue(payloadDigest?.rawValue),
            "executionConstraintDigest": optionalStringValue(executionConstraintDigest?.rawValue),
            "effects": .array(effects.map { .string($0.rawValue) }),
            "requiredCapabilities": .array(requiredCapabilities.values.map { .string($0.rawValue) }),
            "maximumRequestBytes": .unsignedInteger(maximumRequestBytes),
            "maximumResponseBytes": .unsignedInteger(maximumResponseBytes),
            "timeoutMilliseconds": .unsignedInteger(timeoutMilliseconds),
            "retryKind": .string(retryPolicy.kind.rawValue),
            "retryAttempts": .unsignedInteger(UInt64(retryPolicy.maximumAttempts)),
            "retryBaseDelay": .unsignedInteger(retryPolicy.baseDelayMilliseconds),
            "retryMaximumDelay": .unsignedInteger(retryPolicy.maximumDelayMilliseconds),
            "retryJitter": .bool(retryPolicy.allowsJitter),
            "idempotency": .string(idempotency.rawValue),
            "idempotencyKey": optionalStringValue(idempotencyKey?.digest.rawValue),
            "userPreview": .string(userPreview),
            "descriptorID": optionalStringValue(descriptorID),
            "schemaDigest": optionalStringValue(schemaDigest?.rawValue),
            "trustRevision": optionalStringValue(trustRevision),
            "credentialReference": credentialReference.map { reference in
                .object([
                    "id": .string(reference.id.description),
                    "purpose": .string(reference.purpose),
                    "providerID": optionalStringValue(reference.providerID),
                ])
            } ?? .null,
        ])
        return try json.fingerprint()
    }
}

/// User or trusted-policy disposition for one prepared external operation.
public enum ApprovalDecision: String, CaseIterable, Hashable, Codable, Sendable {
    /// The exact prepared operation was approved.
    case approved
    /// The operation was explicitly denied.
    case denied
    /// The approval interaction was cancelled without granting authority.
    case cancelled
}

/// Persistence scope of an approval receipt.
public enum ApprovalScope: String, CaseIterable, Hashable, Codable, Sendable {
    /// The receipt authorizes only one exact prepared request.
    case exactInvocation
    /// Matching reads may reuse the receipt within one conversation and bounded scope.
    case conversation
}

/// Durable evidence that a bounded operation plan was approved or denied.
public struct ApprovalReceipt: Hashable, Codable, Sendable {
    /// Stable approval identity.
    public let id: ApprovalID
    /// Run in which the decision was recorded.
    public let runID: AgentRunID
    /// Conversation limiting any reusable read grant.
    public let conversationID: ConversationID
    /// Exact request that displayed the preview and collected the decision.
    public let requestID: AgentRequestID
    /// Exact tool invocation, when the operation originated from a tool.
    public let invocationID: ToolInvocationID?
    /// Exact operation-plan fingerprint shown for approval.
    public let planFingerprint: StableDigest
    /// User or trusted-policy decision.
    public let decision: ApprovalDecision
    /// Scope of the decision.
    public let scope: ApprovalScope
    /// Version of locally trusted approval policy.
    public let policyVersion: UInt32
    /// Time at which the durable decision was made.
    public let decidedAt: AgentTimestamp
    /// Optional expiry for a reusable receipt.
    public let expiresAt: AgentTimestamp?
    /// Digest of the exact displayed preview.
    public let previewDigest: StableDigest
    /// Digest of normalized arguments, when present.
    public let argumentsDigest: StableDigest?
    /// Exact primary destination matcher.
    public let destination: ExternalDestination?
    /// Bounded redirects covered by the receipt.
    public let allowedRedirects: [ExternalDestination]
    /// Bounded fallbacks covered by the receipt.
    public let allowedFallbacks: [ExternalDestination]
    /// Data categories shown to the authorizer.
    public let dataCategories: [AgentDataCategory]
    /// Artifacts shown to the authorizer.
    public let artifactIDs: [ArtifactID]
    /// Sandbox workspace shown to the authorizer.
    public let workspaceID: SandboxWorkspaceHandleID?
    /// Extensible scoped constraints shown to the authorizer.
    public let authorityConstraints: [AgentAuthorityConstraint]
    /// Maximum effect classes shown to the authorizer.
    public let effects: [AgentEffect]
    /// Digest of outbound or protected payload data, when applicable.
    public let payloadDigest: StableDigest?
    /// Complete sandbox/provider constraint digest shown to the authorizer.
    public let executionConstraintDigest: StableDigest?
    /// Descriptor identity covered by the receipt.
    public let descriptorID: String?
    /// Schema digest covered by the receipt.
    public let schemaDigest: StableDigest?
    /// Trust revision covered by the receipt.
    public let trustRevision: String?
    /// Exact idempotency key covered by the receipt, when one was planned.
    public let idempotencyKey: ExternalIdempotencyKey?
    /// Full opaque credential selector covered by the receipt, never credential material.
    public let credentialReference: SecretReference?
    /// Fingerprint of the exact prepared request, including payload and grant.
    public let preparedRequestFingerprint: StableDigest
    /// Fingerprint of the exact step grant shown to the authorizer.
    public let stepCapabilityGrantFingerprint: StableDigest
    /// Fingerprint of the run ceiling from which the step grant was attenuated.
    public let runCapabilityCeilingFingerprint: StableDigest

    /// Creates a durable receipt bound to one complete immutable plan.
    public init(
        id: ApprovalID,
        prepared: PreparedExternalOperationRequest,
        decision: ApprovalDecision,
        scope: ApprovalScope,
        policyVersion: UInt32,
        decidedAt: AgentTimestamp,
        expiresAt: AgentTimestamp? = nil
    ) throws {
        guard policyVersion > 0 else {
            throw AgentContractError.invalidExternalOperationPlan("approval policy version must be positive")
        }
        if let expiresAt, expiresAt < decidedAt {
            throw AgentContractError.invalidExternalOperationPlan("approval expiry precedes decision")
        }
        let plan = prepared.plan
        if scope == .conversation, !plan.permitsConversationScopedApproval {
            throw AgentContractError.invalidExternalOperationPlan(
                "conversation approval is restricted to bounded reads"
            )
        }
        self.id = id
        runID = prepared.runID
        conversationID = prepared.conversationID
        requestID = prepared.requestID
        invocationID = prepared.invocationID
        planFingerprint = plan.fingerprint
        self.decision = decision
        self.scope = scope
        self.policyVersion = policyVersion
        self.decidedAt = decidedAt
        self.expiresAt = expiresAt
        previewDigest = StableDigest.sha256(Data(plan.userPreview.utf8))
        argumentsDigest = plan.canonicalArguments?.fingerprint
        destination = plan.destination
        allowedRedirects = plan.allowedRedirects
        allowedFallbacks = plan.allowedFallbacks
        dataCategories = plan.dataCategories
        artifactIDs = plan.artifactIDs
        workspaceID = plan.workspaceID
        authorityConstraints = plan.authorityConstraints
        effects = plan.effects
        payloadDigest = plan.payloadDigest
        executionConstraintDigest = plan.executionConstraintDigest
        descriptorID = plan.descriptorID
        schemaDigest = plan.schemaDigest
        trustRevision = plan.trustRevision
        idempotencyKey = plan.idempotencyKey
        credentialReference = plan.credentialReference
        preparedRequestFingerprint = prepared.fingerprint
        stepCapabilityGrantFingerprint = prepared.capabilityGrant.fingerprint
        runCapabilityCeilingFingerprint = prepared.capabilityGrant.runCeiling.fingerprint
    }

    /// Decodes a receipt and rejects noncanonical arrays or impossible expiry/scope combinations.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRedirects = try container.decode([ExternalDestination].self, forKey: .allowedRedirects)
        let decodedFallbacks = try container.decode([ExternalDestination].self, forKey: .allowedFallbacks)
        let decodedCategories = try container.decode([AgentDataCategory].self, forKey: .dataCategories)
        let decodedArtifacts = try container.decode([ArtifactID].self, forKey: .artifactIDs)
        let decodedConstraints = try container.decode(
            [AgentAuthorityConstraint].self,
            forKey: .authorityConstraints
        )
        let decodedEffects = try container.decode([AgentEffect].self, forKey: .effects)
        let decodedDecision = try container.decode(ApprovalDecision.self, forKey: .decision)
        let decodedScope = try container.decode(ApprovalScope.self, forKey: .scope)
        let decodedDecidedAt = try container.decode(AgentTimestamp.self, forKey: .decidedAt)
        let decodedExpiresAt = try container.decodeIfPresent(AgentTimestamp.self, forKey: .expiresAt)
        guard decodedRedirects == Array(Set(decodedRedirects)).sorted(),
              decodedFallbacks == Array(Set(decodedFallbacks)).sorted(),
              decodedCategories == Array(Set(decodedCategories)).sorted(),
              decodedArtifacts == Array(Set(decodedArtifacts)).sorted(by: { $0.description < $1.description }),
              decodedConstraints == Array(Set(decodedConstraints)).sorted(),
              Set(decodedConstraints.map(\.key)).count == decodedConstraints.count,
              decodedEffects == Array(Set(decodedEffects)).sorted(),
              try container.decode(UInt32.self, forKey: .policyVersion) > 0
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Noncanonical or invalid approval receipt")
            )
        }
        if let decodedExpiresAt, decodedExpiresAt < decodedDecidedAt {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Approval expiry precedes decision")
            )
        }
        let safeReadEffects: Set<AgentEffect> = [.localRead, .privateDataRead, .networkRead]
        if decodedScope == .conversation,
           !Set(decodedEffects).isSubset(of: safeReadEffects)
        {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unsafe conversation approval")
            )
        }
        id = try container.decode(ApprovalID.self, forKey: .id)
        runID = try container.decode(AgentRunID.self, forKey: .runID)
        conversationID = try container.decode(ConversationID.self, forKey: .conversationID)
        requestID = try container.decode(AgentRequestID.self, forKey: .requestID)
        invocationID = try container.decodeIfPresent(ToolInvocationID.self, forKey: .invocationID)
        planFingerprint = try container.decode(StableDigest.self, forKey: .planFingerprint)
        decision = decodedDecision
        scope = decodedScope
        policyVersion = try container.decode(UInt32.self, forKey: .policyVersion)
        decidedAt = decodedDecidedAt
        expiresAt = decodedExpiresAt
        previewDigest = try container.decode(StableDigest.self, forKey: .previewDigest)
        argumentsDigest = try container.decodeIfPresent(StableDigest.self, forKey: .argumentsDigest)
        destination = try container.decodeIfPresent(ExternalDestination.self, forKey: .destination)
        allowedRedirects = decodedRedirects
        allowedFallbacks = decodedFallbacks
        dataCategories = decodedCategories
        artifactIDs = decodedArtifacts
        workspaceID = try container.decodeIfPresent(SandboxWorkspaceHandleID.self, forKey: .workspaceID)
        authorityConstraints = decodedConstraints
        effects = decodedEffects
        payloadDigest = try container.decodeIfPresent(StableDigest.self, forKey: .payloadDigest)
        executionConstraintDigest = try container.decodeIfPresent(
            StableDigest.self,
            forKey: .executionConstraintDigest
        )
        descriptorID = try container.decodeIfPresent(String.self, forKey: .descriptorID)
        schemaDigest = try container.decodeIfPresent(StableDigest.self, forKey: .schemaDigest)
        trustRevision = try container.decodeIfPresent(String.self, forKey: .trustRevision)
        idempotencyKey = try container.decodeIfPresent(
            ExternalIdempotencyKey.self,
            forKey: .idempotencyKey
        )
        credentialReference = try container.decodeIfPresent(
            SecretReference.self,
            forKey: .credentialReference
        )
        preparedRequestFingerprint = try container.decode(
            StableDigest.self,
            forKey: .preparedRequestFingerprint
        )
        stepCapabilityGrantFingerprint = try container.decode(
            StableDigest.self,
            forKey: .stepCapabilityGrantFingerprint
        )
        runCapabilityCeilingFingerprint = try container.decode(
            StableDigest.self,
            forKey: .runCapabilityCeilingFingerprint
        )
    }

    /// Returns whether an approved receipt remains valid at an explicit deterministic time.
    public func isUsable(at timestamp: AgentTimestamp) -> Bool {
        guard decision == .approved, timestamp >= decidedAt else { return false }
        return expiresAt.map { timestamp <= $0 } ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case id, runID, conversationID, requestID, invocationID, planFingerprint, decision, scope
        case policyVersion, decidedAt, expiresAt, previewDigest, argumentsDigest, destination
        case allowedRedirects, allowedFallbacks, dataCategories, artifactIDs, workspaceID
        case authorityConstraints, effects, payloadDigest, executionConstraintDigest
        case descriptorID, schemaDigest, trustRevision
        case idempotencyKey, credentialReference, preparedRequestFingerprint, stepCapabilityGrantFingerprint
        case runCapabilityCeilingFingerprint
    }
}

/// A side-effect-free prepared request that may be handed to an approval engine.
public struct PreparedExternalOperationRequest: Hashable, Codable, Sendable {
    /// Stable request identity.
    public let requestID: AgentRequestID
    /// Owning run.
    public let runID: AgentRunID
    /// Conversation whose bounded policy and reusable read receipts apply.
    public let conversationID: ConversationID
    /// Stable preparation step.
    public let stepID: AgentStepID
    /// Optional tool invocation associated with this request.
    public let invocationID: ToolInvocationID?
    /// Immutable operation plan.
    public let plan: ExternalOperationPlan
    /// Provider-neutral prepared request payload.
    public let payload: SanitizedCanonicalJSON
    /// Step authority against which plan requirements were checked.
    public let capabilityGrant: StepCapabilityGrant

    /// Deterministic identity of request IDs, immutable plan, exact payload, and scoped grant.
    public var fingerprint: StableDigest {
        StableDigest.fingerprint(
            domain: "prepared-external-operation.v1",
            components: [
                Data(requestID.description.utf8),
                Data(runID.description.utf8),
                Data(conversationID.description.utf8),
                Data(stepID.description.utf8),
                Data((invocationID?.description ?? "").utf8),
                Data(plan.fingerprint.rawValue.utf8),
                Data(payload.fingerprint.rawValue.utf8),
                Data(capabilityGrant.fingerprint.rawValue.utf8),
                Data(capabilityGrant.runCeiling.fingerprint.rawValue.utf8),
            ]
        )
    }

    /// Creates a prepared request and rejects missing step authority.
    public init(
        requestID: AgentRequestID,
        runID: AgentRunID,
        conversationID: ConversationID,
        stepID: AgentStepID,
        invocationID: ToolInvocationID? = nil,
        plan: ExternalOperationPlan,
        payload: SanitizedCanonicalJSON,
        capabilityGrant: StepCapabilityGrant
    ) throws {
        guard plan.isWithin(capabilityGrant.authority) else {
            var missingCapabilities: [AgentCapability] = []
            for capability in plan.requiredCapabilities.values
                where !capabilityGrant.capabilities.contains(capability)
            {
                missingCapabilities.append(capability)
            }
            throw AgentContractError.capabilityEscalation(missingCapabilities)
        }
        guard plan.payloadDigest == payload.fingerprint else {
            throw AgentContractError.authorizationBindingMismatch("prepared payload digest")
        }
        guard payload.data.count <= plan.maximumRequestBytes else {
            throw AgentContractError.invalidExternalOperationPlan("prepared payload exceeds request bytes")
        }
        self.requestID = requestID
        self.runID = runID
        self.conversationID = conversationID
        self.stepID = stepID
        self.invocationID = invocationID
        self.plan = plan
        self.payload = payload
        self.capabilityGrant = capabilityGrant
    }

    /// Decodes and revalidates the complete plan against the embedded scoped grant.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                requestID: container.decode(AgentRequestID.self, forKey: .requestID),
                runID: container.decode(AgentRunID.self, forKey: .runID),
                conversationID: container.decode(ConversationID.self, forKey: .conversationID),
                stepID: container.decode(AgentStepID.self, forKey: .stepID),
                invocationID: container.decodeIfPresent(ToolInvocationID.self, forKey: .invocationID),
                plan: container.decode(ExternalOperationPlan.self, forKey: .plan),
                payload: container.decode(SanitizedCanonicalJSON.self, forKey: .payload),
                capabilityGrant: container.decode(StepCapabilityGrant.self, forKey: .capabilityGrant)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, runID, conversationID, stepID, invocationID, plan, payload, capabilityGrant
    }
}

/// Versioned durable request shown to the user before an external operation may be approved.
public struct AgentApprovalRequest: Hashable, Codable, Sendable, AgentContractPayload {
    /// Stable wire schema identity.
    public static let schemaID = "com.mobilellm.agent.approval-request"

    /// Stable identity copied unchanged into blocking state, commands, and the eventual receipt.
    public let id: ApprovalID
    /// Exact immutable operation presented for the decision.
    public let prepared: PreparedExternalOperationRequest
    /// Version of the locally trusted approval policy that produced this request.
    public let policyVersion: UInt32
    /// Time at which the request became durably visible.
    public let createdAt: AgentTimestamp
    /// Optional last instant at which a decision may be accepted.
    public let expiresAt: AgentTimestamp?

    /// Creates a bounded approval request with a nonnegative decision window.
    public init(
        id: ApprovalID,
        prepared: PreparedExternalOperationRequest,
        policyVersion: UInt32,
        createdAt: AgentTimestamp,
        expiresAt: AgentTimestamp? = nil
    ) throws {
        guard policyVersion > 0 else {
            throw AgentContractError.invalidExternalOperationPlan(
                "approval request policy version must be positive"
            )
        }
        if let expiresAt, expiresAt < createdAt {
            throw AgentContractError.invalidExternalOperationPlan(
                "approval request expiry precedes creation"
            )
        }
        self.id = id
        self.prepared = prepared
        self.policyVersion = policyVersion
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Decodes and revalidates the policy version and decision window.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ApprovalID.self, forKey: .id),
                prepared: container.decode(PreparedExternalOperationRequest.self, forKey: .prepared),
                policyVersion: container.decode(UInt32.self, forKey: .policyVersion),
                createdAt: container.decode(AgentTimestamp.self, forKey: .createdAt),
                expiresAt: container.decodeIfPresent(AgentTimestamp.self, forKey: .expiresAt)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    /// Returns whether a command may still decide this request at an explicit trusted time.
    public func acceptsDecision(at timestamp: AgentTimestamp) -> Bool {
        guard timestamp >= createdAt else { return false }
        if let expiresAt { return timestamp <= expiresAt }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case id, prepared, policyVersion, createdAt, expiresAt
    }
}

public extension ApprovalReceipt {
    /// Creates a receipt that carries the exact identity and policy version shown in a request.
    init(
        request: AgentApprovalRequest,
        decision: ApprovalDecision,
        scope: ApprovalScope,
        decidedAt: AgentTimestamp,
        receiptExpiresAt: AgentTimestamp? = nil
    ) throws {
        guard request.acceptsDecision(at: decidedAt) else {
            throw AgentContractError.authorizationExpired
        }
        try self.init(
            id: request.id,
            prepared: request.prepared,
            decision: decision,
            scope: scope,
            policyVersion: request.policyVersion,
            decidedAt: decidedAt,
            expiresAt: receiptExpiresAt
        )
    }
}

/// One concrete attempt, cryptographically bound to its prepared request and idempotency key.
public struct ExternalOperationAttempt: Hashable, Codable, Sendable {
    /// Prepared request being attempted.
    public let requestID: AgentRequestID
    /// Exact immutable plan for the attempt.
    public let planFingerprint: StableDigest
    /// One-based attempt number, bounded by the frozen retry policy.
    public let attemptNumber: UInt16
    /// Key attached to this attempt, exactly matching the plan when required.
    public let idempotencyKey: ExternalIdempotencyKey?
    /// Digest binding the request, plan, attempt number, and key.
    public let fingerprint: StableDigest

    /// Creates an attempt from the only prepared request it may execute.
    public init(prepared: PreparedExternalOperationRequest, attemptNumber: UInt16) throws {
        guard attemptNumber > 0,
              attemptNumber <= prepared.plan.retryPolicy.maximumAttempts,
              attemptNumber == 1 || prepared.plan.retryPolicy.kind != .never
        else { throw AgentContractError.invalidExternalOperationPlan("attempt exceeds retry policy") }
        requestID = prepared.requestID
        planFingerprint = prepared.plan.fingerprint
        self.attemptNumber = attemptNumber
        idempotencyKey = prepared.plan.idempotencyKey
        fingerprint = Self.makeFingerprint(
            requestID: prepared.requestID,
            planFingerprint: prepared.plan.fingerprint,
            attemptNumber: attemptNumber,
            idempotencyKey: prepared.plan.idempotencyKey
        )
    }

    /// Decodes and rejects zero attempt numbers and fingerprint tampering.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(AgentRequestID.self, forKey: .requestID)
        planFingerprint = try container.decode(StableDigest.self, forKey: .planFingerprint)
        attemptNumber = try container.decode(UInt16.self, forKey: .attemptNumber)
        idempotencyKey = try container.decodeIfPresent(
            ExternalIdempotencyKey.self,
            forKey: .idempotencyKey
        )
        fingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        guard attemptNumber > 0,
              fingerprint == Self.makeFingerprint(
                  requestID: requestID,
                  planFingerprint: planFingerprint,
                  attemptNumber: attemptNumber,
                  idempotencyKey: idempotencyKey
              )
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid operation attempt")
            )
        }
    }

    fileprivate func isBound(to prepared: PreparedExternalOperationRequest) -> Bool {
        requestID == prepared.requestID
            && planFingerprint == prepared.plan.fingerprint
            && attemptNumber > 0
            && attemptNumber <= prepared.plan.retryPolicy.maximumAttempts
            && (attemptNumber == 1 || prepared.plan.retryPolicy.kind != .never)
            && idempotencyKey == prepared.plan.idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, planFingerprint, attemptNumber, idempotencyKey, fingerprint
    }

    private static func makeFingerprint(
        requestID: AgentRequestID,
        planFingerprint: StableDigest,
        attemptNumber: UInt16,
        idempotencyKey: ExternalIdempotencyKey?
    ) -> StableDigest {
        StableDigest.fingerprint(
            domain: "external-operation-attempt.v1",
            components: [
                Data(requestID.description.utf8),
                Data(planFingerprint.rawValue.utf8),
                Data(String(attemptNumber).utf8),
                Data((idempotencyKey?.digest.rawValue ?? "").utf8),
            ]
        )
    }
}

/// Kind of one exact destination in an immutable external-operation itinerary.
public enum ExternalOperationBoundaryHopKind: String, CaseIterable, Hashable, Codable, Sendable {
    /// The operation's primary destination.
    case primary
    /// One exact destination in the frozen redirect list.
    case redirect
    /// One exact destination in the frozen provider-fallback list.
    case fallback
}

/// One one-shot boundary hop within an attempt, including redirects or provider fallbacks.
public struct ExternalOperationBoundaryHop: Hashable, Codable, Sendable {
    /// Fingerprint of the attempt that owns this hop.
    public let attemptFingerprint: StableDigest
    /// Exact itinerary role of this hop.
    public let kind: ExternalOperationBoundaryHopKind
    /// Exact destination this hop may cross; nil only for a local-pure primary hop.
    public let destination: ExternalDestination?
    /// One-based canonical itinerary position; a retry creates a new attempt.
    public let hopNumber: UInt16
    /// Stable one-shot identity consumed by an execution gate.
    public let fingerprint: StableDigest

    /// Creates the unique hop for one destination in a prepared request's frozen itinerary.
    public init(
        prepared: PreparedExternalOperationRequest,
        attempt: ExternalOperationAttempt,
        destination: ExternalDestination?
    ) throws {
        guard attempt.isBound(to: prepared) else {
            throw AgentContractError.authorizationBindingMismatch("operation attempt")
        }
        let kind: ExternalOperationBoundaryHopKind
        let position: Int
        if destination == prepared.plan.destination {
            kind = .primary
            position = 1
        } else if let destination,
                  let index = prepared.plan.allowedRedirects.firstIndex(of: destination)
        {
            kind = .redirect
            position = 2 + index
        } else if let destination,
                  let index = prepared.plan.allowedFallbacks.firstIndex(of: destination)
        {
            kind = .fallback
            position = 2 + prepared.plan.allowedRedirects.count + index
        } else {
            throw AgentContractError.authorizationBindingMismatch("unplanned boundary destination")
        }
        guard let hopNumber = UInt16(exactly: position) else {
            throw AgentContractError.invalidExternalOperationPlan("boundary itinerary is too large")
        }
        attemptFingerprint = attempt.fingerprint
        self.kind = kind
        self.destination = destination
        self.hopNumber = hopNumber
        fingerprint = Self.makeFingerprint(
            attemptFingerprint: attempt.fingerprint,
            kind: kind,
            destination: destination,
            hopNumber: hopNumber
        )
    }

    /// Decodes and rejects zero positions and fingerprint tampering.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attemptFingerprint = try container.decode(StableDigest.self, forKey: .attemptFingerprint)
        kind = try container.decode(ExternalOperationBoundaryHopKind.self, forKey: .kind)
        destination = try container.decodeIfPresent(ExternalDestination.self, forKey: .destination)
        hopNumber = try container.decode(UInt16.self, forKey: .hopNumber)
        fingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        guard hopNumber > 0,
              fingerprint == Self.makeFingerprint(
                  attemptFingerprint: attemptFingerprint,
                  kind: kind,
                  destination: destination,
                  hopNumber: hopNumber
              )
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid boundary hop")
            )
        }
    }

    fileprivate func isBound(
        to attempt: ExternalOperationAttempt,
        prepared: PreparedExternalOperationRequest
    ) -> Bool {
        guard attemptFingerprint == attempt.fingerprint,
              attempt.isBound(to: prepared)
        else { return false }
        let expected: ExternalOperationBoundaryHop?
        expected = try? ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: destination
        )
        return expected == self
    }

    private enum CodingKeys: String, CodingKey {
        case attemptFingerprint, kind, destination, hopNumber, fingerprint
    }

    private static func makeFingerprint(
        attemptFingerprint: StableDigest,
        kind: ExternalOperationBoundaryHopKind,
        destination: ExternalDestination?,
        hopNumber: UInt16
    ) -> StableDigest {
        .fingerprint(
            domain: "external-operation-boundary-hop.v1",
            components: [
                Data(attemptFingerprint.rawValue.utf8),
                Data(kind.rawValue.utf8),
                Data((destination?.kind.rawValue ?? "").utf8),
                Data((destination?.normalizedIdentity ?? "").utf8),
                Data(String(hopNumber).utf8),
            ]
        )
    }
}

/// Opaque, non-serializable request wrapper issued only after trusted local authorization.
public struct AuthorizedExternalOperationRequest: Hashable, Sendable {
    /// The exact prepared request covered by this authorization.
    public let prepared: PreparedExternalOperationRequest
    /// Durable receipt bound to the request's complete plan fingerprint.
    public let authorization: ApprovalReceipt
    /// Independent local authority root proving the decoded ceiling was admitted.
    public let trustedRunAuthority: TrustedRunAuthority

    /// Binds durable authorization fields structurally; execution-time expiry is checked separately.
    @_spi(AgentRuntime)
    public init(
        prepared: PreparedExternalOperationRequest,
        authorization: ApprovalReceipt,
        trustedRunAuthority: TrustedRunAuthority
    ) throws {
        guard authorization.decision == .approved else { throw AgentContractError.authorizationDenied }
        guard trustedRunAuthority.validates(
            runID: prepared.runID,
            grant: prepared.capabilityGrant
        ) else { throw AgentContractError.authorizationBindingMismatch("trusted run authority") }
        let plan = prepared.plan
        guard authorization.conversationID == prepared.conversationID else {
            throw AgentContractError.authorizationBindingMismatch("conversation identity")
        }
        switch authorization.scope {
        case .exactInvocation:
            guard authorization.runID == prepared.runID,
                  authorization.requestID == prepared.requestID,
                  authorization.invocationID == prepared.invocationID,
                  authorization.preparedRequestFingerprint == prepared.fingerprint,
                  authorization.stepCapabilityGrantFingerprint == prepared.capabilityGrant.fingerprint,
                  authorization.runCapabilityCeilingFingerprint
                    == prepared.capabilityGrant.runCeiling.fingerprint
            else { throw AgentContractError.authorizationBindingMismatch("exact invocation identity") }
        case .conversation:
            // The receipt records the original grant fingerprints for evidence, but a later run
            // may have a different ceiling. `PreparedExternalOperationRequest` has already proven
            // the exact unchanged plan is inside the current grant.
            guard plan.permitsConversationScopedApproval else {
                throw AgentContractError.authorizationBindingMismatch("unsafe conversation scope")
            }
        }
        guard authorization.planFingerprint == plan.fingerprint else {
            throw AgentContractError.authorizationBindingMismatch("plan fingerprint")
        }
        guard authorization.previewDigest == StableDigest.sha256(Data(plan.userPreview.utf8)),
              authorization.argumentsDigest == plan.canonicalArguments?.fingerprint,
              authorization.destination == plan.destination,
              authorization.allowedRedirects == plan.allowedRedirects,
              authorization.allowedFallbacks == plan.allowedFallbacks,
              authorization.dataCategories == plan.dataCategories,
              authorization.artifactIDs == plan.artifactIDs,
              authorization.workspaceID == plan.workspaceID,
              authorization.authorityConstraints == plan.authorityConstraints,
              authorization.effects == plan.effects,
              authorization.payloadDigest == plan.payloadDigest,
              authorization.executionConstraintDigest == plan.executionConstraintDigest,
              authorization.descriptorID == plan.descriptorID,
              authorization.schemaDigest == plan.schemaDigest,
              authorization.trustRevision == plan.trustRevision,
              authorization.idempotencyKey == plan.idempotencyKey,
              authorization.credentialReference == plan.credentialReference
        else {
            throw AgentContractError.authorizationBindingMismatch("authorization scope")
        }
        self.prepared = prepared
        self.authorization = authorization
        self.trustedRunAuthority = trustedRunAuthority
    }

    /// Creates a trusted gate that revalidates time, observation, and attempt on every boundary call.
    @_spi(AgentRuntime)
    public func executionGate(
        clock: any AgentAuthorizationClock,
        policyValidator: any AgentAuthorizationPolicyValidating,
        attemptLedger: any ExternalOperationAttemptClaiming
    ) -> ExternalExecutionAuthorizationGate {
        ExternalExecutionAuthorizationGate(
            authorized: self,
            clock: clock,
            policyValidator: policyValidator,
            attemptLedger: attemptLedger
        )
    }
}

/// Runtime-observed values checked immediately before an external boundary is crossed.
public struct ExternalOperationObservation: Hashable, Codable, Sendable {
    /// Actual destination selected after resolution or redirect handling.
    public let destination: ExternalDestination?
    /// Data categories actually crossing the boundary.
    public let dataCategories: [AgentDataCategory]
    /// Effects the adapter may actually perform.
    public let effects: [AgentEffect]
    /// Request bytes about to cross the boundary.
    public let requestBytes: UInt64
    /// Maximum response bytes configured on the concrete operation.
    public let responseBytesLimit: UInt64
    /// Actual payload digest, when payload data will cross the boundary.
    public let payloadDigest: StableDigest?
    /// Concrete complete sandbox/provider constraint digest.
    public let executionConstraintDigest: StableDigest?
    /// Artifacts actually used by the operation.
    public let artifactIDs: [ArtifactID]
    /// Actual sandbox workspace, when applicable.
    public let workspaceID: SandboxWorkspaceHandleID?
    /// Concrete descriptor identity observed before execution.
    public let descriptorID: String?
    /// Concrete schema digest observed before execution.
    public let schemaDigest: StableDigest?
    /// Concrete trust revision observed before execution.
    public let trustRevision: String?
    /// Idempotency key actually attached to the concrete attempt, when required.
    public let idempotencyKey: ExternalIdempotencyKey?
    /// Credential selector actually resolved for the operation; never secret material.
    public let credentialReference: SecretReference?
    /// Complete set of secret-store references resolved for this concrete operation.
    public let resolvedSecretReferenceIDs: [SecretReferenceID]

    /// Creates a normalized execution-time observation.
    public init(
        destination: ExternalDestination?,
        dataCategories: some Sequence<AgentDataCategory>,
        effects: some Sequence<AgentEffect>,
        requestBytes: UInt64,
        responseBytesLimit: UInt64,
        payloadDigest: StableDigest?,
        executionConstraintDigest: StableDigest? = nil,
        artifactIDs: some Sequence<ArtifactID> = [],
        workspaceID: SandboxWorkspaceHandleID? = nil,
        descriptorID: String? = nil,
        schemaDigest: StableDigest? = nil,
        trustRevision: String? = nil,
        idempotencyKey: ExternalIdempotencyKey? = nil,
        credentialReference: SecretReference? = nil,
        resolvedSecretReferenceIDs: some Sequence<SecretReferenceID> = []
    ) throws {
        let normalizedEffects = Array(Set(effects)).sorted()
        guard !normalizedEffects.isEmpty else {
            throw AgentContractError.invalidExternalOperationPlan("observation requires an effect")
        }
        self.destination = destination
        self.dataCategories = Array(Set(dataCategories)).sorted()
        self.effects = normalizedEffects
        self.requestBytes = requestBytes
        self.responseBytesLimit = responseBytesLimit
        self.payloadDigest = payloadDigest
        self.executionConstraintDigest = executionConstraintDigest
        self.artifactIDs = Array(Set(artifactIDs)).sorted { $0.description < $1.description }
        self.workspaceID = workspaceID
        self.descriptorID = descriptorID
        self.schemaDigest = schemaDigest
        self.trustRevision = trustRevision
        self.idempotencyKey = idempotencyKey
        self.credentialReference = credentialReference
        self.resolvedSecretReferenceIDs = Array(Set(resolvedSecretReferenceIDs)).sorted {
            $0.description < $1.description
        }
    }

    /// Decodes and rejects noncanonical or empty execution observations.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let categories = try container.decode([AgentDataCategory].self, forKey: .dataCategories)
        let effects = try container.decode([AgentEffect].self, forKey: .effects)
        let artifacts = try container.decode([ArtifactID].self, forKey: .artifactIDs)
        let secrets = try container.decode([SecretReferenceID].self, forKey: .resolvedSecretReferenceIDs)
        do {
            try self.init(
                destination: container.decodeIfPresent(ExternalDestination.self, forKey: .destination),
                dataCategories: categories,
                effects: effects,
                requestBytes: container.decode(UInt64.self, forKey: .requestBytes),
                responseBytesLimit: container.decode(UInt64.self, forKey: .responseBytesLimit),
                payloadDigest: container.decodeIfPresent(StableDigest.self, forKey: .payloadDigest),
                executionConstraintDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .executionConstraintDigest
                ),
                artifactIDs: artifacts,
                workspaceID: container.decodeIfPresent(SandboxWorkspaceHandleID.self, forKey: .workspaceID),
                descriptorID: container.decodeIfPresent(String.self, forKey: .descriptorID),
                schemaDigest: container.decodeIfPresent(StableDigest.self, forKey: .schemaDigest),
                trustRevision: container.decodeIfPresent(String.self, forKey: .trustRevision),
                idempotencyKey: container.decodeIfPresent(
                    ExternalIdempotencyKey.self,
                    forKey: .idempotencyKey
                ),
                credentialReference: container.decodeIfPresent(
                    SecretReference.self,
                    forKey: .credentialReference
                ),
                resolvedSecretReferenceIDs: secrets
            )
            guard dataCategories == categories, self.effects == effects, artifactIDs == artifacts,
                  resolvedSecretReferenceIDs == secrets
            else {
                throw AgentContractError.invalidExternalOperationPlan("noncanonical observation")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    /// Returns whether observed behavior is equal to or narrower than an immutable plan.
    public func isWithin(_ plan: ExternalOperationPlan) -> Bool {
        let destinations = Set([plan.destination].compactMap { $0 } + plan.allowedRedirects + plan.allowedFallbacks)
        let plannedSecrets = Set(
            (plan.canonicalArguments?.referencedSecretIDs ?? [])
                + [plan.credentialReference?.id].compactMap { $0 }
        )
        guard destination.map(destinations.contains) ?? (plan.kind == .localPure),
              Set(dataCategories).isSubset(of: Set(plan.dataCategories)),
              Set(effects).isSubset(of: Set(plan.effects)),
              requestBytes <= plan.maximumRequestBytes,
              responseBytesLimit <= plan.maximumResponseBytes,
              payloadDigest == plan.payloadDigest,
              executionConstraintDigest == plan.executionConstraintDigest,
              Set(artifactIDs).isSubset(of: Set(plan.artifactIDs)),
              workspaceID == plan.workspaceID,
              descriptorID == plan.descriptorID,
              schemaDigest == plan.schemaDigest,
              trustRevision == plan.trustRevision,
              idempotencyKey == plan.idempotencyKey,
              credentialReference == plan.credentialReference,
              Set(resolvedSecretReferenceIDs) == plannedSecrets
        else { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case destination, dataCategories, effects, requestBytes, responseBytesLimit, payloadDigest
        case executionConstraintDigest
        case artifactIDs, workspaceID, descriptorID, schemaDigest, trustRevision
        case idempotencyKey, credentialReference, resolvedSecretReferenceIDs
    }
}

/// Closed eager values that may leave an authorized external boundary.
///
/// Lazy handles such as `Task`, `AsyncSequence`, closures, streams, sockets, and provider handles
/// cannot conform by extension because this is an enum rather than an open marker protocol.
public enum ExternalOperationBoundaryValue: Hashable, Codable, Sendable {
    /// The boundary completed without returning a body.
    case none
    /// A bounded canonical JSON body was fully consumed before the gate returned.
    case canonicalJSON(CanonicalJSON)
    /// A durable artifact was committed before the gate returned.
    case artifact(ArtifactReference)
    /// A complete stable tool outcome was consumed before the gate returned.
    case toolOutcome(AgentToolInvocationOutcome)
    /// A complete stable model-attempt outcome was consumed before the gate returned.
    case modelOutcome(AgentModelAttemptOutcome)
}

/// Closed completion supplied by an operation after all authorized boundary work has finished.
public struct ExternalOperationBoundaryCompletion: Hashable, Codable, Sendable {
    /// Eager value; it cannot transport a lazy execution handle.
    public let value: ExternalOperationBoundaryValue
    /// Optional digest of the complete consumed response representation.
    public let responseDigest: StableDigest?

    /// Creates eager boundary completion evidence without a caller-supplied byte count.
    public init(
        value: ExternalOperationBoundaryValue,
        responseDigest: StableDigest? = nil
    ) {
        self.value = value
        self.responseDigest = responseDigest
    }
}

/// Result issued by the gate after it closes byte accounting and invalidates escaped controls.
public struct ExternalOperationBoundaryResult: Hashable, Codable, Sendable {
    /// Closed eager value returned by the completed operation.
    public let value: ExternalOperationBoundaryValue
    /// Response bytes admitted through the gate's hard accumulator.
    public let responseBytes: UInt64
    /// Optional digest of the complete consumed response representation.
    public let responseDigest: StableDigest?

    fileprivate init(
        completion: ExternalOperationBoundaryCompletion,
        responseBytes: UInt64
    ) {
        value = completion.value
        self.responseBytes = responseBytes
        responseDigest = completion.responseDigest
    }
}

/// One-shot byte allowance owned by an active authorization-gate call.
///
/// Adapters record each response chunk before parsing, persisting, or emitting it. The accumulator
/// throws before a chunk that would exceed the immutable plan limit, and rejects calls after the
/// enclosing operation returns so an escaped producer cannot continue under stale authorization.
public actor ExternalOperationBoundaryControl {
    /// Immutable maximum response bytes admitted for this operation.
    public let maximumResponseBytes: UInt64

    private var consumedResponseBytes: UInt64 = 0
    private var isClosed = false

    fileprivate init(maximumResponseBytes: UInt64) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    /// Records one complete response chunk before the adapter handles that chunk.
    public func consumeResponseBytes(_ byteCount: UInt64) throws {
        guard !isClosed else {
            throw AgentContractError.authorizationBindingMismatch("closed boundary control")
        }
        guard byteCount <= maximumResponseBytes - consumedResponseBytes else {
            throw AgentContractError.authorizationBindingMismatch("response byte bound")
        }
        consumedResponseBytes += byteCount
    }

    fileprivate func close() -> UInt64 {
        isClosed = true
        return consumedResponseBytes
    }
}

/// Trusted source of authorization time injected by the runtime rather than an adapter caller.
public protocol AgentAuthorizationClock: Sendable {
    /// Returns the current trusted time for one boundary admission decision.
    func now() async throws -> AgentTimestamp
}

/// Trusted runtime policy hook that checks current receipt status, policy revision, revocation,
/// and the locally keyed `SanitizedCanonicalJSON` attestations on payload and arguments.
public protocol AgentAuthorizationPolicyValidating: Sendable {
    /// Throws unless authorization is still locally valid at the supplied trusted time.
    func validateCurrentAuthorization(
        receipt: ApprovalReceipt,
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws
}

/// Durable atomic claim store preventing replay across process restarts and concurrent gates.
public protocol ExternalOperationAttemptClaiming: Sendable {
    /// Atomically claims a one-shot boundary hop; returns false when it was already consumed.
    func claimBoundaryHop(
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool
}

/// Production wall clock for authorization expiry checks.
public struct SystemAgentAuthorizationClock: AgentAuthorizationClock, Sendable {
    /// Creates a stateless system clock.
    public init() {}

    /// Returns the current finite timestamp.
    public func now() async throws -> AgentTimestamp { try AgentTimestamp(Date()) }
}

/// Trusted execution gate; unlike a bearer proof, it cannot authorize I/O without revalidation.
///
/// Adapters must place the real boundary-crossing call inside `perform`. Redirects, fallbacks,
/// and retries each require a separate call with a fresh observation and current trusted time.
public actor ExternalExecutionAuthorizationGate {
    private let authorized: AuthorizedExternalOperationRequest
    private let clock: any AgentAuthorizationClock
    private let policyValidator: any AgentAuthorizationPolicyValidating
    private let attemptLedger: any ExternalOperationAttemptClaiming
    private var consumedHops: Set<StableDigest> = []
    private var pendingHops: Set<StableDigest> = []

    fileprivate init(
        authorized: AuthorizedExternalOperationRequest,
        clock: any AgentAuthorizationClock,
        policyValidator: any AgentAuthorizationPolicyValidating,
        attemptLedger: any ExternalOperationAttemptClaiming
    ) {
        self.authorized = authorized
        self.clock = clock
        self.policyValidator = policyValidator
        self.attemptLedger = attemptLedger
    }

    /// Revalidates authorization, consumes one operation, and returns only eager completion evidence.
    public func perform(
        observation: ExternalOperationObservation,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop,
        operation: @escaping @Sendable (
            ExternalOperationBoundaryControl
        ) async throws -> ExternalOperationBoundaryCompletion
    ) async throws -> ExternalOperationBoundaryResult {
        let timestamp = try await clock.now()
        guard authorized.authorization.isUsable(at: timestamp) else {
            throw AgentContractError.authorizationExpired
        }
        try await policyValidator.validateCurrentAuthorization(
            receipt: authorized.authorization,
            prepared: authorized.prepared,
            trustedRunAuthority: authorized.trustedRunAuthority,
            at: timestamp
        )
        guard attempt.isBound(to: authorized.prepared) else {
            throw AgentContractError.authorizationBindingMismatch("operation attempt")
        }
        guard hop.isBound(to: attempt, prepared: authorized.prepared),
              hop.destination == observation.destination
        else {
            throw AgentContractError.authorizationBindingMismatch("operation boundary hop")
        }
        guard observation.isWithin(authorized.prepared.plan),
              observation.payloadDigest == authorized.authorization.payloadDigest,
              observation.idempotencyKey == attempt.idempotencyKey
        else {
            throw AgentContractError.authorizationBindingMismatch("observed operation widened")
        }
        guard !consumedHops.contains(hop.fingerprint),
              pendingHops.insert(hop.fingerprint).inserted
        else {
            throw AgentContractError.authorizationBindingMismatch("duplicate boundary hop")
        }
        let durablyClaimed: Bool
        do {
            durablyClaimed = try await attemptLedger.claimBoundaryHop(
                approvalID: authorized.authorization.id,
                preparedRequestFingerprint: authorized.prepared.fingerprint,
                attempt: attempt,
                hop: hop
            )
        } catch {
            pendingHops.remove(hop.fingerprint)
            throw error
        }
        pendingHops.remove(hop.fingerprint)
        guard durablyClaimed else {
            throw AgentContractError.authorizationBindingMismatch("durable duplicate boundary hop")
        }
        consumedHops.insert(hop.fingerprint)
        let control = ExternalOperationBoundaryControl(
            maximumResponseBytes: observation.responseBytesLimit
        )
        let completion: ExternalOperationBoundaryCompletion
        do {
            completion = try await operation(control)
        } catch {
            _ = await control.close()
            throw error
        }
        let responseBytes = await control.close()
        return ExternalOperationBoundaryResult(
            completion: completion,
            responseBytes: responseBytes
        )
    }
}

private extension ExternalOperationPlan {
    var permitsConversationScopedApproval: Bool {
        let reusableReadEffects: Set<AgentEffect> = [.localRead, .privateDataRead, .networkRead]
        return !effects.isEmpty
            && Set(effects).isSubset(of: reusableReadEffects)
            && idempotency == .pureRead
            && !effects.contains(.unknownExternal)
    }
}
