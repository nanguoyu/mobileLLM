// SPDX-License-Identifier: MIT

import Foundation

/// A stable namespaced authority token interpreted only by locally trusted policy.
public struct AgentCapability: Hashable, Codable, Sendable, Comparable,
    CustomStringConvertible
{
    /// The lowercase dot-separated capability identifier.
    public let rawValue: String

    /// Creates a capability after validating its stable namespaced representation.
    public init(rawValue: String) throws {
        guard Self.isValid(rawValue) else { throw AgentContractError.invalidName("capability") }
        self.rawValue = rawValue
    }

    /// The namespaced capability identifier.
    public var description: String { rawValue }

    /// Orders capabilities by their stable wire identity.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Decodes one namespaced capability string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(rawValue: encoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid namespaced capability"
            )
        }
    }

    /// Encodes one namespaced capability string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Authority to read app-owned local data.
    public static let localRead = try! Self(rawValue: "local.read")
    /// Authority to write app-owned local data.
    public static let localWrite = try! Self(rawValue: "local.write")
    /// Authority to access private user or system data.
    public static let privateDataRead = try! Self(rawValue: "private-data.read")
    /// Authority to read from a network boundary.
    public static let networkRead = try! Self(rawValue: "network.read")
    /// Authority to invoke an unclassified external operation under conservative policy.
    public static let unknownExternal = try! Self(rawValue: "external.unknown")
    /// Authority to write to an external system.
    public static let externalWrite = try! Self(rawValue: "external.write")
    /// Authority to communicate with a third party.
    public static let externalCommunication = try! Self(rawValue: "external.communication")
    /// Authority to perform a destructive operation.
    public static let destructive = try! Self(rawValue: "external.destructive")
    /// Authority to perform a financial operation.
    public static let financial = try! Self(rawValue: "external.financial")
    /// Authority to execute code in an injected sandbox provider.
    public static let codeExecution = try! Self(rawValue: "sandbox.code-execution")

    private static func isValid(_ value: String) -> Bool {
        AgentWireValidation.isLowercaseNamespace(value, maximumLength: 128)
    }
}

/// An immutable, deterministically encoded set of capabilities.
public struct AgentCapabilitySet: Hashable, Codable, Sendable {
    /// Capabilities in stable sorted order.
    public let values: [AgentCapability]

    /// Creates a set, removing duplicates and normalizing order.
    public init(_ values: some Sequence<AgentCapability>) {
        self.values = Array(Set(values)).sorted()
    }

    /// Returns whether the set contains one exact capability.
    public func contains(_ capability: AgentCapability) -> Bool {
        values.binarySearch(capability)
    }

    /// Returns whether every capability in this set exists in another set.
    public func isSubset(of other: Self) -> Bool {
        Set(values).isSubset(of: Set(other.values))
    }

    /// Returns whether this set is a strict subset of another set.
    public func isStrictSubset(of other: Self) -> Bool {
        values != other.values && isSubset(of: other)
    }

    /// A deterministic digest used to bind grants and child ceilings.
    public var fingerprint: StableDigest {
        StableDigest.fingerprint(
            domain: "agent-capability-set.v1",
            components: values.map { Data($0.rawValue.utf8) }
        )
    }

    /// Decodes a capability array and normalizes it as a mathematical set.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode([AgentCapability].self)
        let canonical = Array(Set(encoded)).sorted()
        guard encoded == canonical else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Capabilities must be unique and canonically ordered"
            )
        }
        self.init(encoded)
    }

    /// Encodes the normalized capability array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// An extensible bounded authority constraint whose child values may only be removed.
public struct AgentAuthorityConstraint: Hashable, Codable, Sendable, Comparable {
    /// Stable locally interpreted constraint key.
    public let key: String

    /// Exact allowed values in stable order.
    public let allowedValues: [String]

    /// Creates a normalized enumerable authority constraint.
    public init(key: String, allowedValues: some Sequence<String>) throws {
        let normalizedValues = Array(Set(allowedValues)).sorted()
        guard AgentWireValidation.isLowercaseNamespace(key, maximumLength: 128),
              !normalizedValues.isEmpty,
              normalizedValues.allSatisfy({
                  AgentWireValidation.isNonblankControlFree($0, maximumLength: 2_048)
              })
        else { throw AgentContractError.invalidName("authority constraint") }
        self.key = key
        self.allowedValues = normalizedValues
    }

    /// Returns whether every value is allowed by the same parent constraint key.
    public func isSubset(of parent: Self) -> Bool {
        key == parent.key && Set(allowedValues).isSubset(of: Set(parent.allowedValues))
    }

