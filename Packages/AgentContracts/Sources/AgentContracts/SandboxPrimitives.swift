// SPDX-License-Identifier: MIT

import Foundation

/// Requested access mode for one declarative sandbox filesystem input.
public enum SandboxFilesystemAccess: String, CaseIterable, Hashable, Codable, Sendable {
    /// Read existing content without mutation.
    case readOnly
    /// Read and write within the explicitly bounded logical root.
    case readWrite
}

/// Declarative filesystem authority without choosing mounts, snapshots, or transport mechanics.
public struct SandboxFilesystemRequirement: Hashable, Codable, Sendable, Comparable {
    /// Stable logical root name interpreted by an injected provider adapter.
    public let logicalRoot: String
    /// Requested access mode.
    public let access: SandboxFilesystemAccess
    /// Existing artifacts made available under this logical root.
    public let artifactIDs: [ArtifactID]
    /// Maximum newly written bytes under this root.
    public let maximumWrittenBytes: UInt64

    /// Creates a normalized declarative filesystem requirement.
    public init(
        logicalRoot: String,
        access: SandboxFilesystemAccess,
        artifactIDs: some Sequence<ArtifactID> = [],
        maximumWrittenBytes: UInt64 = 0
    ) throws {
        guard AgentWireValidation.isLowercaseNamespace(logicalRoot, maximumLength: 128),
              access == .readWrite || maximumWrittenBytes == 0
        else { throw AgentContractError.invalidName("sandbox filesystem requirement") }
        self.logicalRoot = logicalRoot
        self.access = access
        self.artifactIDs = Array(Set(artifactIDs)).sorted { $0.description < $1.description }
        self.maximumWrittenBytes = maximumWrittenBytes
    }

    /// Decodes and rejects noncanonical artifact ordering or invalid access semantics.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let artifacts = try container.decode([ArtifactID].self, forKey: .artifactIDs)
        do {
            try self.init(
                logicalRoot: container.decode(String.self, forKey: .logicalRoot),
                access: container.decode(SandboxFilesystemAccess.self, forKey: .access),
                artifactIDs: artifacts,
                maximumWrittenBytes: container.decode(UInt64.self, forKey: .maximumWrittenBytes)
            )
            guard artifactIDs == artifacts else {
                throw AgentContractError.invalidName("noncanonical sandbox artifacts")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case logicalRoot, access, artifactIDs, maximumWrittenBytes
    }

    /// Orders requirements by stable logical root.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.logicalRoot < rhs.logicalRoot }
}

/// Declarative process and generated-code limits for an injected sandbox provider.
public struct SandboxProcessRequirement: Hashable, Codable, Sendable {
    /// Maximum number of simultaneously live processes.
    public let maximumConcurrentProcesses: UInt16
    /// Maximum total process launches.
    public let maximumProcessLaunches: UInt32
    /// Allowed language or runtime identifiers in stable order.
    public let allowedRuntimeIDs: [String]

    /// Creates bounded process requirements.
    public init(
        maximumConcurrentProcesses: UInt16,
        maximumProcessLaunches: UInt32,
        allowedRuntimeIDs: some Sequence<String>
    ) throws {
        let runtimes = Array(Set(allowedRuntimeIDs)).sorted()
        guard maximumConcurrentProcesses > 0,
              maximumProcessLaunches >= maximumConcurrentProcesses,
              !runtimes.isEmpty,
              runtimes.allSatisfy({ AgentWireValidation.isLowercaseNamespace($0, maximumLength: 128) })
        else { throw AgentContractError.invalidName("sandbox process requirement") }
        self.maximumConcurrentProcesses = maximumConcurrentProcesses
        self.maximumProcessLaunches = maximumProcessLaunches
        self.allowedRuntimeIDs = runtimes
    }

