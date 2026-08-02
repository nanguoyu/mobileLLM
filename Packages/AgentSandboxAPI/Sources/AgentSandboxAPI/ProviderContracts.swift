// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Provider-neutral sandbox features negotiated before any execution is started.
public enum SandboxFeature: String, CaseIterable, Hashable, Codable, Sendable, Comparable {
    case artifactOutput
    case cancellation
    case checkpointResume
    case codeExecution
    case filesystemRead
    case filesystemWrite
    case networkAccess
    case processExecution
    case progressEvents
    case structuredOutput
    case workspaceReuse

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Versioned, stable identity advertised by an injected sandbox provider.
public struct AgentSandboxProviderDescriptor: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.provider-descriptor"

    /// Stable namespace registered by trusted local composition code.
    public let providerID: String
    /// Wire protocol used to interpret this descriptor.
    public let protocolVersion: SemanticVersion
    /// Safe display label; never used as an authority identity.
    public let displayName: String
    /// Provider implementation version for diagnostics and compatibility policy.
    public let implementationVersion: SemanticVersion
    /// Finite protocol versions the provider claims to implement.
    public let supportedProtocolVersions: [SemanticVersion]
    /// Positive revision of the local trust relationship expected by the provider.
    public let trustRevision: UInt64
    /// Version of the provider's capability vocabulary.
    public let capabilitySchemaVersion: UInt16
    /// Deterministic descriptor digest pinned by local registration policy.
    public let fingerprint: StableDigest

    public init(
        providerID: String,
        displayName: String,
        implementationVersion: SemanticVersion,
        supportedProtocolVersions: some Sequence<SemanticVersion>,
        trustRevision: UInt64,
        capabilitySchemaVersion: UInt16 = 1,
        protocolVersion: SemanticVersion = AgentContractVersion.currentProtocol
    ) throws {
        let versions = SandboxContractValidation.canonicalVersions(supportedProtocolVersions)
        guard SandboxContractValidation.namespace(providerID),
              SandboxContractValidation.safeText(displayName, maximumUTF8Bytes: 256),
              !versions.isEmpty,
              versions.contains(protocolVersion),
              protocolVersion.major == AgentContractVersion.currentProtocol.major,
              versions.allSatisfy({ $0.prereleaseIdentifiers.isEmpty }),
              trustRevision > 0,
              capabilitySchemaVersion > 0
        else { throw AgentSandboxAPIError.invalidValue("provider descriptor") }
        self.providerID = providerID
        self.protocolVersion = protocolVersion
        self.displayName = displayName
        self.implementationVersion = implementationVersion
        self.supportedProtocolVersions = versions
        self.trustRevision = trustRevision
        self.capabilitySchemaVersion = capabilitySchemaVersion
        fingerprint = try Self.makeFingerprint(
            providerID: providerID,
            protocolVersion: protocolVersion,
            implementationVersion: implementationVersion,
            supportedProtocolVersions: versions,
            trustRevision: trustRevision,
            capabilitySchemaVersion: capabilitySchemaVersion
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        let encodedVersions = try container.decode(
            [SemanticVersion].self,
            forKey: .supportedProtocolVersions
        )
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                providerID: container.decode(String.self, forKey: .providerID),
                displayName: container.decode(String.self, forKey: .displayName),
                implementationVersion: container.decode(SemanticVersion.self, forKey: .implementationVersion),
                supportedProtocolVersions: encodedVersions,
                trustRevision: container.decode(UInt64.self, forKey: .trustRevision),
                capabilitySchemaVersion: container.decode(UInt16.self, forKey: .capabilitySchemaVersion),
                protocolVersion: container.decode(SemanticVersion.self, forKey: .protocolVersion)
            )
            guard decoded.supportedProtocolVersions == encodedVersions,
                  decoded.fingerprint == encodedFingerprint
            else {
                throw AgentSandboxAPIError.descriptorFingerprintMismatch
            }
            return decoded
        }
    }

    private struct FingerprintMaterial: Encodable {
        let providerID: String
        let protocolVersion: SemanticVersion
        let implementationVersion: SemanticVersion
        let supportedProtocolVersions: [SemanticVersion]
        let trustRevision: UInt64
        let capabilitySchemaVersion: UInt16
    }

    private static func makeFingerprint(
        providerID: String,
        protocolVersion: SemanticVersion,
        implementationVersion: SemanticVersion,
        supportedProtocolVersions: [SemanticVersion],
        trustRevision: UInt64,
        capabilitySchemaVersion: UInt16
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-provider-descriptor.v1",
            value: FingerprintMaterial(
                providerID: providerID,
                protocolVersion: protocolVersion,
                implementationVersion: implementationVersion,
                supportedProtocolVersions: supportedProtocolVersions,
                trustRevision: trustRevision,
                capabilitySchemaVersion: capabilitySchemaVersion
            )
        )
    }
}