    /// Orders constraints by key and then by their normalized values.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        return lhs.allowedValues.lexicographicallyPrecedes(rhs.allowedValues)
    }

    /// Decodes and rejects duplicate or noncanonically ordered values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        let values = try container.decode([String].self, forKey: .allowedValues)
        do {
            try self.init(key: key, allowedValues: values)
            guard allowedValues == values else {
                throw AgentContractError.invalidName("noncanonical authority constraint")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case allowedValues
    }
}

/// Complete deny-by-default authority, including both verbs and bounded resource scope.
public struct AgentAuthorityScope: Hashable, Codable, Sendable {
    /// Allowed operation capabilities.
    public let capabilities: AgentCapabilitySet
    /// Exact external destinations that may appear in prepared plans.
    public let destinations: [ExternalDestination]
    /// Data categories that may cross a protected boundary.
    public let dataCategories: [AgentDataCategory]
    /// Existing artifacts that a step may read, export, or mount.
    public let artifactIDs: [ArtifactID]
    /// Opaque secret references that a step may resolve at execution time.
    public let secretReferenceIDs: [SecretReferenceID]
    /// Opaque sandbox workspaces that a step may address.
    public let workspaceIDs: [SandboxWorkspaceHandleID]
    /// Opaque sandbox checkpoints that a step may resume.
    public let checkpointIDs: [SandboxCheckpointHandleID]
    /// Additional locally interpreted enumerable restrictions.
    public let constraints: [AgentAuthorityConstraint]

    /// Creates a normalized, immutable authority scope.
    public init(
        capabilities: AgentCapabilitySet,
        destinations: some Sequence<ExternalDestination> = [],
        dataCategories: some Sequence<AgentDataCategory> = [],
        artifactIDs: some Sequence<ArtifactID> = [],
        secretReferenceIDs: some Sequence<SecretReferenceID> = [],
        workspaceIDs: some Sequence<SandboxWorkspaceHandleID> = [],
        checkpointIDs: some Sequence<SandboxCheckpointHandleID> = [],
        constraints: some Sequence<AgentAuthorityConstraint> = []
    ) throws {
        let normalizedConstraints = Array(Set(constraints)).sorted()
        guard Set(normalizedConstraints.map(\.key)).count == normalizedConstraints.count else {
            throw AgentContractError.invalidName("duplicate authority constraint key")
        }
        self.capabilities = capabilities
        self.destinations = Array(Set(destinations)).sorted()
        self.dataCategories = Array(Set(dataCategories)).sorted()
        self.artifactIDs = Array(Set(artifactIDs)).sorted { $0.description < $1.description }
        self.secretReferenceIDs = Array(Set(secretReferenceIDs)).sorted { $0.description < $1.description }
        self.workspaceIDs = Array(Set(workspaceIDs)).sorted { $0.description < $1.description }
        self.checkpointIDs = Array(Set(checkpointIDs)).sorted { $0.description < $1.description }
        self.constraints = normalizedConstraints
    }

    /// A deny-by-default empty authority scope.
    public static let empty = try! Self(capabilities: .init([]))

    /// Returns whether every verb and every resource dimension is contained by a parent scope.
    public func isSubset(of parent: Self) -> Bool {
        guard capabilities.isSubset(of: parent.capabilities),
              Set(destinations).isSubset(of: Set(parent.destinations)),
              Set(dataCategories).isSubset(of: Set(parent.dataCategories)),
              Set(artifactIDs).isSubset(of: Set(parent.artifactIDs)),
              Set(secretReferenceIDs).isSubset(of: Set(parent.secretReferenceIDs)),
              Set(workspaceIDs).isSubset(of: Set(parent.workspaceIDs)),
              Set(checkpointIDs).isSubset(of: Set(parent.checkpointIDs))
        else { return false }
        let parentByKey = Dictionary(uniqueKeysWithValues: parent.constraints.map { ($0.key, $0) })
        for child in constraints {
            guard let parentConstraint = parentByKey[child.key],
                  child.isSubset(of: parentConstraint)
            else { return false }
        }
        return true
    }

    /// Returns whether this scope removes at least one authority element from its parent.
    public func isStrictSubset(of parent: Self) -> Bool {
        self != parent && isSubset(of: parent)
    }