    /// Decodes and rejects noncanonical runtime identifiers or invalid process limits.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runtimes = try container.decode([String].self, forKey: .allowedRuntimeIDs)
        do {
            try self.init(
                maximumConcurrentProcesses: container.decode(UInt16.self, forKey: .maximumConcurrentProcesses),
                maximumProcessLaunches: container.decode(UInt32.self, forKey: .maximumProcessLaunches),
                allowedRuntimeIDs: runtimes
            )
            guard allowedRuntimeIDs == runtimes else {
                throw AgentContractError.invalidName("noncanonical sandbox runtimes")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumConcurrentProcesses, maximumProcessLaunches, allowedRuntimeIDs
    }
}

/// Complete provider-neutral sandbox requirement reserved by an agent request.
public struct SandboxRequirement: Hashable, Codable, Sendable {
    /// Minimum compatible sandbox protocol version.
    public let minimumProtocolVersion: SemanticVersion
    /// Optional exact existing workspace; nil requests a provider-created workspace.
    public let workspaceID: SandboxWorkspaceHandleID?
    /// Optional checkpoint from which an injected provider may resume.
    public let checkpointID: SandboxCheckpointHandleID?
    /// Immutable attenuated authority available to the sandbox execution.
    public let authority: AgentAuthorityScope
    /// Independent sandbox resource budget.
    public let budget: AgentBudget
    /// Declarative logical filesystem requirements.
    public let filesystem: [SandboxFilesystemRequirement]
    /// Exact network destinations available to sandbox adapters.
    public let networkDestinations: [ExternalDestination]
    /// Optional process/code requirements.
    public let process: SandboxProcessRequirement?
    /// Opaque secret references a provider may resolve through trusted injection.
    public let secretReferences: [SecretReference]

    /// Deterministic digest binding every declarative sandbox requirement dimension.
    public var fingerprint: StableDigest {
        var components: [Data] = [
            Data(minimumProtocolVersion.description.utf8),
            Data((workspaceID?.description ?? "").utf8),
            Data((checkpointID?.description ?? "").utf8),
            Data(authority.fingerprint.rawValue.utf8),
            Data(maximumBudgetFingerprint.rawValue.utf8),
        ]
        components += filesystem.map { root in
            Data(StableDigest.fingerprint(
                domain: "sandbox-filesystem-requirement.v1",
                components: [
                    Data(root.logicalRoot.utf8),
                    Data(root.access.rawValue.utf8),
                    Data(String(root.maximumWrittenBytes).utf8),
                ] + root.artifactIDs.map { Data($0.description.utf8) }
            ).rawValue.utf8)
        }
        components += networkDestinations.map {
            Data(StableDigest.fingerprint(
                domain: "sandbox-network-destination.v1",
                components: [Data($0.kind.rawValue.utf8), Data($0.normalizedIdentity.utf8)]
            ).rawValue.utf8)
        }
        if let process {
            components.append(Data(StableDigest.fingerprint(
                domain: "sandbox-process-requirement.v1",
                components: [
                Data(String(process.maximumConcurrentProcesses).utf8),
                Data(String(process.maximumProcessLaunches).utf8),
                ] + process.allowedRuntimeIDs.map { Data($0.utf8) }
            ).rawValue.utf8))
        }
        components += secretReferences.map { reference in
            Data(StableDigest.fingerprint(
                domain: "sandbox-secret-reference.v1",
                components: [
                    Data(reference.id.description.utf8),
                    Data(reference.purpose.utf8),
                    Data((reference.providerID ?? "").utf8),
                ]
            ).rawValue.utf8)
        }
        return .fingerprint(domain: "sandbox-requirement.v1", components: components)
    }

    /// Creates normalized sandbox requirements without runtime implementation details.
    public init(
        minimumProtocolVersion: SemanticVersion,
        workspaceID: SandboxWorkspaceHandleID? = nil,
        checkpointID: SandboxCheckpointHandleID? = nil,
        authority: AgentAuthorityScope,
        budget: AgentBudget,
        filesystem: some Sequence<SandboxFilesystemRequirement> = [],
        networkDestinations: some Sequence<ExternalDestination> = [],
        process: SandboxProcessRequirement? = nil,
        secretReferences: some Sequence<SecretReference> = []
    ) throws {
        let filesystem = Array(Set(filesystem)).sorted()
        let network = Array(Set(networkDestinations)).sorted()
        let secrets = Array(Set(secretReferences)).sorted { $0.id.description < $1.id.description }
        var totalWrites: UInt64 = 0
        for root in filesystem {
            let (next, overflow) = totalWrites.addingReportingOverflow(root.maximumWrittenBytes)
            guard !overflow else {
                throw AgentContractError.arithmeticOverflow(dimension: .generatedArtifactBytes)
            }
            totalWrites = next
        }
        guard Set(filesystem.map(\.logicalRoot)).count == filesystem.count,
              Set(secrets.map(\.id)).count == secrets.count,
              Set(network).isSubset(of: Set(authority.destinations)),
              Set(secrets.map(\.id)).isSubset(of: Set(authority.secretReferenceIDs)),
              filesystem.flatMap(\.artifactIDs).allSatisfy(authority.artifactIDs.contains),
              workspaceID.map(authority.workspaceIDs.contains) ?? true,
              checkpointID.map(authority.checkpointIDs.contains) ?? true,
              filesystem.isEmpty || authority.capabilities.contains(.localRead),
              !filesystem.contains(where: { $0.access == .readWrite })
                || authority.capabilities.contains(.localWrite),
              network.isEmpty || authority.capabilities.contains(.networkRead),
              process == nil || authority.capabilities.contains(.codeExecution),
              totalWrites <= budget.limits[.generatedArtifactBytes],
              totalWrites <= budget.limits[.persistedOutputBytes]
        else { throw AgentContractError.capabilityEscalation([]) }
        self.minimumProtocolVersion = minimumProtocolVersion
        self.workspaceID = workspaceID
        self.checkpointID = checkpointID
        self.authority = authority
        self.budget = budget
        self.filesystem = filesystem
        self.networkDestinations = network
        self.process = process
        self.secretReferences = secrets
    }