/// Versioned self-report from a provider. It confers no authority by itself.
public struct SandboxCapabilities: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.capabilities"

    public let providerID: String
    public let protocolVersion: SemanticVersion
    public let descriptorFingerprint: StableDigest
    public let supportedProtocolVersions: [SemanticVersion]
    public let features: [SandboxFeature]
    public let maximumAuthority: AgentAuthorityScope
    public let maximumBudget: AgentBudget
    public let maximumConcurrentExecutions: UInt16
    public let reportRevision: UInt64
    public let fingerprint: StableDigest

    public init(
        providerID: String,
        descriptorFingerprint: StableDigest,
        supportedProtocolVersions: some Sequence<SemanticVersion>,
        features: some Sequence<SandboxFeature>,
        maximumAuthority: AgentAuthorityScope,
        maximumBudget: AgentBudget,
        maximumConcurrentExecutions: UInt16,
        reportRevision: UInt64,
        protocolVersion: SemanticVersion = AgentContractVersion.currentProtocol
    ) throws {
        let versions = SandboxContractValidation.canonicalVersions(supportedProtocolVersions)
        let features = Array(Set(features)).sorted()
        guard SandboxContractValidation.namespace(providerID),
              !versions.isEmpty,
              versions.contains(protocolVersion),
              protocolVersion.major == AgentContractVersion.currentProtocol.major,
              maximumConcurrentExecutions > 0,
              reportRevision > 0
        else { throw AgentSandboxAPIError.invalidValue("capability report") }
        self.providerID = providerID
        self.protocolVersion = protocolVersion
        self.descriptorFingerprint = descriptorFingerprint
        self.supportedProtocolVersions = versions
        self.features = features
        self.maximumAuthority = maximumAuthority
        self.maximumBudget = maximumBudget
        self.maximumConcurrentExecutions = maximumConcurrentExecutions
        self.reportRevision = reportRevision
        fingerprint = try Self.makeFingerprint(
            providerID: providerID,
            protocolVersion: protocolVersion,
            descriptorFingerprint: descriptorFingerprint,
            supportedProtocolVersions: versions,
            features: features,
            maximumAuthority: maximumAuthority,
            maximumBudget: maximumBudget,
            maximumConcurrentExecutions: maximumConcurrentExecutions,
            reportRevision: reportRevision
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        let encodedVersions = try container.decode(
            [SemanticVersion].self,
            forKey: .supportedProtocolVersions
        )
        let encodedFeatures = try container.decode([SandboxFeature].self, forKey: .features)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                providerID: container.decode(String.self, forKey: .providerID),
                descriptorFingerprint: container.decode(StableDigest.self, forKey: .descriptorFingerprint),
                supportedProtocolVersions: encodedVersions,
                features: encodedFeatures,
                maximumAuthority: container.decode(AgentAuthorityScope.self, forKey: .maximumAuthority),
                maximumBudget: container.decode(AgentBudget.self, forKey: .maximumBudget),
                maximumConcurrentExecutions: container.decode(
                    UInt16.self,
                    forKey: .maximumConcurrentExecutions
                ),
                reportRevision: container.decode(UInt64.self, forKey: .reportRevision),
                protocolVersion: container.decode(SemanticVersion.self, forKey: .protocolVersion)
            )
            guard decoded.supportedProtocolVersions == encodedVersions,
                  decoded.features == encodedFeatures,
                  decoded.fingerprint == encodedFingerprint
            else {
                throw AgentSandboxAPIError.capabilityReportBindingMismatch
            }
            return decoded
        }
    }

    private struct FingerprintMaterial: Encodable {
        let providerID: String
        let protocolVersion: SemanticVersion
        let descriptorFingerprint: StableDigest
        let supportedProtocolVersions: [SemanticVersion]
        let features: [SandboxFeature]
        let maximumAuthority: AgentAuthorityScope
        let maximumBudget: AgentBudget
        let maximumConcurrentExecutions: UInt16
        let reportRevision: UInt64
    }

    private static func makeFingerprint(
        providerID: String,
        protocolVersion: SemanticVersion,
        descriptorFingerprint: StableDigest,
        supportedProtocolVersions: [SemanticVersion],
        features: [SandboxFeature],
        maximumAuthority: AgentAuthorityScope,
        maximumBudget: AgentBudget,
        maximumConcurrentExecutions: UInt16,
        reportRevision: UInt64
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-capabilities.v1",
            value: FingerprintMaterial(
                providerID: providerID,
                protocolVersion: protocolVersion,
                descriptorFingerprint: descriptorFingerprint,
                supportedProtocolVersions: supportedProtocolVersions,
                features: features,
                maximumAuthority: maximumAuthority,
                maximumBudget: maximumBudget,
                maximumConcurrentExecutions: maximumConcurrentExecutions,
                reportRevision: reportRevision
            )
        )
    }
}