    /// A deterministic digest binding every scoped authority dimension.
    public var fingerprint: StableDigest {
        var components = capabilities.values.map { Data("capability:\($0.rawValue)".utf8) }
        components += destinations.map { Data("destination:\($0.kind.rawValue):\($0.normalizedIdentity)".utf8) }
        components += dataCategories.map { Data("data:\($0.rawValue)".utf8) }
        components += artifactIDs.map { Data("artifact:\($0.description)".utf8) }
        components += secretReferenceIDs.map { Data("secret:\($0.description)".utf8) }
        components += workspaceIDs.map { Data("workspace:\($0.description)".utf8) }
        components += checkpointIDs.map { Data("checkpoint:\($0.description)".utf8) }
        components += constraints.flatMap { constraint in
            constraint.allowedValues.map { Data("constraint:\(constraint.key):\($0)".utf8) }
        }
        return StableDigest.fingerprint(domain: "agent-authority-scope.v1", components: components)
    }

    /// Decodes and normalizes every authority dimension.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let destinations = try container.decode([ExternalDestination].self, forKey: .destinations)
        let categories = try container.decode([AgentDataCategory].self, forKey: .dataCategories)
        let artifacts = try container.decode([ArtifactID].self, forKey: .artifactIDs)
        let secrets = try container.decode([SecretReferenceID].self, forKey: .secretReferenceIDs)
        let workspaces = try container.decode([SandboxWorkspaceHandleID].self, forKey: .workspaceIDs)
        let checkpoints = try container.decode([SandboxCheckpointHandleID].self, forKey: .checkpointIDs)
        let constraints = try container.decode([AgentAuthorityConstraint].self, forKey: .constraints)
        do {
            try self.init(
                capabilities: container.decode(AgentCapabilitySet.self, forKey: .capabilities),
                destinations: destinations,
                dataCategories: categories,
                artifactIDs: artifacts,
                secretReferenceIDs: secrets,
                workspaceIDs: workspaces,
                checkpointIDs: checkpoints,
                constraints: constraints
            )
            guard self.destinations == destinations,
                  self.dataCategories == categories,
                  self.artifactIDs == artifacts,
                  self.secretReferenceIDs == secrets,
                  self.workspaceIDs == workspaces,
                  self.checkpointIDs == checkpoints,
                  self.constraints == constraints
            else { throw AgentContractError.invalidName("noncanonical authority scope") }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities, destinations, dataCategories, artifactIDs, secretReferenceIDs
        case workspaceIDs, checkpointIDs, constraints
    }
}

/// The immutable maximum authority frozen when a run is created.
public struct RunCapabilityCeiling: Hashable, Codable, Sendable {
    /// Every verb and bounded resource that any step in the run may possibly receive.
    public let authority: AgentAuthorityScope

    /// Convenience access to the ceiling's operation capabilities.
    public var capabilities: AgentCapabilitySet { authority.capabilities }

    /// Creates a trusted root ceiling from a complete scoped authority value.
    public init(authority: AgentAuthorityScope) {
        self.authority = authority
    }

    /// Creates a local-only ceiling with no external resource scope.
    public init(capabilities: AgentCapabilitySet) {
        authority = try! AgentAuthorityScope(capabilities: capabilities)
    }

    /// A deterministic digest used to bind grants, requests, and future child runs.
    public var fingerprint: StableDigest { authority.fingerprint }

    /// Creates a child ceiling and fails closed unless it attenuates this ceiling.
    public func attenuating(
        to childAuthority: AgentAuthorityScope,
        requireStrict: Bool = true
    ) throws -> RunCapabilityCeiling {
        guard childAuthority.isSubset(of: authority) else {
            throw AgentContractError.capabilityEscalation(
                childAuthority.capabilities.values.filter { !capabilities.contains($0) }
            )
        }
        if requireStrict, !childAuthority.isStrictSubset(of: authority) {
            throw AgentContractError.capabilityNotStrictlyAttenuated
        }
        return RunCapabilityCeiling(authority: childAuthority)
    }
}

/// The immutable subset of a run's authority made available to one step.
public struct StepCapabilityGrant: Hashable, Codable, Sendable {
    /// The ceiling against which this grant was validated.
    public let runCeiling: RunCapabilityCeiling

    /// The exact scoped authority granted to the step.
    public let authority: AgentAuthorityScope

    /// Convenience access to the grant's operation capabilities.
    public var capabilities: AgentCapabilitySet { authority.capabilities }