    /// Decodes and revalidates authority, budget, and canonical resource requirements.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let filesystem = try container.decode([SandboxFilesystemRequirement].self, forKey: .filesystem)
        let network = try container.decode([ExternalDestination].self, forKey: .networkDestinations)
        let secrets = try container.decode([SecretReference].self, forKey: .secretReferences)
        do {
            try self.init(
                minimumProtocolVersion: container.decode(
                    SemanticVersion.self,
                    forKey: .minimumProtocolVersion
                ),
                workspaceID: container.decodeIfPresent(SandboxWorkspaceHandleID.self, forKey: .workspaceID),
                checkpointID: container.decodeIfPresent(
                    SandboxCheckpointHandleID.self,
                    forKey: .checkpointID
                ),
                authority: container.decode(AgentAuthorityScope.self, forKey: .authority),
                budget: container.decode(AgentBudget.self, forKey: .budget),
                filesystem: filesystem,
                networkDestinations: network,
                process: container.decodeIfPresent(SandboxProcessRequirement.self, forKey: .process),
                secretReferences: secrets
            )
            guard self.filesystem == filesystem,
                  networkDestinations == network,
                  secretReferences == secrets
            else { throw AgentContractError.invalidName("noncanonical sandbox requirement") }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case minimumProtocolVersion, workspaceID, checkpointID, authority, budget, filesystem
        case networkDestinations, process, secretReferences
    }

    /// Proves this requirement remains inside a current trusted step grant and parent budget.
    public func validateForExecution(
        runID: AgentRunID,
        stepGrant: StepCapabilityGrant,
        parentBudget: AgentBudget,
        trustedRunAuthority: TrustedRunAuthority
    ) throws {
        guard trustedRunAuthority.validates(runID: runID, grant: stepGrant) else {
            throw AgentContractError.authorizationBindingMismatch("sandbox trusted run authority")
        }
        guard authority.isSubset(of: stepGrant.authority) else {
            throw AgentContractError.capabilityEscalation(
                authority.capabilities.values.filter { !stepGrant.capabilities.contains($0) }
            )
        }
        _ = try parentBudget.attenuating(to: budget)
    }

    private var maximumBudgetFingerprint: StableDigest {
        var components = budget.limits.entries.flatMap { entry in
            [Data(entry.dimension.rawValue.utf8), Data(String(entry.value).utf8)]
        }
        components += [
            Data(String(budget.maximumThermalState.rawValue).utf8),
            Data(budget.memoryPressureResponse.rawValue.utf8),
        ]
        return .fingerprint(domain: "agent-budget.v1", components: components)
    }
}

/// Structured progress shared by durable external execution handles.
public struct AgentExecutionProgress: Hashable, Codable, Sendable {
    /// Stable phase name.
    public let phase: String
    /// Completed work units.
    public let completedUnits: UInt64
    /// Optional total work units.
    public let totalUnits: UInt64?
    /// Safe redacted status message.
    public let safeMessage: String?

    /// Creates bounded structured progress.
    public init(
        phase: String,
        completedUnits: UInt64,
        totalUnits: UInt64? = nil,
        safeMessage: String? = nil
    ) throws {
        guard AgentWireValidation.isLowercaseNamespace(phase, maximumLength: 128),
              totalUnits.map({ completedUnits <= $0 }) ?? true,
              safeMessage.map({ AgentWireValidation.isNonblankControlFree($0, maximumLength: 512) }) ?? true
        else { throw AgentContractError.invalidName("execution progress") }
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.safeMessage = safeMessage
    }

    /// Decodes and revalidates structured progress.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                phase: container.decode(String.self, forKey: .phase),
                completedUnits: container.decode(UInt64.self, forKey: .completedUnits),
                totalUnits: container.decodeIfPresent(UInt64.self, forKey: .totalUnits),
                safeMessage: container.decodeIfPresent(String.self, forKey: .safeMessage)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case phase, completedUnits, totalUnits, safeMessage
    }
}