/// Trusted local registration policy. Provider self-report is always intersected with this value.
public struct RegisteredSandboxProviderPolicy: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.registered-provider-policy"

    public let providerID: String
    public let descriptorFingerprint: StableDigest
    public let trustRevision: UInt64
    public let allowedProtocolVersions: [SemanticVersion]
    public let allowedFeatures: [SandboxFeature]
    public let maximumAuthority: AgentAuthorityScope
    public let maximumBudget: AgentBudget
    public let maximumConcurrentExecutions: UInt16
    public let policyRevision: UInt64
    public let fingerprint: StableDigest

    public init(
        providerID: String,
        descriptorFingerprint: StableDigest,
        trustRevision: UInt64,
        allowedProtocolVersions: some Sequence<SemanticVersion>,
        allowedFeatures: some Sequence<SandboxFeature>,
        maximumAuthority: AgentAuthorityScope,
        maximumBudget: AgentBudget,
        maximumConcurrentExecutions: UInt16,
        policyRevision: UInt64
    ) throws {
        let versions = SandboxContractValidation.canonicalVersions(allowedProtocolVersions)
        let features = Array(Set(allowedFeatures)).sorted()
        guard SandboxContractValidation.namespace(providerID),
              trustRevision > 0,
              !versions.isEmpty,
              maximumConcurrentExecutions > 0,
              policyRevision > 0
        else { throw AgentSandboxAPIError.invalidValue("provider policy") }
        self.providerID = providerID
        self.descriptorFingerprint = descriptorFingerprint
        self.trustRevision = trustRevision
        self.allowedProtocolVersions = versions
        self.allowedFeatures = features
        self.maximumAuthority = maximumAuthority
        self.maximumBudget = maximumBudget
        self.maximumConcurrentExecutions = maximumConcurrentExecutions
        self.policyRevision = policyRevision
        fingerprint = try Self.makeFingerprint(
            providerID: providerID,
            descriptorFingerprint: descriptorFingerprint,
            trustRevision: trustRevision,
            allowedProtocolVersions: versions,
            allowedFeatures: features,
            maximumAuthority: maximumAuthority,
            maximumBudget: maximumBudget,
            maximumConcurrentExecutions: maximumConcurrentExecutions,
            policyRevision: policyRevision
        )
    }

    /// Computes and pins the least-authority intersection of local policy and provider claims.
    public func negotiate(
        descriptor: AgentSandboxProviderDescriptor,
        capabilities: SandboxCapabilities
    ) throws -> NegotiatedSandboxCapabilities {
        let report = capabilities
        guard providerID == descriptor.providerID, providerID == report.providerID else {
            throw AgentSandboxAPIError.providerIdentityMismatch
        }
        guard descriptorFingerprint == descriptor.fingerprint else {
            throw AgentSandboxAPIError.descriptorFingerprintMismatch
        }
        guard trustRevision == descriptor.trustRevision else {
            throw AgentSandboxAPIError.trustRevisionMismatch
        }
        guard report.descriptorFingerprint == descriptor.fingerprint else {
            throw AgentSandboxAPIError.capabilityReportBindingMismatch
        }
        guard descriptor.protocolVersion == report.protocolVersion else {
            throw AgentSandboxAPIError.incompatibleProtocol
        }

        let versions = Set(allowedProtocolVersions)
            .intersection(descriptor.supportedProtocolVersions)
            .intersection(report.supportedProtocolVersions)
            .filter { version in
                version.major == AgentContractVersion.currentProtocol.major
                    && !AgentContractVersion.currentProtocol.hasLowerSemanticPrecedence(than: version)
            }
            .sorted()
        guard let selectedVersion = versions.last else {
            throw AgentSandboxAPIError.incompatibleProtocol
        }
        let features = Array(Set(allowedFeatures).intersection(report.features)).sorted()
        let authority = try SandboxContractValidation.authorityIntersection(
            maximumAuthority,
            report.maximumAuthority
        )
        let budget = try SandboxContractValidation.budgetIntersection(maximumBudget, report.maximumBudget)
        return try NegotiatedSandboxCapabilities(
            providerID: providerID,
            selectedProtocolVersion: selectedVersion,
            descriptorFingerprint: descriptor.fingerprint,
            capabilityReportFingerprint: report.fingerprint,
            registeredPolicyFingerprint: fingerprint,
            trustRevision: trustRevision,
            features: features,
            maximumAuthority: authority,
            maximumBudget: budget,
            maximumConcurrentExecutions: min(
                maximumConcurrentExecutions,
                report.maximumConcurrentExecutions
            )
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        let encodedVersions = try container.decode(
            [SemanticVersion].self,
            forKey: .allowedProtocolVersions
        )
        let encodedFeatures = try container.decode([SandboxFeature].self, forKey: .allowedFeatures)
        self = try SandboxContractValidation.rethrowAsCorruption(decoder) {
            let decoded = try Self(
                providerID: container.decode(String.self, forKey: .providerID),
                descriptorFingerprint: container.decode(StableDigest.self, forKey: .descriptorFingerprint),
                trustRevision: container.decode(UInt64.self, forKey: .trustRevision),
                allowedProtocolVersions: encodedVersions,
                allowedFeatures: encodedFeatures,
                maximumAuthority: container.decode(AgentAuthorityScope.self, forKey: .maximumAuthority),
                maximumBudget: container.decode(AgentBudget.self, forKey: .maximumBudget),
                maximumConcurrentExecutions: container.decode(
                    UInt16.self,
                    forKey: .maximumConcurrentExecutions
                ),
                policyRevision: container.decode(UInt64.self, forKey: .policyRevision)
            )
            guard decoded.allowedProtocolVersions == encodedVersions,
                  decoded.allowedFeatures == encodedFeatures,
                  decoded.fingerprint == encodedFingerprint
            else {
                throw AgentSandboxAPIError.requestBindingMismatch
            }
            return decoded
        }
    }

    private struct FingerprintMaterial: Encodable {
        let providerID: String
        let descriptorFingerprint: StableDigest
        let trustRevision: UInt64
        let allowedProtocolVersions: [SemanticVersion]
        let allowedFeatures: [SandboxFeature]
        let maximumAuthority: AgentAuthorityScope
        let maximumBudget: AgentBudget
        let maximumConcurrentExecutions: UInt16
        let policyRevision: UInt64
    }

    private static func makeFingerprint(
        providerID: String,
        descriptorFingerprint: StableDigest,
        trustRevision: UInt64,
        allowedProtocolVersions: [SemanticVersion],
        allowedFeatures: [SandboxFeature],
        maximumAuthority: AgentAuthorityScope,
        maximumBudget: AgentBudget,
        maximumConcurrentExecutions: UInt16,
        policyRevision: UInt64
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-provider-policy.v1",
            value: FingerprintMaterial(
                providerID: providerID,
                descriptorFingerprint: descriptorFingerprint,
                trustRevision: trustRevision,
                allowedProtocolVersions: allowedProtocolVersions,
                allowedFeatures: allowedFeatures,
                maximumAuthority: maximumAuthority,
                maximumBudget: maximumBudget,
                maximumConcurrentExecutions: maximumConcurrentExecutions,
                policyRevision: policyRevision
            )
        )
    }
}