    /// Creates a self-validating grant that cannot exceed its embedded run ceiling.
    public init(
        runCeiling: RunCapabilityCeiling,
        authority: AgentAuthorityScope
    ) throws {
        guard authority.isSubset(of: runCeiling.authority) else {
            var missingCapabilities: [AgentCapability] = []
            for capability in authority.capabilities.values
                where !runCeiling.capabilities.contains(capability)
            {
                missingCapabilities.append(capability)
            }
            throw AgentContractError.capabilityEscalation(missingCapabilities)
        }
        self.runCeiling = runCeiling
        self.authority = authority
    }

    /// Creates a local-only grant with no external resource scope.
    public init(
        runCeiling: RunCapabilityCeiling,
        capabilities: AgentCapabilitySet
    ) throws {
        try self.init(
            runCeiling: runCeiling,
            authority: AgentAuthorityScope(capabilities: capabilities)
        )
    }

    /// A deterministic digest binding both the ceiling and the attenuated grant.
    public var fingerprint: StableDigest {
        StableDigest.fingerprint(
            domain: "step-capability-grant.v1",
            components: [
                Data(runCeiling.fingerprint.rawValue.utf8),
                Data(authority.fingerprint.rawValue.utf8),
            ]
        )
    }

    /// Decodes and revalidates a grant rather than trusting serialized authority.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ceiling = try container.decode(RunCapabilityCeiling.self, forKey: .runCeiling)
        let authority = try container.decode(AgentAuthorityScope.self, forKey: .authority)
        do {
            try self.init(runCeiling: ceiling, authority: authority)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runCeiling
        case authority
    }
}

/// Non-serializable trust root issued by local runtime policy for one admitted run.
///
/// A decoded `RunCapabilityCeiling` is only a declaration. Executable authorization must also
/// carry this locally issued value, whose initializer is restricted to the AgentRuntime SPI.
public struct TrustedRunAuthority: Hashable, Sendable {
    /// Run whose declared ceiling was admitted by local policy.
    public let runID: AgentRunID
    /// Locally admitted ceiling, independent of attacker-controlled request decoding.
    public let ceiling: RunCapabilityCeiling
    /// Positive local policy revision used for admission and later revocation checks.
    public let policyRevision: UInt64

    /// Issues a trusted run authority after local policy admission.
    @_spi(AgentRuntime)
    public init(
        runID: AgentRunID,
        ceiling: RunCapabilityCeiling,
        policyRevision: UInt64
    ) throws {
        guard policyRevision > 0 else { throw AgentContractError.authorizationDenied }
        self.runID = runID
        self.ceiling = ceiling
        self.policyRevision = policyRevision
    }

    /// Validates a serialized step grant against this independent local trust root.
    public func validates(runID: AgentRunID, grant: StepCapabilityGrant) -> Bool {
        self.runID == runID
            && grant.runCeiling == ceiling
            && grant.authority.isSubset(of: ceiling.authority)
    }
}

/// The maximum externally observable effect class of an operation.
public enum AgentEffect: String, CaseIterable, Hashable, Codable, Sendable, Comparable {
    /// No external or private-data boundary is crossed.
    case localPure
    /// App-owned local data is read.
    case localRead
    /// App-owned local data is changed.
    case localWrite
    /// Private user or system data is read.
    case privateDataRead
    /// Data is read from a network destination.
    case networkRead
    /// An untrusted remote operation has unknown effects.
    case unknownExternal
    /// An external system is changed.
    case externalWrite
    /// Data is communicated to a third party.
    case externalCommunication
    /// An operation may irreversibly destroy data or publish content.
    case destructive
    /// An operation has financial consequences.
    case financial
    /// Untrusted or generated code is executed.
    case codeExecution

    /// Orders effects by their stable wire representation, not by severity.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Minimum locally trusted capability required for this effect, if any.
    public var minimumCapability: AgentCapability? {
        switch self {
        case .localPure: nil
        case .localRead: .localRead
        case .localWrite: .localWrite
        case .privateDataRead: .privateDataRead
        case .networkRead: .networkRead
        case .unknownExternal: .unknownExternal
        case .externalWrite: .externalWrite
        case .externalCommunication: .externalCommunication
        case .destructive: .destructive
        case .financial: .financial
        case .codeExecution: .codeExecution
        }
    }
}

private extension Array where Element == AgentCapability {
    func binarySearch(_ target: AgentCapability) -> Bool {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let distance = self.distance(from: lower, to: upper)
            let middle = index(lower, offsetBy: distance / 2)
            if self[middle] == target { return true }
            if self[middle] < target {
                lower = index(after: middle)
            } else {
                upper = middle
            }
        }
        return false
    }
}