/// Immutable result of local policy negotiation. Every request pins this complete value.
public struct NegotiatedSandboxCapabilities: Hashable, Codable, Sendable, AgentContractPayload {
    public static let schemaID = "com.mobilellm.agent.sandbox.negotiated-capabilities"

    public let providerID: String
    public let selectedProtocolVersion: SemanticVersion
    public let descriptorFingerprint: StableDigest
    public let capabilityReportFingerprint: StableDigest
    public let registeredPolicyFingerprint: StableDigest
    public let trustRevision: UInt64
    public let features: [SandboxFeature]
    public let maximumAuthority: AgentAuthorityScope
    public let maximumBudget: AgentBudget
    public let maximumConcurrentExecutions: UInt16
    public let fingerprint: StableDigest

    fileprivate init(
        providerID: String,
        selectedProtocolVersion: SemanticVersion,
        descriptorFingerprint: StableDigest,
        capabilityReportFingerprint: StableDigest,
        registeredPolicyFingerprint: StableDigest,
        trustRevision: UInt64,
        features: [SandboxFeature],
        maximumAuthority: AgentAuthorityScope,
        maximumBudget: AgentBudget,
        maximumConcurrentExecutions: UInt16
    ) throws {
        self.providerID = providerID
        self.selectedProtocolVersion = selectedProtocolVersion
        self.descriptorFingerprint = descriptorFingerprint
        self.capabilityReportFingerprint = capabilityReportFingerprint
        self.registeredPolicyFingerprint = registeredPolicyFingerprint
        self.trustRevision = trustRevision
        self.features = features
        self.maximumAuthority = maximumAuthority
        self.maximumBudget = maximumBudget
        self.maximumConcurrentExecutions = maximumConcurrentExecutions
        fingerprint = try Self.makeFingerprint(
            providerID: providerID,
            selectedProtocolVersion: selectedProtocolVersion,
            descriptorFingerprint: descriptorFingerprint,
            capabilityReportFingerprint: capabilityReportFingerprint,
            registeredPolicyFingerprint: registeredPolicyFingerprint,
            trustRevision: trustRevision,
            features: features,
            maximumAuthority: maximumAuthority,
            maximumBudget: maximumBudget,
            maximumConcurrentExecutions: maximumConcurrentExecutions
        )
    }

    /// Recomputes negotiation from trusted local inputs and requires an exact match.
    public func validate(
        against policy: RegisteredSandboxProviderPolicy,
        descriptor: AgentSandboxProviderDescriptor,
        capabilities: SandboxCapabilities
    ) throws {
        guard try policy.negotiate(descriptor: descriptor, capabilities: capabilities) == self else {
            throw AgentSandboxAPIError.negotiatedCapabilityMismatch
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let providerID = try container.decode(String.self, forKey: .providerID)
        let version = try container.decode(SemanticVersion.self, forKey: .selectedProtocolVersion)
        let descriptor = try container.decode(StableDigest.self, forKey: .descriptorFingerprint)
        let report = try container.decode(StableDigest.self, forKey: .capabilityReportFingerprint)
        let policy = try container.decode(StableDigest.self, forKey: .registeredPolicyFingerprint)
        let trustRevision = try container.decode(UInt64.self, forKey: .trustRevision)
        let features = try container.decode([SandboxFeature].self, forKey: .features)
        let authority = try container.decode(AgentAuthorityScope.self, forKey: .maximumAuthority)
        let budget = try container.decode(AgentBudget.self, forKey: .maximumBudget)
        let concurrency = try container.decode(UInt16.self, forKey: .maximumConcurrentExecutions)
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        let canonicalFeatures = Array(Set(features)).sorted()
        guard SandboxContractValidation.namespace(providerID),
              version.major == AgentContractVersion.currentProtocol.major,
              trustRevision > 0,
              features == canonicalFeatures,
              concurrency > 0
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid negotiation")
            )
        }
        try self.init(
            providerID: providerID,
            selectedProtocolVersion: version,
            descriptorFingerprint: descriptor,
            capabilityReportFingerprint: report,
            registeredPolicyFingerprint: policy,
            trustRevision: trustRevision,
            features: features,
            maximumAuthority: authority,
            maximumBudget: budget,
            maximumConcurrentExecutions: concurrency
        )
        guard fingerprint == encodedFingerprint else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Negotiation fingerprint mismatch")
            )
        }
    }

    private struct FingerprintMaterial: Encodable {
        let providerID: String
        let selectedProtocolVersion: SemanticVersion
        let descriptorFingerprint: StableDigest
        let capabilityReportFingerprint: StableDigest
        let registeredPolicyFingerprint: StableDigest
        let trustRevision: UInt64
        let features: [SandboxFeature]
        let maximumAuthority: AgentAuthorityScope
        let maximumBudget: AgentBudget
        let maximumConcurrentExecutions: UInt16
    }

    private static func makeFingerprint(
        providerID: String,
        selectedProtocolVersion: SemanticVersion,
        descriptorFingerprint: StableDigest,
        capabilityReportFingerprint: StableDigest,
        registeredPolicyFingerprint: StableDigest,
        trustRevision: UInt64,
        features: [SandboxFeature],
        maximumAuthority: AgentAuthorityScope,
        maximumBudget: AgentBudget,
        maximumConcurrentExecutions: UInt16
    ) throws -> StableDigest {
        try SandboxContractValidation.fingerprint(
            domain: "agent-sandbox-negotiation.v1",
            value: FingerprintMaterial(
                providerID: providerID,
                selectedProtocolVersion: selectedProtocolVersion,
                descriptorFingerprint: descriptorFingerprint,
                capabilityReportFingerprint: capabilityReportFingerprint,
                registeredPolicyFingerprint: registeredPolicyFingerprint,
                trustRevision: trustRevision,
                features: features,
                maximumAuthority: maximumAuthority,
                maximumBudget: maximumBudget,
                maximumConcurrentExecutions: maximumConcurrentExecutions
            )
        )
    }
}
